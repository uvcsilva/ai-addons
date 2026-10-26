import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from provider_harness import ROOT, ProviderInstallerTest  # noqa: E402

SCRIPT = ROOT / "install-cline-ubuntu.sh"

FAKE_RTK = r'''#!/usr/bin/env python3
import os, pathlib, sys
with open(os.environ["CALLS"], "a") as f:
    f.write("rtk " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["init", "--agent", "cline"]:
    pathlib.Path(".clinerules").write_text("# RTK\nPrefix shell commands with rtk.\n")
'''


class ClineInstallerTest(ProviderInstallerTest):
    SCRIPT = SCRIPT

    def setUp(self):
        super().setUp()
        self.executable(self.local_bin / "rtk", FAKE_RTK)
        self.settings = self.home / ".cline/data/settings/cline_mcp_settings.json"
        self.rules = self.home / ".cline/rules"

    def test_dry_run_writes_nothing(self):
        out = self.assert_dry_run_writes_nothing("--project-dir", "/srv/app")
        self.assertIn("Simulacao do Cline", out)
        self.assertIn("--context ide --add-mode no-memories --project /srv/app", out)

    def test_invalid_arguments_and_config_exit_2(self):
        self.assert_bad_arguments_exit_2(["--cline-config", "relative.json", "--dry-run"])

    def test_flow_configures_every_addon_and_is_idempotent(self):
        self.run_main("--project-dir", "/srv/app")
        self.assert_in_order(self.call_log(), ["tools_check", "tools_install", "serena start-mcp-server --help",
                                               "rtk init --agent cline"])
        bin_ = str(self.local_bin)
        servers = json.loads(self.settings.read_text())["mcpServers"]
        self.assertEqual(servers["engram"], {"command": f"{bin_}/engram", "args": ["mcp", "--tools=agent"],
                                             "disabled": False, "autoApprove": []})
        self.assertEqual(servers["serena"]["args"], [
            "start-mcp-server", "--context", "ide", "--add-mode", "no-memories", "--project", "/srv/app",
            "--log-level", "INFO", "--add-mode", "planning"])
        self.assertEqual(servers["context7"]["args"], [])
        for addon in ("engram", "serena", "context7", "rtk", "ponytail"):
            text = (self.rules / f"six-addons-{addon}.md").read_text()
            self.assertTrue(text.startswith(f"<!-- six-addons:{addon}:begin -->"), addon)
        self.assertIn("Prefix shell commands with rtk", (self.rules / "six-addons-rtk.md").read_text())
        self.assertNotIn("## Level:", (self.rules / "six-addons-ponytail.md").read_text())  # mode full

        files = [self.settings, *sorted(self.rules.iterdir())]
        before = {p: p.read_text() for p in files}
        self.run_main("--project-dir", "/srv/app")
        self.assertEqual({p: p.read_text() for p in files}, before)

    def test_cline_config_precedence(self):
        env_file, option_file, flag_file = (self.home / n for n in ("env.json", "option.json", "flag.json"))
        self.run_main(CLINE_MCP_SETTINGS_PATH=str(env_file))
        self.assertTrue(env_file.exists())
        self.config.write_text(json.dumps({**self.CONFIG, "options": {"cline-config": str(option_file)}}))
        self.run_main(CLINE_MCP_SETTINGS_PATH=str(env_file))
        self.assertTrue(option_file.exists())
        self.run_main("--cline-config", str(flag_file), CLINE_MCP_SETTINGS_PATH=str(env_file))
        self.assertTrue(flag_file.exists())
        self.assertFalse(self.settings.exists())

    def test_conflicting_mcp_stops_before_any_download(self):
        self.settings.parent.mkdir(parents=True)
        original = json.dumps({"mcpServers": {"engram": {"command": "/other/engram", "args": []}}})
        self.settings.write_text(original)
        result = self.run_main(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Conflito MCP engram", result.stdout + result.stderr)
        self.assertNotIn("tools_install", self.call_log())
        self.assertEqual(self.settings.read_text(), original)
        self.assertFalse(self.rules.exists())


if __name__ == "__main__":
    unittest.main()
