import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from provider_harness import ROOT, ProviderInstallerTest  # noqa: E402

SCRIPT = ROOT / "install-opencode-ubuntu.sh"

FAKE_OPENCODE = r'''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f:
    f.write("opencode " + " ".join(args) + "\n")
config_dir = pathlib.Path(os.environ.get("XDG_CONFIG_HOME") or pathlib.Path(os.environ["HOME"]) / ".config") / "opencode"
if args == ["--version"]:
    print(os.environ.get("FAKE_OPENCODE_VERSION", "1.19.4"))
elif args == ["plugin", "@dietrichgebert/ponytail", "--global"]:
    config = next(p for p in (config_dir / "opencode.jsonc", config_dir / "opencode.json") if p.exists())
    text = config.read_text()
    if '"@dietrichgebert/ponytail"' not in text:
        end = text.rindex("}")
        config.write_text(text[:end].rstrip() + ',\n  "plugin": ["@dietrichgebert/ponytail"]\n' + text[end:])
else:
    raise SystemExit("Unexpected OpenCode call: " + repr(args))
'''

# Like the real setups, these also rewrite opencode.json and touch Claude files.
FAKE_ENGRAM = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
with open(os.environ["CALLS"], "a") as f:
    f.write("engram " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["setup", "opencode"]:
    oc = pathlib.Path(os.environ["XDG_CONFIG_HOME"]) / "opencode"
    (oc / "plugins").mkdir(parents=True, exist_ok=True)
    (oc / "plugins/engram.ts").write_text(f'const ENGRAM_BIN = "{sys.argv[0]}"\n')
    (oc / "opencode.json").write_text(json.dumps({"mcp": {"engram": {"command": ["engram", "mcp", "--tools=agent"]}}}))
    (oc / "tui.json").write_text(json.dumps({"plugin": ["opencode-subagent-statusline"]}, indent=2) + "\n")
'''

FAKE_RTK = r'''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f:
    f.write("rtk " + " ".join(args) + "\n")
if args[:3] == ["init", "--global", "--opencode"]:
    home = pathlib.Path(os.environ["HOME"])
    plugins = pathlib.Path(os.environ["XDG_CONFIG_HOME"]) / "opencode/plugins"
    plugins.mkdir(parents=True, exist_ok=True)
    (plugins / "rtk.ts").write_text("// RTK OpenCode plugin\n")
    (home / ".claude").mkdir(exist_ok=True)
    (home / ".claude/RTK.md").write_text("rtk\n")
elif args == ["init", "--agent", "cline"]:
    pathlib.Path(".clinerules").write_text("# RTK\nPrefix shell commands with rtk.\n")
'''

OLD_PONYTAIL = "<!-- six-addons:ponytail:begin -->\nold ponytail rules\n<!-- six-addons:ponytail:end -->\n"


class OpenCodeInstallerTest(ProviderInstallerTest):
    SCRIPT = SCRIPT

    def setUp(self):
        super().setUp()
        self.executable(self.fake / "opencode", FAKE_OPENCODE)
        self.executable(self.local_bin / "engram", FAKE_ENGRAM)
        self.executable(self.local_bin / "rtk", FAKE_RTK)
        self.oc = self.home / ".config/opencode"

    def test_dry_run_writes_nothing(self):
        out = self.assert_dry_run_writes_nothing("--project-dir", "/srv/app", "--opencode-major", "2")
        self.assertIn("Simulacao do OpenCode", out)
        self.assertIn("--context ide --add-mode no-memories --project /srv/app", out)

    def test_invalid_arguments_and_config_exit_2(self):
        self.assert_bad_arguments_exit_2(["--opencode-major", "3"], ["--project-dir", "rel", "--dry-run"])

    def test_v1_flow_uses_native_plugins_and_is_idempotent(self):
        self.oc.mkdir(parents=True)
        (self.oc / "AGENTS.md").write_text("My rules\n\n" + OLD_PONYTAIL)
        self.run_main()
        bin_ = str(self.local_bin)
        self.assert_in_order(self.call_log(), [
            "opencode --version", "tools_check", "tools_install", "serena start-mcp-server --help",
            "engram setup opencode", "rtk init --global --opencode --auto-patch --no-trust-filters",
            "rtk init --agent cline", "opencode plugin @dietrichgebert/ponytail --global"])

        config = json.loads((self.oc / "opencode.json").read_text())
        self.assertEqual(config["mcp"]["engram"], {"type": "local", "command": [f"{bin_}/engram", "mcp", "--tools=agent"],
                                                   "enabled": True})
        self.assertEqual(config["mcp"]["serena"]["command"][1:], [
            "start-mcp-server", "--context", "ide", "--project-from-cwd", "--add-mode", "no-memories",
            "--log-level", "INFO", "--add-mode", "planning"])
        self.assertEqual(config["plugin"], ["@dietrichgebert/ponytail"])
        self.assertEqual((self.oc / "plugins/engram.ts").read_text(), f'const ENGRAM_BIN = "{bin_}/engram"\n')
        self.assertEqual((self.oc / "plugins/rtk.ts").read_text(), "// RTK OpenCode plugin\n")
        self.assertEqual(json.loads((self.oc / "tui.json").read_text()), {"plugin": ["opencode-subagent-statusline"]})
        self.assertFalse((self.home / ".claude").exists())  # rtk init --opencode ran in a scratch HOME

        rules = (self.oc / "AGENTS.md").read_text()
        self.assertTrue(rules.startswith("My rules\n"))
        for addon in ("engram", "serena", "context7", "rtk"):
            self.assertIn(f"<!-- six-addons:{addon}:begin -->", rules)
        self.assertNotIn("six-addons:ponytail", rules)

        files = [self.oc / n for n in ("opencode.json", "AGENTS.md", "tui.json", "plugins/engram.ts", "plugins/rtk.ts")]
        before = {p: p.read_text() for p in files}
        result = self.run_main()
        self.assertIn("Plugin OpenCode engram.ts ja confere", result.stdout)
        self.assertEqual({p: p.read_text() for p in files}, before)

    def test_v2_jsonc_keeps_comments_and_fixed_project(self):
        self.oc.mkdir(parents=True)
        (self.oc / "opencode.jsonc").write_text('{\n  // keep me\n  "model": "x/y"\n}\n')
        self.run_main("--opencode-major", "2", "--project-dir", "/srv/app", FAKE_OPENCODE_VERSION="2.0.1")
        text = (self.oc / "opencode.jsonc").read_text()
        self.assertIn("// keep me", text)
        self.assertFalse((self.oc / "opencode.json").exists())
        stripped = json.loads("\n".join(l for l in text.splitlines() if not l.strip().startswith("//")))
        serena = stripped["mcp"]["servers"]["serena"]
        self.assertEqual(serena["disabled"], False)
        self.assertEqual(serena["command"][1:5], ["start-mcp-server", "--context", "ide", "--add-mode"])
        self.assertIn("/srv/app", serena["command"])
        self.assertEqual(stripped["plugin"], ["@dietrichgebert/ponytail"])

    def test_without_opencode_cli(self):
        (self.fake / "opencode").unlink()
        result = self.run_main(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Instale OpenCode ou informe --opencode-major", result.stdout + result.stderr)
        result = self.run_main("--opencode-major", "1")
        self.assertIn("comando opencode ausente", result.stdout)
        self.assertIn("<!-- six-addons:ponytail:begin -->", (self.oc / "AGENTS.md").read_text())
        self.assertNotIn("plugin", json.loads((self.oc / "opencode.json").read_text()))

    def test_refusals_change_nothing(self):
        result = self.run_main(check=False, OPENCODE_CONFIG=str(self.home / "other.json"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("OPENCODE_CONFIG", result.stdout + result.stderr)
        self.oc.mkdir(parents=True)
        for name in ("opencode.json", "opencode.jsonc"):
            (self.oc / name).write_text("{}\n")
        result = self.run_main(check=False)
        self.assertIn("consolide", result.stdout + result.stderr)
        self.assertNotIn("tools_install", self.call_log())
        self.assertEqual(sorted(p.name for p in self.oc.iterdir()), ["opencode.json", "opencode.jsonc"])

    def test_existing_tui_config_is_not_rewritten(self):
        self.oc.mkdir(parents=True)
        (self.oc / "tui.json").write_text('{"theme": "dark"}\n')
        result = self.run_main()
        self.assertIn("inclua \"opencode-subagent-statusline\"", result.stdout)
        self.assertEqual((self.oc / "tui.json").read_text(), '{"theme": "dark"}\n')

    def test_conflicting_mcp_stops_before_any_download(self):
        self.oc.mkdir(parents=True)
        original = json.dumps({"mcp": {"context7": {"type": "local", "command": ["/other/c7"], "enabled": True}}})
        (self.oc / "opencode.json").write_text(original)
        result = self.run_main(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Conflito MCP context7", result.stdout + result.stderr)
        self.assertNotIn("tools_install", self.call_log())
        self.assertEqual((self.oc / "opencode.json").read_text(), original)
        self.assertFalse((self.oc / "plugins").exists())


if __name__ == "__main__":
    unittest.main()
