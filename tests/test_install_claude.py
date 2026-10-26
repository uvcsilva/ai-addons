import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from provider_harness import ROOT, ProviderInstallerTest  # noqa: E402

SCRIPT = ROOT / "install-claude-ubuntu.sh"

FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
home = pathlib.Path(os.environ["HOME"])
cjson = home / ".claude.json"
state = home / "fake-claude-plugins.json"
with open(os.environ["CALLS"], "a") as f:
    f.write("claude " + " ".join(args) + "\n")
def load(p, default):
    return json.loads(p.read_text()) if p.exists() else default
if args == ["--version"]:
    print("2.1.300 (Claude Code)")
elif args[:2] == ["mcp", "add"]:
    sep = args.index("--")
    data = load(cjson, {})
    data.setdefault("mcpServers", {})[args[6]] = {"type": "stdio", "command": args[sep + 1], "args": args[sep + 2:]}
    cjson.write_text(json.dumps(data))
elif args[:2] == ["mcp", "remove"]:
    data = load(cjson, {})
    data["mcpServers"].pop(args[-1])
    cjson.write_text(json.dumps(data))
elif args[:3] == ["plugin", "marketplace", "add"]:
    p = home / ".claude/plugins/known_marketplaces.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"ponytail": {"source": {"source": "github", "repo": args[3]}}}))
elif args[:2] == ["plugin", "install"]:
    plugins = load(state, [])
    if any(p["id"] == args[2] for p in plugins):
        print("Plugin already installed"); sys.exit(1)
    plugins.append({"id": args[2], "scope": "user", "enabled": True})
    state.write_text(json.dumps(plugins))
elif args[:2] == ["plugin", "list"]:
    print(json.dumps(load(state, [])))
'''

FAKE_ENGRAM = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
home = pathlib.Path(os.environ["HOME"])
with open(os.environ["CALLS"], "a") as f:
    f.write("engram " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["setup", "claude-code"]:
    state = home / "fake-claude-plugins.json"
    plugins = json.loads(state.read_text()) if state.exists() else []
    if not any(p["id"] == "engram@engram" for p in plugins):
        plugins.append({"id": "engram@engram", "scope": "user", "enabled": True})
    state.write_text(json.dumps(plugins))
'''

FAKE_RTK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
home = pathlib.Path(os.environ["HOME"])
with open(os.environ["CALLS"], "a") as f:
    f.write("rtk " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:2] == ["init"]:
    p = home / ".claude/settings.json"
    data = json.loads(p.read_text()) if p.exists() else {}
    data["hooks"] = {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook claude"}]}]}
    p.write_text(json.dumps(data))
'''


class ClaudeInstallerTest(ProviderInstallerTest):
    SCRIPT = SCRIPT

    def setUp(self):
        super().setUp()
        self.executable(self.fake / "claude", FAKE_CLAUDE)
        self.executable(self.local_bin / "engram", FAKE_ENGRAM)
        self.executable(self.local_bin / "rtk", FAKE_RTK)

    def test_dry_run_writes_nothing(self):
        out = self.assert_dry_run_writes_nothing()
        self.assertIn("Simulacao do Claude", out)
        self.assertIn("rtk init --global --auto-patch --hook-only --no-trust-filters", out)

    def test_invalid_arguments_and_config_exit_2(self):
        self.assert_bad_arguments_exit_2()

    def test_flow_configures_every_addon_and_is_idempotent(self):
        self.run_main()
        bin_ = str(self.local_bin)
        self.assert_in_order(self.call_log(), [
            "tools_check", "tools_install", "tools_install_ccusage", "engram setup claude-code",
            f"claude mcp add --transport stdio --scope user engram -- {bin_}/engram mcp --tools=agent",
            "serena start-mcp-server --help", "rtk init --global --auto-patch --hook-only --no-trust-filters",
            "claude plugin marketplace add DietrichGebert/ponytail", "claude plugin install ponytail@ponytail --scope user"])

        servers = json.loads((self.home / ".claude.json").read_text())["mcpServers"]
        self.assertEqual(servers["engram"]["args"], ["mcp", "--tools=agent"])
        self.assertEqual(servers["serena"], {"type": "stdio", "command": f"{bin_}/serena", "args": [
            "start-mcp-server", "--context", "claude-code", "--project-from-cwd", "--add-mode", "no-memories",
            "--log-level", "INFO", "--add-mode", "planning"]})
        self.assertEqual(servers["context7"], {"type": "stdio", "command": f"{bin_}/context7-mcp", "args": []})

        settings = json.loads((self.home / ".claude/settings.json").read_text())
        self.assertIs(settings["autoMemoryEnabled"], False)
        self.assertEqual(settings["env"]["MCP_TIMEOUT"], "60000")
        rules = (self.home / ".claude/CLAUDE.md").read_text()
        self.assert_graphify_skill(self.home / ".claude/skills/graphify")
        for addon in ("serena", "context7", "graphify"):
            self.assertIn(f"<!-- six-addons:{addon}:begin -->", rules)
        for addon in ("engram", "rtk", "ponytail"):
            self.assertNotIn(f"six-addons:{addon}", rules)
        self.assertEqual(json.loads((self.home / ".config/ponytail/config.json").read_text())["defaultMode"], "full")
        self.assertEqual(len(list((self.home / ".local/state/six-addons-installer").glob("install-claude-*.log"))), 1)

        before = {p: p.read_text() for p in (self.home / ".claude.json", self.home / ".claude/CLAUDE.md",
                                              self.home / ".config/ponytail/config.json")}
        self.run_main()
        calls = self.call_log()
        self.assertFalse([c for c in calls if c.startswith(("claude mcp add", "claude mcp remove",
                                                            "claude plugin marketplace add"))], calls)
        self.assertEqual({p: p.read_text() for p in before}, before)

    def test_conflicting_mcp_stops_before_any_download(self):
        original = json.dumps({"mcpServers": {"serena": {"type": "stdio", "command": "/other/serena", "args": []}}})
        (self.home / ".claude.json").write_text(original)
        result = self.run_main(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Conflito: Claude MCP serena", result.stderr + result.stdout)
        calls = self.call_log()
        self.assertNotIn("tools_install", calls)
        self.assertFalse([c for c in calls if c.startswith("claude mcp add")])
        self.assertEqual((self.home / ".claude.json").read_text(), original)
        self.assertFalse((self.home / ".claude/CLAUDE.md").exists())

    def test_legacy_context7_entry_is_migrated(self):
        legacy = ["npx", "-y", "--registry=https://registry.npmjs.org", "@upstash/context7-mcp"]
        (self.home / ".claude.json").write_text(json.dumps(
            {"mcpServers": {"context7": {"type": "stdio", "command": legacy[0], "args": legacy[1:]}}}))
        self.run_main()
        self.assertIn("claude mcp remove --scope user context7", self.call_log())
        servers = json.loads((self.home / ".claude.json").read_text())["mcpServers"]
        self.assertEqual(servers["context7"]["command"], f"{self.local_bin}/context7-mcp")

    def test_native_memory_must_be_off(self):
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        for content, ok in (('{"autoMemoryEnabled": false}', True), ('{"autoMemoryEnabled": true}', False),
                            ("{}", False)):
            with self.subTest(content=content):
                settings.write_text(content)
                result = self.run_function("claude_verify_native_memory_off", check=False)
                self.assertEqual(result.returncode == 0, ok, result.stderr)


if __name__ == "__main__":
    unittest.main()
