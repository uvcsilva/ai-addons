import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "lib"



class ToolsFlowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / ".local/bin"
        self.bin.mkdir(parents=True)
        self.fake = self.base / "fake"
        self.fake.mkdir()
        self.calls = self.base / "calls"

    def executable(self, path, body):
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o700)

    def run_tools(self, config, code, check=True):
        path = self.base / "addons.json"
        path.write_text(json.dumps(config))
        env = dict(os.environ, HOME=str(self.base), PATH=f"{self.fake}:/usr/bin:/bin", CALLS=str(self.calls))
        for key in ("XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR", "GITHUB_TOKEN"):
            env.pop(key, None)
        sources = "".join(f". {shlex.quote(str(LIB / n))}\n" for n in ("common.sh", "config.sh", "tools.sh"))
        result = subprocess.run(["bash", "-c", "set -Eeuo pipefail\n" + sources
                                 + f"config_load {shlex.quote(str(path))}\ntools_load_options\n" + code],
                                env=env, text=True, capture_output=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_options_are_validated(self):
        bad = {"addons.rtk.telemetry": {"rtk": {"telemetry": "maybe"}},
               "addons.rtk.history-days": {"rtk": {"history-days": 0}},
               "addons.serena.ls-dependencies": {"serena": {"ls-dependencies": ["go lang"]}},
               "addons.ccusage.settings": {"ccusage": {"settings": "[1]"}},
               "Caminho precisa ser absoluto": {"serena": {"check-go-project": "relative/api"}}}
        for expected, addons in bad.items():
            with self.subTest(expected=expected):
                result = self.run_tools({"addons": addons}, "", check=False)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(expected, result.stderr)

    def test_check_picks_assets_for_arch_and_backs_up(self):
        (self.bin / "rtk").write_text("old")
        backup = self.base / "backup"
        backup.mkdir()
        for machine, expected in (("aarch64", "arm64 rtk-aarch64-unknown-linux-gnu.tar.gz uv-aarch64-unknown-linux-gnu.tar.gz"),
                                  ("x86_64", "amd64 rtk-x86_64-unknown-linux-musl.tar.gz uv-x86_64-unknown-linux-gnu.tar.gz")):
            with self.subTest(machine=machine):
                self.executable(self.fake / "uname", f"echo {machine}\n")
                result = self.run_tools({}, f"BACKUP_DIR={shlex.quote(str(backup))}\ntools_check\n"
                                        'printf "%s %s %s" "$ASSET_ARCH" "$RTK_ASSET" "$UV_ASSET"')
                self.assertEqual(result.stdout.splitlines()[-1], expected)
        self.assertEqual(len(list(backup.iterdir())), 1)
        self.executable(self.fake / "uname", "echo riscv64\n")
        self.assertNotEqual(self.run_tools({}, "tools_check", check=False).returncode, 0)

    def test_install_runs_each_tool_in_order(self):
        # Every fake binary only records how it was called.
        log = 'printf "%s\\n" "$(basename "$0") $*" >> "$CALLS"\n'
        tpl = self.base / "tpl"
        tpl.mkdir()
        for name in ("engram", "uvx", "rtk", "serena", "graphify", "logger"):
            self.executable(tpl / name, log)
        # uv tool install creates the tool's entry point, as the real uv does.
        self.executable(tpl / "uv", log + '[[ $1 != tool ]] || case "${@: -1}" in\n'
                        f'  serena-agent) cp {shlex.quote(str(tpl / "serena"))} {shlex.quote(str(self.bin / "serena"))} ;;\n'
                        f'  graphifyy) cp {shlex.quote(str(tpl / "graphify"))} {shlex.quote(str(self.bin / "graphify"))} ;;\n'
                        'esac\n')
        self.executable(self.fake / "npm", log + 'pkg="${@: -1}"; name="${pkg%@latest}"; name="${name##*/}"\n'
                        f'cp {shlex.quote(str(tpl / "logger"))} {shlex.quote(str(self.bin))}/"$name"\n')
        stubs = ("download_verified_release_asset() { printf '%s\\n' \"download $1\" >> \"$CALLS\"; echo v9; }\n"
                 f"extract_archive_binary() {{ cp {shlex.quote(str(tpl))}/\"$2\" \"$3\"; }}\n"
                 "warn_engram_runtime_version() { printf '%s\\n' warn >> \"$CALLS\"; }\n")
        config = {"addons": {"rtk": {"telemetry": "disable", "recall": "sqlite", "awareness": "high"},
                             "ccusage": {"settings": {"defaults": {"timezone": "UTC"}}}}}
        code = (stubs + f"TMP_WORKDIR={shlex.quote(str(self.base))}\nBACKUP_DIR={shlex.quote(str(self.base))}\n"
                "ASSET_ARCH=arm64; RTK_ASSET=r.tgz; UV_ASSET=u.tgz\n"
                "tools_install\ntools_install_ccusage\n")
        self.run_tools(config, code)
        names = [" ".join(line.split()[:2]) for line in self.calls.read_text().splitlines()]
        self.assertEqual(names, [
            "download Gentleman-Programming/engram", "engram version", "warn",
            "download astral-sh/uv", "uv tool", "serena --version", "uv tool", "graphify --version",
            "npm install", "download rtk-ai/rtk", "rtk telemetry", "rtk config", "rtk --version",
            "npm install", "ccusage --version", "ccusage --help"])
        uv_calls = [line for line in self.calls.read_text().splitlines() if line.startswith("uv tool")]
        self.assertEqual(uv_calls[1], "uv tool install --upgrade -p 3.13 graphifyy")
        preflight = self.bin / "graphify-preflight"
        self.assertEqual(preflight.read_text(), (ROOT / "bin/graphify-preflight").read_text())
        self.assertTrue(os.access(preflight, os.X_OK))
        self.assertIn('level = "high"', (self.base / ".config/rtk/config.toml").read_text())
        self.assertEqual(json.loads((self.base / ".config/claude/ccusage.json").read_text())["defaults"],
                         {"timezone": "UTC"})


if __name__ == "__main__":
    unittest.main()
