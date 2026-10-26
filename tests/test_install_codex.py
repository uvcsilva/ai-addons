import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from provider_harness import ROOT, ProviderInstallerTest  # noqa: E402

try:
    import tomllib
except ImportError:
    tomllib = None

SCRIPT = ROOT / "install-codex-ubuntu.sh"

# Codex keeps MCP servers in config.toml; plugins live in a state file of the fake.
FAKE_CODEX = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, tomllib
args = sys.argv[1:]
home = pathlib.Path(os.environ["HOME"])
config = home / ".codex/config.toml"
state = home / "fake-codex-plugins.json"
with open(os.environ["CALLS"], "a") as f:
    f.write("codex " + " ".join(args) + "\n")
data = tomllib.loads(config.read_text()) if config.exists() else {}
plugins = json.loads(state.read_text()) if state.exists() else []
def add_plugin(name):
    plugins.append({"name": name, "marketplaceName": name, "installed": True, "enabled": True})
    state.write_text(json.dumps(plugins))
if args == ["--version"]:
    print("codex-cli 0.130.0")
elif args == ["mcp", "list", "--json"]:
    print(json.dumps([{"name": name, "enabled": server.get("enabled", True),
        "transport": {"type": "stdio", "command": server["command"], "args": server.get("args", []),
                      "env": server.get("env")}} for name, server in data.get("mcp_servers", {}).items()]))
elif args[:2] == ["mcp", "add"]:
    assert args[2] not in data.get("mcp_servers", {}) and args[3] == "--"
    config.parent.mkdir(parents=True, exist_ok=True)
    with config.open("a") as f:
        f.write("\n[mcp_servers." + args[2] + "]\ncommand = " + json.dumps(args[4]) + "\nargs = " + json.dumps(args[5:]) + "\n")
elif args[:3] == ["plugin", "marketplace", "add"]:
    marker = home / "fake-codex-marketplace"
    if marker.exists():
        print("Marketplace already added"); sys.exit(1)
    marker.write_text(args[3])
elif args == ["plugin", "list", "--json"]:
    print(json.dumps({"installed": plugins}))
elif args[:2] == ["plugin", "add"]:
    add_plugin(args[2].split("@")[0])
else:
    raise SystemExit("Unexpected Codex call: " + repr(args))
'''

FAKE_ENGRAM = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
home = pathlib.Path(os.environ["HOME"])
with open(os.environ["CALLS"], "a") as f:
    f.write("engram " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["setup", "codex"]:
    state = home / "fake-codex-plugins.json"
    plugins = json.loads(state.read_text()) if state.exists() else []
    if not any(p["name"] == "engram" for p in plugins):
        plugins.append({"name": "engram", "marketplaceName": "engram", "installed": True, "enabled": True})
    state.write_text(json.dumps(plugins))
'''

# Refuses the flags rtk init --codex refuses (src/hooks/init/mod.rs).
FAKE_RTK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
home = pathlib.Path(os.environ["HOME"])
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f:
    f.write("rtk " + " ".join(args) + "\n")
if "--codex" in args and {"--hook-only", "--auto-patch", "--no-patch", "--claude-md"} & set(args):
    sys.exit(1)
if args[:1] == ["init"]:
    p = home / ".codex/hooks.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "rtk hook codex"}]}]}}))
'''


@unittest.skipUnless(tomllib, "requires Python 3.11+ (tomllib)")
class CodexInstallerTest(ProviderInstallerTest):
    SCRIPT = SCRIPT

    def setUp(self):
        super().setUp()
        self.executable(self.fake / "codex", FAKE_CODEX)
        self.executable(self.local_bin / "engram", FAKE_ENGRAM)
        self.executable(self.local_bin / "rtk", FAKE_RTK)
        self.codex = self.home / ".codex"

    def test_dry_run_writes_nothing(self):
        out = self.assert_dry_run_writes_nothing()
        self.assertIn("Simulacao do Codex", out)
        self.assertIn("rtk init --global --codex --no-trust-filters", out)

    def test_invalid_arguments_and_config_exit_2(self):
        self.assert_bad_arguments_exit_2()

    def test_flow_configures_every_addon_and_is_idempotent(self):
        self.run_main()
        bin_ = str(self.local_bin)
        calls = self.call_log()
        self.assert_in_order(calls, [
            "tools_check", "tools_install", "engram setup codex",
            f"codex mcp add engram -- {bin_}/engram mcp --tools=agent", "serena start-mcp-server --help",
            "rtk init --global --codex --no-trust-filters",
            "codex plugin marketplace add DietrichGebert/ponytail", "codex plugin add ponytail@ponytail"])
        self.assertNotIn("tools_install_ccusage", calls)

        config = tomllib.loads((self.codex / "config.toml").read_text())
        servers = config["mcp_servers"]
        self.assertEqual(servers["engram"], {"command": f"{bin_}/engram", "args": ["mcp", "--tools=agent"]})
        self.assertEqual(servers["serena"]["args"], [
            "start-mcp-server", "--context", "codex", "--project-from-cwd", "--add-mode", "no-memories",
            "--log-level", "INFO", "--add-mode", "planning"])
        self.assertEqual(servers["context7"], {"command": f"{bin_}/context7-mcp", "args": []})
        self.assertIs(config["features"]["memories"], False)
        self.assertEqual(config["memories"], {"use_memories": False, "generate_memories": False})
        rules = (self.codex / "AGENTS.md").read_text()
        for addon in ("serena", "context7"):
            self.assertIn(f"<!-- six-addons:{addon}:begin -->", rules)
        for addon in ("engram", "rtk", "ponytail"):
            self.assertNotIn(f"six-addons:{addon}", rules)
        self.assertEqual(json.loads((self.home / ".config/ponytail/config.json").read_text())["defaultMode"], "full")

        before = {p: p.read_text() for p in (self.codex / "config.toml", self.codex / "AGENTS.md",
                                              self.home / ".config/ponytail/config.json")}
        result = self.run_main()
        self.assertIn("abra /hooks", result.stdout)
        calls = self.call_log()
        self.assertFalse([c for c in calls if c.startswith(("codex mcp add", "codex plugin add"))], calls)
        self.assertEqual({p: p.read_text() for p in before}, before)

    def test_conflicting_mcp_stops_before_any_download(self):
        self.codex.mkdir()
        original = '[mcp_servers.serena]\ncommand = "/other/serena"\nargs = []\n'
        (self.codex / "config.toml").write_text(original)
        result = self.run_main(check=False)
        self.assertNotEqual(result.returncode, 0)
        calls = self.call_log()
        self.assertNotIn("tools_install", calls)
        self.assertFalse([c for c in calls if c.startswith("codex mcp add")])
        self.assertEqual((self.codex / "config.toml").read_text(), original)
        self.assertFalse((self.codex / "AGENTS.md").exists())

    def test_native_memory_must_be_off(self):
        self.codex.mkdir()
        good = "[features]\nmemories = false\n\n[memories]\nuse_memories = false\ngenerate_memories = false\n"
        for content, ok in ((good, True), ("[features]\nmemories = false\n", False),
                            (good.replace("use_memories = false", "use_memories = true"), False)):
            with self.subTest(content=content):
                (self.codex / "config.toml").write_text(content)
                result = self.run_function("codex_verify_native_memory_off", check=False)
                self.assertEqual(result.returncode == 0, ok, result.stderr)


if __name__ == "__main__":
    unittest.main()
