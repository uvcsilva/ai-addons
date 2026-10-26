import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from provider_harness import ROOT, ProviderInstallerTest  # noqa: E402

SCRIPT = ROOT / "install-copilot-ubuntu.sh"

FAKE_COPILOT = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
home = pathlib.Path(os.environ["HOME"])
markets_file, plugins_file = home / "fake-copilot-markets.json", home / "fake-copilot-plugins.json"
markets = json.loads(markets_file.read_text()) if markets_file.exists() else [
    {"name": "awesome-copilot", "source": "GitHub: github/awesome-copilot", "isDefault": True}]
plugins = json.loads(plugins_file.read_text()) if plugins_file.exists() else []
with open(os.environ["CALLS"], "a") as f:
    f.write("copilot " + " ".join(args) + "\n")
if args == ["--version"]:
    print("GitHub Copilot CLI 1.0.103.")
elif args == ["plugin", "marketplace", "list", "--json"]:
    print(json.dumps(markets))
elif args[:3] == ["plugin", "marketplace", "add"]:
    markets.append({"name": "ponytail", "source": "GitHub: " + args[3]})
    markets_file.write_text(json.dumps(markets))
elif args == ["plugin", "list", "--json"]:
    print(json.dumps(plugins))
elif args[:2] == ["plugin", "install"]:
    name, market = args[2].split("@")
    plugins.append({"name": name, "marketplace": market, "version": "5.3.2", "enabled": True, "source": "marketplace"})
    plugins_file.write_text(json.dumps(plugins))
elif args[:3] == ["plugin", "marketplace", "update"] or args[:2] == ["plugin", "update"]:
    pass
else:
    raise SystemExit("Unexpected Copilot call: " + repr(args))
'''

# rtk init --copilot writes its own hook and instructions; --agent cline writes .clinerules in the cwd.
FAKE_RTK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f:
    f.write("rtk " + " ".join(args) + "\n")
copilot = pathlib.Path(os.environ.get("COPILOT_HOME") or pathlib.Path(os.environ["HOME"]) / ".copilot")
if args[:3] == ["init", "--global", "--copilot"]:
    (copilot / "hooks").mkdir(parents=True, exist_ok=True)
    (copilot / "hooks/rtk-rewrite.json").write_text(json.dumps(
        {"version": 1, "hooks": {"PreToolUse": [{"type": "command", "command": "rtk hook copilot"}]}}))
    instructions = copilot / "copilot-instructions.md"
    text = instructions.read_text() if instructions.exists() else ""
    if "RTK (native)" not in text:
        instructions.write_text(text + "\n# RTK (native)\nUse rtk.\n")
elif args == ["init", "--agent", "cline"]:
    pathlib.Path(".clinerules").write_text("# RTK\nPrefix shell commands with rtk.\n")
'''

OLD_BLOCK = "<!-- six-addons:{0}:begin -->\nold {0} rules\n<!-- six-addons:{0}:end -->\n"


