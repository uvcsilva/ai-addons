import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from provider_harness import ROOT, ProviderInstallerTest  # noqa: E402

SCRIPT = ROOT / "install-antigravity-ubuntu.sh"

# Refuses the flags rtk init --agent antigravity refuses (src/hooks/init/mod.rs).
FAKE_RTK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f:
    f.write("rtk " + " ".join(args) + "\n")
if "antigravity" in args and {"--hook-only", "--auto-patch", "--no-patch", "--claude-md"} & set(args):
    sys.exit(1)
if args[:4] == ["init", "--global", "--agent", "antigravity"]:
    plugin = pathlib.Path(os.environ["HOME"]) / ".gemini/config/plugins/rtk"
    plugin.mkdir(parents=True, exist_ok=True)
    (plugin / "hooks.json").write_text(json.dumps({"rtk-rewrite": {"enabled": True, "PreToolUse": [
        {"matcher": "run_command", "hooks": [{"type": "command", "command": "rtk hook antigravity"}]}]}}))
'''

FAKE_AGY = r'''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
state = pathlib.Path(os.environ["HOME"]) / "fake-agy-plugins"
with open(os.environ["CALLS"], "a") as f:
    f.write("agy " + " ".join(args) + "\n")
if args == ["plugin", "list"]:
    print(state.read_text() if state.exists() else "No plugins installed")
elif args == ["plugin", "install", "https://github.com/DietrichGebert/ponytail"]:
    state.write_text("ponytail  1.0.0  enabled\n")
else:
    raise SystemExit("Unexpected agy call: " + repr(args))
'''


class AntigravityInstallerTest(ProviderInstallerTest):
    SCRIPT = SCRIPT

    def setUp(self):
        super().setUp()
        self.executable(self.local_bin / "rtk", FAKE_RTK)
        self.executable(self.fake / "agy", FAKE_AGY)
        self.gemini = self.home / ".gemini"

    def test_dry_run_writes_nothing(self):
        out = self.assert_dry_run_writes_nothing("--project-dir", "/srv/app")
        self.assertIn("Simulacao do Antigravity", out)
        self.assertIn("--context antigravity --add-mode no-memories --project /srv/app", out)

    def test_invalid_arguments_and_config_exit_2(self):
        self.assert_bad_arguments_exit_2(["--project-dir", "rel", "--dry-run"])

    def test_flow_configures_every_addon_and_is_idempotent(self):
        self.run_main()
        self.assert_in_order(self.call_log(), [
            "tools_check", "tools_install", "serena start-mcp-server --help",
            "rtk init --global --agent antigravity --no-trust-filters", "agy plugin list",
            "agy plugin install https://github.com/DietrichGebert/ponytail"])
        bin_ = str(self.local_bin)
        servers = json.loads((self.gemini / "config/mcp_config.json").read_text())["mcpServers"]
        self.assertEqual(servers["engram"], {"command": f"{bin_}/engram", "args": ["mcp", "--tools=agent"]})
        self.assertEqual(servers["serena"]["args"], [
            "start-mcp-server", "--context", "antigravity", "--project-from-cwd", "--add-mode", "no-memories",
            "--log-level", "INFO", "--add-mode", "planning"])
        rules = (self.gemini / "GEMINI.md").read_text()
        self.assert_graphify_skill(self.gemini / "config/skills/graphify")
        for addon in ("engram", "serena", "context7", "ponytail", "graphify"):
            self.assertIn(f"<!-- six-addons:{addon}:begin -->", rules)
        self.assertNotIn("six-addons:rtk", rules)

        files = [self.gemini / "config/mcp_config.json", self.gemini / "GEMINI.md"]
        before = {p: p.read_text() for p in files}
        result = self.run_main()
        self.assertIn("Plugin Antigravity ponytail ja instalado", result.stdout)
        self.assertNotIn("agy plugin install https://github.com/DietrichGebert/ponytail", self.call_log())
        self.assertEqual({p: p.read_text() for p in files}, before)

    def test_fixed_project_and_no_agy(self):
        (self.fake / "agy").unlink()
        result = self.run_main("--project-dir", "/srv/app")
        self.assertIn("CLI agy ausente", result.stdout)
        serena = json.loads((self.gemini / "config/mcp_config.json").read_text())["mcpServers"]["serena"]
        self.assertEqual(serena["args"][:6], ["start-mcp-server", "--context", "antigravity", "--add-mode",
                                              "no-memories", "--project"])
        self.assertIn("<!-- six-addons:ponytail:begin -->", (self.gemini / "GEMINI.md").read_text())

    def test_conflicting_mcp_stops_before_any_download(self):
        (self.gemini / "config").mkdir(parents=True)
        original = json.dumps({"mcpServers": {"serena": {"command": "/other/serena", "args": []}}})
        (self.gemini / "config/mcp_config.json").write_text(original)
        result = self.run_main(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Conflito MCP serena", result.stdout + result.stderr)
        self.assertNotIn("tools_install", self.call_log())
        self.assertEqual((self.gemini / "config/mcp_config.json").read_text(), original)
        self.assertFalse((self.gemini / "GEMINI.md").exists())


if __name__ == "__main__":
    unittest.main()
