import copy
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

from test_installers import function

try:
    import tomllib
except ImportError:
    tomllib = None


SCRIPTS = ("install-serena-ubuntu.sh", "install-context7-ubuntu.sh", "install-engram-ubuntu.sh")


@unittest.skipUnless(tomllib, "requires Python 3.11+ (tomllib)")
class CodexMcpTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.config = self.base / "config.toml"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.calls = self.base / "calls.jsonl"
        codex = self.bin / "codex"
        codex.write_text("#!" + sys.executable + "\n" + '''import json, os, pathlib, sys, tomllib
p = pathlib.Path(os.environ["CODEX_HOME"]) / "config.toml"
with open(os.environ["CODEX_TEST_CALLS"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
data = tomllib.loads(p.read_text()) if p.exists() else {}
if sys.argv[1:] == ["mcp", "list", "--json"]:
    print(json.dumps([{"name": name, "enabled": server.get("enabled", True),
        "transport": {"type": "stdio", "command": server["command"],
                      "args": server.get("args", []), "env": server.get("env")}}
        for name, server in data.get("mcp_servers", {}).items()]))
elif sys.argv[1:3] == ["mcp", "add"]:
    name = sys.argv[3]
    assert name not in data.get("mcp_servers", {})
    assert sys.argv[4] == "--"
    with p.open("a") as f:
        f.write("\\n[mcp_servers." + name + "]\\ncommand = " + json.dumps(sys.argv[5])
                + "\\nargs = " + json.dumps(sys.argv[6:]) + "\\n")
else:
    raise SystemExit("Unexpected Codex mutation: " + repr(sys.argv[1:]))
''')
        codex.chmod(0o700)

    def ensure(self, script, command="/bin/owned", args=("mcp", "--tools=all"), legacy=None):
        code = ("set -euo pipefail\n"
                "die() { echo \"$*\" >&2; exit 1; }\n"
                "assert_regular_or_absent() { [[ ! -L $1 && ( ! -e $1 || -f $1 ) ]]; }\n"
                "backup_path() { :; }\n"
                + "\n".join(function(script, name) for name in
                            ("codex_mcp_state", "update_codex_mcp", "ensure_codex_mcp"))
                + "\nensure_codex_mcp addon " + shlex.join([command, *args]) + "\n")
        env = dict(os.environ, PATH=str(self.bin) + ":/usr/bin:/bin", CODEX_HOME=str(self.base),
                   CODEX_CONFIG=str(self.config), TMP_WORKDIR=str(self.base),
                   CODEX_TEST_CALLS=str(self.calls), LEGACY_MCP_ARGV=json.dumps(legacy or []))
        return subprocess.run(["bash", "-c", code], env=env, capture_output=True, text=True)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_new_arguments_preserve_custom_settings_and_comments(self):
        old_args = '[\n  "mcp",\n  "--tools=agent",\n]'
        original = ('# user config\nmodel = "test"\n\n[mcp_servers.addon] # server note\n'
                    'command = "/bin/owned" # command note\nargs = ' + old_args + ' # args note\n'
                    'startup_timeout_sec = 60\ntool_timeout_sec = 180\n'
                    'enabled_tools = ["mem_search"]\ndisabled_tools = ["mem_delete"]\n'
                    '[mcp_servers.addon.env]\nGOMAXPROCS = "2" # env note\n'
                    '[mcp_servers.other]\ncommand = "other"\n')
        for script in SCRIPTS:
            with self.subTest(script=script):
                self.config.write_text(original)
                self.config.chmod(0o640)
                before = tomllib.loads(original)
                self.assert_ok(self.ensure(script))
                expected = copy.deepcopy(before)
                expected["mcp_servers"]["addon"]["args"] = ["mcp", "--tools=all"]
                self.assertEqual(tomllib.loads(self.config.read_text()), expected)
                self.assertEqual(self.config.read_text(), original.replace(old_args, '["mcp", "--tools=all"]'))
                self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
                first = self.config.read_bytes()
                self.assert_ok(self.ensure(script))
                self.assertEqual(self.config.read_bytes(), first)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertTrue(all(call == ["mcp", "list", "--json"] for call in calls))

    def test_legacy_command_migration_preserves_options(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                self.config.write_text('[mcp_servers.addon]\ncommand = "npx" # keep\n'
                                       'args = ["-y", "old-package"]\ntool_timeout_sec = 120\n'
                                       '[mcp_servers.addon.env]\nCUSTOM = "value"\n')
                self.assert_ok(self.ensure(script, args=(), legacy=["npx", "-y", "old-package"]))
                server = tomllib.loads(self.config.read_text())["mcp_servers"]["addon"]
                self.assertEqual(server, {"command": "/bin/owned", "args": [],
                                          "tool_timeout_sec": 120, "env": {"CUSTOM": "value"}})
                self.assertIn('command = "/bin/owned" # keep', self.config.read_text())

    def test_missing_args_are_inserted_before_env(self):
        self.config.write_text('[mcp_servers.addon]\ncommand = "/bin/owned"\n'
                               '[mcp_servers.addon.env]\nCUSTOM = "value"\n')
        self.assert_ok(self.ensure(SCRIPTS[0]))
        self.assertEqual(tomllib.loads(self.config.read_text())["mcp_servers"]["addon"],
                         {"command": "/bin/owned", "args": ["mcp", "--tools=all"],
                          "env": {"CUSTOM": "value"}})

    def test_command_only_legacy_keeps_missing_args(self):
        self.config.write_text('[mcp_servers.addon]\ncommand = "old"\nstartup_timeout_sec = 60\n')
        self.assert_ok(self.ensure(SCRIPTS[0], args=(), legacy=["old"]))
        self.assertEqual(tomllib.loads(self.config.read_text())["mcp_servers"]["addon"],
                         {"command": "/bin/owned", "startup_timeout_sec": 60})

    def test_missing_server_uses_codex_add(self):
        self.config.write_text('model = "test"\n')
        self.assert_ok(self.ensure(SCRIPTS[0]))
        self.assertEqual(tomllib.loads(self.config.read_text())["model"], "test")
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls[1], ["mcp", "add", "addon", "--", "/bin/owned", "mcp", "--tools=all"])

    def test_foreign_disabled_and_unrecognized_toml_are_preserved(self):
        cases = ('[mcp_servers.addon]\ncommand = "foreign"\n',
                 '[mcp_servers.addon]\ncommand = "/bin/owned"\nenabled = false\n',
                 'mcp_servers.addon = {command = "/bin/owned", args = ["old"]}\n',
                 '[mcp_servers.addon]\ncommand = "/bin/owned"\nargs = [\n"old", # keep argument note\n]\n',
                 '[mcp_servers.addon]\ncommand = "/bin/owned"\ncommand = "duplicate"\n')
        for original in cases:
            with self.subTest(original=original):
                self.config.write_text(original)
                self.assertNotEqual(self.ensure(SCRIPTS[0]).returncode, 0)
                self.assertEqual(self.config.read_text(), original)


if __name__ == "__main__":
    unittest.main()
