import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "opencode-desktop" / "ai-tooling-vm"


class OpenCodeDesktopVmTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.primary = self.home / "OrbStack/vm-one/home/alice/projeto"
        self.secondary = self.home / "OrbStack/vm-two/home/bob/projeto"
        self.outside = self.base / "outside"
        self.primary.mkdir(parents=True)
        self.secondary.mkdir(parents=True)
        self.outside.mkdir()
        config_dir = self.home / ".config/opencode"
        config_dir.mkdir(parents=True)
        (config_dir / "ai-tooling-vm.conf").write_text(
            "AI_TOOLING_VM_NAME=vm-default\n"
            "AI_TOOLING_VM_USER=carol\n"
            "AI_TOOLING_VM_HOME=/home/carol\n"
        )
        self.orb_log = self.base / "orb-calls.jsonl"
        self.orb = self.base / "orb"
        self.orb.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['ORB_LOG'], 'a') as f:\n"
            "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
        )
        self.orb.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), ORB_BIN=str(self.orb), ORB_LOG=str(self.orb_log))

    def run_adapter(self, tool, *args, cwd=None):
        return subprocess.run([str(ADAPTER), tool, *args], cwd=cwd or self.primary, env=self.env,
                              capture_output=True, text=True, check=False)

    def calls(self):
        if not self.orb_log.exists():
            return []
        return [json.loads(line) for line in self.orb_log.read_text().splitlines()]

    def test_project_vm_supports_all_adapter_tools(self):
        for tool, args in (("serena", ()), ("context7", ()), ("engram", ("mcp", "--tools=agent")),
                           ("rtk", ("git", "status")), ("ccusage", ("opencode", "daily"))):
            with self.subTest(tool=tool):
                self.orb_log.unlink(missing_ok=True)
                result = self.run_adapter(tool, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                call = self.calls()[0]
                self.assertEqual(call[:6], ["-m", "vm-one", "-u", "alice", "-w", "/home/alice/projeto"])
                if tool in ("engram", "rtk", "ccusage"):
                    self.assertEqual(call[6:], [f"/home/alice/.local/bin/{tool}", *args])
                elif tool == "serena":
                    self.assertEqual(call[6], "/home/alice/.local/bin/serena")
                    self.assertIn("start-mcp-server", call)
                    self.assertIn("--project-from-cwd", call)
                else:
                    self.assertEqual(call[6:8], ["bash", "-lc"])

    def test_second_vm_route_and_arguments_are_preserved(self):
        result = self.run_adapter("rtk", "git", "status", cwd=self.secondary)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[0]
        self.assertEqual(call[:6], ["-m", "vm-two", "-u", "bob", "-w", "/home/bob/projeto"])
        self.assertEqual(call[6:], ["/home/bob/.local/bin/rtk", "git", "status"])

    def test_fallback_and_rtk_outside_volumes(self):
        result = self.run_adapter("engram", "mcp", cwd=self.outside)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[0]
        self.assertEqual(call[:6], ["-m", "vm-default", "-u", "carol", "-w", "/home/carol"])
        self.orb_log.unlink()
        result = self.run_adapter("rtk", "git", "status", cwd=self.outside)
        self.assertEqual(result.returncode, 2)
        self.assertIn("RTK requires a project", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_unknown_tool_is_rejected_before_orbstack(self):
        result = self.run_adapter("desconhecido")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Unsupported tool", result.stderr)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
