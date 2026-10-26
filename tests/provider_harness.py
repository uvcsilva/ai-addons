"""Shared scaffolding for the install-<provider>-ubuntu.sh tests (not a test module itself)."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IS_UBUNTU = Path("/etc/os-release").exists() and "ID=ubuntu" in Path("/etc/os-release").read_text()

# The tool installers are tested in test_tools; provider tests only record that the flow called them.
STUBS = ("tools_check() { echo tools_check >> \"$CALLS\"; }\n"
         "tools_install() { echo tools_install >> \"$CALLS\"; }\n"
         "tools_install_ccusage() { echo tools_install_ccusage >> \"$CALLS\"; }\n")

FAKE_SERENA = ('#!/bin/sh\nprintf "serena %s\\n" "$*" >> "$CALLS"\n'
               'echo "--context --project-from-cwd --add-mode --log-level --agent-interface --open-web-dashboard"\n')

# Like graphify 0.9.96: a skill under the client's config dir, a CLAUDE.md edit outside managed
# blocks, and an OpenCode plugin written relative to the cwd.
FAKE_GRAPHIFY = r'''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
home = pathlib.Path(os.environ["HOME"])
config = pathlib.Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
with open(os.environ["CALLS"], "a") as f:
    f.write("graphify " + " ".join(args) + "\n")
skills = {"claude": home / ".claude/skills/graphify", "codex": home / ".codex/skills/graphify",
          "opencode": config / "opencode/skills/graphify", "copilot": home / ".copilot/skills/graphify",
          "antigravity": home / ".gemini/config/skills/graphify"}
if args[:2] == ["install", "--platform"]:
    skill = skills[args[2]]
    (skill / "references").mkdir(parents=True, exist_ok=True)
    (skill / "SKILL.md").write_text("---\nname: graphify\n---\n# /graphify\n")
    (skill / "references/query.md").write_text("graphify query\n")
    if args[2] == "claude":
        (home / ".claude/CLAUDE.md").write_text("# graphify\n- unmanaged section\n")
    if args[2] == "opencode":
        pathlib.Path(".opencode/plugins").mkdir(parents=True, exist_ok=True)
        pathlib.Path(".opencode/plugins/graphify.js").write_text("// graphify OpenCode plugin\n")
elif args == ["--version"]:
    print("graphify 0.9.96")
'''

ENV_TO_DROP = ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME", "CLINE_MCP_SETTINGS_PATH", "XDG_CONFIG_HOME",
               "XDG_STATE_HOME", "PONYTAIL_DEFAULT_MODE", "CONTEXT7_API_KEY", "OPENCODE_CONFIG",
               "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_DIR")


@unittest.skipUnless(IS_UBUNTU, "installer_begin requires Ubuntu")
class ProviderInstallerTest(unittest.TestCase):
    SCRIPT = None
    CLIS = ()  # provider CLIs the test fakes itself
    CONFIG = {"addons": {"serena": {"log-level": "INFO", "modes": ["planning"]},
                         "rtk": {"init-mode": "hook-only", "trust-filters": False},
                         "ponytail": {"mode": "full"}}}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.local_bin = self.home / ".local/bin"
        self.local_bin.mkdir(parents=True)
        self.fake = self.home / "fake-bin"
        self.fake.mkdir()
        self.calls = self.home / "calls"
        self.config = self.home / "addons.json"
        self.config.write_text(json.dumps(self.CONFIG))
        for name in ("git", "jq", "curl", "node", "npm"):
            self.executable(self.fake / name, "#!/bin/sh\nexit 0\n")
        self.executable(self.local_bin / "serena", FAKE_SERENA)
        self.executable(self.local_bin / "context7-mcp", "#!/bin/sh\nexit 0\n")
        self.executable(self.local_bin / "graphify", FAKE_GRAPHIFY)

    def assert_graphify_skill(self, skill_dir):
        """The skill was copied from the scratch HOME; the real HOME got nothing else from graphify."""
        self.assertEqual((skill_dir / "SKILL.md").read_text(), "---\nname: graphify\n---\n# /graphify\n")
        self.assertTrue((skill_dir / "references/query.md").is_file())
        claude_md = self.home / ".claude/CLAUDE.md"
        self.assertFalse(claude_md.exists() and "unmanaged section" in claude_md.read_text())

    def executable(self, path, body):
        path.write_text(body)
        path.chmod(0o700)

    def env(self, **extra):
        env = dict(os.environ, HOME=str(self.home), PATH=f"{self.fake}:/usr/bin:/bin", CALLS=str(self.calls))
        for key in ENV_TO_DROP:
            env.pop(key, None)
        env.update(extra)
        return env

    def run_script(self, *args, check=True, **env):
        result = subprocess.run(["bash", str(self.SCRIPT), *args], cwd="/", env=self.env(**env), text=True,
                                capture_output=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def run_main(self, *args, check=True, **env):
        code = (f". {shlex.quote(str(self.SCRIPT))}\n{STUBS}"
                f"main --config {shlex.quote(str(self.config))} {shlex.join(args)}\n")
        result = subprocess.run(["bash", "-c", code], env=self.env(**env), text=True, capture_output=True,
                                timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def run_function(self, code, check=True):
        result = subprocess.run(["bash", "-c", f". {shlex.quote(str(self.SCRIPT))}\n{code}"], env=self.env(),
                                text=True, capture_output=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def call_log(self):
        lines = self.calls.read_text().splitlines() if self.calls.exists() else []
        self.calls.write_text("")
        return lines

    def assert_in_order(self, calls, expected):
        positions = [calls.index(c) for c in expected]
        self.assertEqual(positions, sorted(positions), calls)

    def assert_dry_run_writes_nothing(self, *args):
        result = self.run_script("--config", str(self.config), "--dry-run", *args)
        self.assertFalse((self.home / ".local/state").exists())
        self.assertFalse(self.calls.exists())
        self.assertEqual(sorted(p.name for p in self.home.iterdir()), [".local", "addons.json", "fake-bin"])
        return result.stdout

    def assert_bad_arguments_exit_2(self, *extra_cases):
        bad = self.home / "bad.json"
        bad.write_text(json.dumps({"addons": {"ponytail": {"mode": "max"}}}))
        for args in (["--bogus"], ["--config"], ["--config", str(bad), "--dry-run"], *extra_cases):
            with self.subTest(args=args):
                self.assertEqual(self.run_script(*args, check=False).returncode, 2)
