import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from provider_harness import ROOT, ProviderInstallerTest  # noqa: E402

SCRIPT = ROOT / "install-kimi-ubuntu.sh"

FAKE_KIMI = r'''#!/usr/bin/env python3
import os, sys
with open(os.environ["CALLS"], "a") as f:
    f.write("kimi " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["--version"]:
    print("kimi-code 1.0.0")
else:
    raise SystemExit("Unexpected kimi call: " + repr(sys.argv[1:]))
'''

FAKE_ENGRAM = r'''#!/usr/bin/env python3
import os, pathlib, sys
with open(os.environ["CALLS"], "a") as f:
    f.write("engram " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["setup", "kimi"]:
    root = pathlib.Path(os.environ.get("KIMI_CODE_HOME") or pathlib.Path(os.environ["HOME"]) / ".kimi-code")
    root.mkdir(parents=True, exist_ok=True)
    rules = root / "AGENTS.md"
    text = rules.read_text() if rules.exists() else ""
    if "engram" not in text.lower():
        rules.write_text(text + ("\n" if text else "") + "# Engram\nUse engram memory.\n")
else:
    raise SystemExit("Unexpected engram call: " + repr(sys.argv[1:]))
'''

FAKE_RTK = r'''#!/usr/bin/env python3
import os, pathlib, sys
with open(os.environ["CALLS"], "a") as f:
    f.write("rtk " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["init", "--agent", "kimi"]:
    pathlib.Path("AGENTS.md").write_text("# RTK\nPrefix shell commands with rtk.\n")
else:
    raise SystemExit("Unexpected rtk call: " + repr(sys.argv[1:]))
'''


class KimiInstallerTest(ProviderInstallerTest):
    SCRIPT = SCRIPT

    def setUp(self):
        super().setUp()
        self.executable(self.fake / "kimi", FAKE_KIMI)
        self.executable(self.local_bin / "engram", FAKE_ENGRAM)
        self.executable(self.local_bin / "rtk", FAKE_RTK)
        self.kimi = self.home / ".kimi-code"
        self.settings = self.kimi / "mcp.json"
        self.rules = self.kimi / "AGENTS.md"

    def test_dry_run_writes_nothing(self):
        out = self.assert_dry_run_writes_nothing("--project-dir", "/srv/app")
        self.assertIn("Simulacao do Kimi Code", out)
        self.assertIn("--context ide --add-mode no-memories --project /srv/app", out)
        self.assertIn("engram setup kimi", out)

    def test_invalid_arguments_and_config_exit_2(self):
        self.assert_bad_arguments_exit_2(["--project-dir", "rel", "--dry-run"])
        result = self.run_script("--config", str(self.config), "--dry-run", check=False,
                                 KIMI_CODE_HOME="relative")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Caminho precisa ser absoluto", result.stderr)

    def test_flow_configures_every_addon_and_is_idempotent(self):
        self.kimi.mkdir(parents=True)
        self.settings.write_text(json.dumps({"mcpServers": {"other": {"command": "/bin/other", "args": []}}}))
        self.rules.write_text("# Minhas regras\nPreserve esta instrucao.\n")
        config_toml = self.kimi / "config.toml"
        config_toml.write_text('model = "moonshotai/kimi-k2"\n')

        self.run_main("--project-dir", "/srv/app")
        self.assert_in_order(self.call_log(), [
            "kimi --version", "tools_check", "tools_install", "engram setup kimi",
            "serena start-mcp-server --help", "rtk init --agent kimi"])
        bin_ = str(self.local_bin)
        servers = json.loads(self.settings.read_text())["mcpServers"]
        self.assertEqual(servers["other"], {"command": "/bin/other", "args": []})
        self.assertEqual(servers["engram"], {"command": f"{bin_}/engram", "args": ["mcp", "--tools=agent"]})
        self.assertEqual(servers["serena"]["args"], [
            "start-mcp-server", "--context", "ide", "--add-mode", "no-memories", "--project", "/srv/app",
            "--log-level", "INFO", "--add-mode", "planning"])
        self.assertEqual(servers["context7"]["args"], [])
        rules = self.rules.read_text()
        self.assertTrue(rules.startswith("# Minhas regras\nPreserve esta instrucao.\n"))
        self.assertIn("Use engram memory", rules)
        self.assertNotIn("unmanaged section", rules)
        for addon in ("serena", "context7", "rtk", "ponytail", "graphify"):
            self.assertIn(f"<!-- six-addons:{addon}:begin -->", rules)
        self.assertNotIn("<!-- six-addons:engram:begin -->", rules)
        self.assertIn("Prefix shell commands with rtk", rules)
        self.assertNotIn("## Level:", rules)
        self.assert_graphify_skill(self.kimi / "skills/graphify")
        self.assertEqual(config_toml.read_text(), 'model = "moonshotai/kimi-k2"\n')

        files = [self.settings, self.rules, config_toml]
        before = {p: p.read_text() for p in files}
        self.run_main("--project-dir", "/srv/app")
        self.assertEqual({p: p.read_text() for p in files}, before)

    def test_kimi_code_home_is_respected(self):
        custom = self.home / "custom-kimi"
        self.run_main(KIMI_CODE_HOME=str(custom))
        self.assertTrue((custom / "mcp.json").is_file())
        self.assertTrue((custom / "skills/graphify/SKILL.md").is_file())
        self.assertFalse(self.kimi.exists())
        self.assertNotIn("unmanaged section", (custom / "AGENTS.md").read_text())

    def test_conflicting_mcp_stops_before_any_download(self):
        self.kimi.mkdir(parents=True)
        original = json.dumps({"mcpServers": {"serena": {"command": "/other/serena", "args": []}}})
        self.settings.write_text(original)
        result = self.run_main(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Conflito MCP serena", result.stdout + result.stderr)
        self.assertNotIn("tools_install", self.call_log())
        self.assertEqual(self.settings.read_text(), original)
        self.assertFalse(self.rules.exists())


if __name__ == "__main__":
    unittest.main()
