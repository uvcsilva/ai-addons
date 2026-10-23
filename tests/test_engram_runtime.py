import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_installers import function


class EngramRuntimeTest(unittest.TestCase):
    def probe(self, response, *, installed="engram 3.5.2", curl_status=0, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            curl = base / "curl"
            curl.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$CURL_ARGS\"\n"
                            "printf '%s' \"$HEALTH_RESPONSE\"\nexit \"$CURL_STATUS\"\n")
            curl.chmod(0o700)
            env = dict(os.environ, PATH=f"{base}:/usr/bin:/bin", CURL_ARGS=str(base / "args"),
                       HEALTH_RESPONSE=response, CURL_STATUS=str(curl_status))
            for key in ("ENGRAM_URL", "ENGRAM_PORT", "ENGRAM_SOCKET"):
                env.pop(key, None)
            env.update(overrides)
            result = subprocess.run(
                ["bash", "-c", "set -euo pipefail\n"
                 + function("install-engram-ubuntu.sh", "warn_engram_runtime_version")
                 + "\nwarn_engram_runtime_version " + shlex.quote(installed)],
                env=env, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stderr, (base / "args").read_text().splitlines()

    def test_warns_for_older_daemon_without_stopping_it(self):
        warning, args = self.probe(json.dumps({"service": "engram", "status": "ok", "version": "3.4.0"}))
        self.assertIn("[AVISO]", warning)
        self.assertIn("3.4.0", warning)
        self.assertIn("3.5.2", warning)
        self.assertIn("Encerre as sessoes", warning)
        self.assertIn("nao reiniciou processos", warning)
        self.assertEqual(args, ["--silent", "--fail", "--max-time", "2", "http://127.0.0.1:7437/health"])

    def test_current_or_newer_daemon_needs_no_restart(self):
        for version in ("3.5.2", "3.10.0", "4.0.0", "v3.5.2"):
            with self.subTest(version=version):
                warning, _ = self.probe(json.dumps({"service": "engram", "status": "ok", "version": version}))
                self.assertEqual(warning, "")

    def test_unavailable_or_invalid_health_does_not_fail_installation(self):
        for body, status in (("", 7), ("not json", 0), ("[]", 0), ("{}", 0),
                             ('{"service":"other","status":"ok","version":"3.0.0"}', 0),
                             ('{"service":"engram","status":"ok","version":3}', 0),
                             ('{"service":"engram","status":"ok","version":"dev"}', 0)):
            with self.subTest(body=body, status=status):
                warning, _ = self.probe(body, curl_status=status)
                self.assertEqual(warning, "")

    def test_probe_uses_configured_transport(self):
        for overrides, expected in (
                ({"ENGRAM_PORT": "7440"}, ["http://127.0.0.1:7440/health"]),
                ({"ENGRAM_SOCKET": "/tmp/engram.sock"}, ["--unix-socket", "/tmp/engram.sock", "http://localhost/health"]),
                ({"ENGRAM_URL": "https://memory.example/", "ENGRAM_SOCKET": "/ignored"}, ["https://memory.example/health"])):
            with self.subTest(overrides=overrides):
                _, args = self.probe("{}", **overrides)
                self.assertEqual(args[4:], expected)


if __name__ == "__main__":
    unittest.main()