class CopilotInstallerTest(ProviderInstallerTest):
    SCRIPT = SCRIPT

    def setUp(self):
        super().setUp()
        self.executable(self.fake / "copilot", FAKE_COPILOT)
        self.executable(self.local_bin / "rtk", FAKE_RTK)
        self.cli = self.home / ".copilot"
        self.user = self.home / ".config/Code/User"

    def test_dry_run_writes_nothing(self):
        out = self.assert_dry_run_writes_nothing("--project-dir", "/srv/app")
        self.assertIn("Superficies: cli,vscode", out)
        self.assertIn("--context vscode --add-mode no-memories --project /srv/app", out)

    def test_invalid_arguments_and_config_exit_2(self):
        self.assert_bad_arguments_exit_2(["--surfaces", "web"], ["--project-dir", "relative", "--dry-run"])

    def test_flow_configures_both_surfaces_and_is_idempotent(self):
        # Blocks the old per-addon installers wrote; native hook/plugin now replace rtk and ponytail.
        self.cli.mkdir()
        (self.cli / "copilot-instructions.md").write_text(
            "My rules\n\n" + OLD_BLOCK.format("rtk") + "\n" + OLD_BLOCK.format("ponytail"))
        self.run_main("--project-dir", "/srv/app")
        bin_ = str(self.local_bin)
        calls = self.call_log()
        self.assert_in_order(calls, [
            "tools_check", "tools_install", "serena start-mcp-server --help",
            "rtk init --global --copilot --no-trust-filters", "rtk init --agent cline",
            "copilot plugin marketplace add DietrichGebert/ponytail", "copilot plugin install ponytail@ponytail"])

        cli_servers = json.loads((self.cli / "mcp-config.json").read_text())["mcpServers"]
        self.assertEqual(cli_servers["engram"], {"command": f"{bin_}/engram", "args": ["mcp", "--tools=agent"],
                                                 "type": "local", "tools": ["*"]})
        self.assertEqual(cli_servers["serena"]["args"], [
            "start-mcp-server", "--context", "copilot-cli", "--add-mode", "no-memories", "--project-from-cwd",
            "--log-level", "INFO", "--add-mode", "planning"])
        vscode_servers = json.loads((self.user / "mcp.json").read_text())["servers"]
        self.assertEqual(vscode_servers["context7"], {"command": f"{bin_}/context7-mcp", "args": [], "type": "stdio"})
        self.assertEqual(vscode_servers["serena"]["args"], [
            "start-mcp-server", "--context", "vscode", "--add-mode", "no-memories", "--project", "/srv/app",
            "--log-level", "INFO", "--add-mode", "planning"])

        instructions = (self.cli / "copilot-instructions.md").read_text()
        self.assertTrue(instructions.startswith("My rules\n"))
        self.assertIn("# RTK (native)", instructions)
        self.assert_graphify_skill(self.cli / "skills/graphify")
        for addon in ("engram", "serena", "context7", "graphify"):
            self.assertIn(f"<!-- six-addons:{addon}:begin -->", instructions)
        for addon in ("rtk", "ponytail"):
            self.assertNotIn(f"six-addons:{addon}", instructions)
        self.assertIn("rtk hook copilot", (self.cli / "hooks/rtk-rewrite.json").read_text())
        for addon in ("engram", "serena", "context7", "rtk", "ponytail", "graphify"):
            prompt = (self.user / f"prompts/six-addons-{addon}.instructions.md").read_text()
            self.assertTrue(prompt.startswith('---\napplyTo: "**"\n---\n'), addon)
        self.assertNotIn("## Level:", (self.user / "prompts/six-addons-ponytail.instructions.md").read_text())
        settings = json.loads((self.user / "settings.json").read_text())
        self.assertEqual(settings, {"github.copilot.chat.tools.memory.enabled": False,
                                    "github.copilot.chat.copilotMemory.enabled": False})
        self.assertEqual(json.loads((self.home / ".config/ponytail/config.json").read_text())["defaultMode"], "full")

        files = [self.cli / "mcp-config.json", self.cli / "copilot-instructions.md", self.user / "mcp.json",
                 self.user / "settings.json", self.user / "prompts/six-addons-rtk.instructions.md"]
        before = {p: p.read_text() for p in files}
        result = self.run_main("--project-dir", "/srv/app")
        self.assertIn("ACAO MANUAL: desative Copilot Memory", result.stdout)
        calls = self.call_log()
        self.assertFalse([c for c in calls if c.startswith(("copilot plugin install", "copilot plugin marketplace add"))])
        self.assertIn("copilot plugin update ponytail@ponytail", calls)
        self.assertEqual({p: p.read_text() for p in files}, before)

    def test_without_copilot_cli_ponytail_stays_as_rules(self):
        (self.fake / "copilot").unlink()
        result = self.run_main("--surfaces", "cli")
        self.assertIn("comando copilot ausente", result.stdout)
        instructions = (self.cli / "copilot-instructions.md").read_text()
        self.assertIn("<!-- six-addons:ponytail:begin -->", instructions)
        self.assertNotIn("copilot plugin", "\n".join(self.call_log()))
        self.assertFalse(self.user.exists())
        self.assertFalse((self.home / ".config/ponytail").exists())

    def test_vscode_surface_leaves_copilot_cli_untouched(self):
        self.run_main("--surfaces", "vscode")
        self.assertFalse(self.cli.exists())
        self.assertFalse([c for c in self.call_log() if c.startswith(("copilot", "rtk init --global"))])
        self.assertTrue((self.user / "mcp.json").exists())

    def test_conflicting_mcp_stops_before_any_download(self):
        self.cli.mkdir()
        original = json.dumps({"mcpServers": {"serena": {"command": "/other/serena", "args": []}}})
        (self.cli / "mcp-config.json").write_text(original)
        result = self.run_main(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Conflito MCP serena", result.stdout + result.stderr)
        self.assertNotIn("tools_install", self.call_log())
        self.assertEqual((self.cli / "mcp-config.json").read_text(), original)
        self.assertFalse(self.user.exists())

    def test_copilot_home_is_respected(self):
        alt = self.home / "alt-copilot"
        self.run_main("--surfaces", "cli", COPILOT_HOME=str(alt))
        self.assertTrue((alt / "mcp-config.json").exists())
        self.assertTrue((alt / "hooks/rtk-rewrite.json").exists())
        self.assertFalse(self.cli.exists())


if __name__ == "__main__":
    unittest.main()
