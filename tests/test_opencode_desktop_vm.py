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
        self.personal = self.home / "OrbStack/vm-pessoal/home/vitor/projeto"
        self.trt4 = self.home / "OrbStack/vm-trt4/home/vitorcsilva/projeto"
        self.outside = self.base / "outside"
        self.personal.mkdir(parents=True)
        self.trt4.mkdir(parents=True)
        self.outside.mkdir()
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
        return subprocess.run([str(ADAPTER), tool, *args], cwd=cwd or self.personal, env=self.env,
                              capture_output=True, text=True, check=False)

    def calls(self):
        if not self.orb_log.exists():
            return []
        return [json.loads(line) for line in self.orb_log.read_text().splitlines()]

    def test_personal_vm_supports_all_adapter_tools(self):
        for tool, args in (("serena", ()), ("context7", ()), ("engram", ("mcp", "--tools=agent")),
                           ("rtk", ("git", "status")), ("ccusage", ("opencode", "daily"))):
            with self.subTest(tool=tool):
                self.orb_log.unlink(missing_ok=True)
                result = self.run_adapter(tool, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                call = self.calls()[0]
                self.assertEqual(call[:6], ["-m", "vm-pessoal", "-u", "vitor", "-w", "/home/vitor/projeto"])
                if tool in ("engram", "rtk", "ccusage"):
                    self.assertEqual(call[6:], [f"/home/vitor/.local/bin/{tool}", *args])
                elif tool == "serena":
                    self.assertEqual(call[6], "/home/vitor/.local/bin/serena")
                    self.assertIn("start-mcp-server", call)
                    self.assertIn("--project-from-cwd", call)
                else:
                    self.assertEqual(call[6:8], ["bash", "-lc"])

    def test_trt4_route_and_arguments_are_preserved(self):
        result = self.run_adapter("rtk", "git", "status", cwd=self.trt4)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[0]
        self.assertEqual(call[:6], ["-m", "vm-trt4", "-u", "vitorcsilva", "-w", "/home/vitorcsilva/projeto"])
        self.assertEqual(call[6:], ["/home/vitorcsilva/.local/bin/rtk", "git", "status"])

    def test_fallback_and_rtk_outside_volumes(self):
        result = self.run_adapter("engram", "mcp", cwd=self.outside)
        self.assertEqual(result.returncode, 0, result.stderr)
        call = self.calls()[0]
        self.assertEqual(call[:6], ["-m", "vm-pessoal", "-u", "vitor", "-w", "/home/vitor"])
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
