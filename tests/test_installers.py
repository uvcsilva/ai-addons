import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def function(script, name):
    text = (ROOT / script).read_text()
    return re.search(r"^" + name + r"\(\) \{\n.*?^\}", text, re.M | re.S).group()


class InstallersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()

    def run_shell(self, code, check=True):
        env = dict(os.environ, PATH=str(self.bin) + ":/usr/bin:/bin")
        result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + code],
                                env=env, text=True, capture_output=True)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def executable(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o700)

    def prepare_go(self, bad_checksum=False):
        archive = self.base / "fixture-go.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for name in ("go", "gofmt"):
                body = b"#!/bin/sh\nexit 0\n"
                info = tarfile.TarInfo("go/bin/" + name)
                info.size, info.mode = len(body), 0o755
                tar.addfile(info, io.BytesIO(body))
        checksum = "0" * 64 if bad_checksum else hashlib.sha256(archive.read_bytes()).hexdigest()
        release = self.base / "releases.json"
        release.write_text(json.dumps([{"stable": True, "files": [{
            "os": "linux", "arch": "arm64", "kind": "archive",
            "version": "go1.27.2", "filename": "go1.27.2.linux-arm64.tar.gz",
            "sha256": checksum}]}]))
        self.executable("uname", "echo aarch64\n")
        self.executable("curl", "src=" + shlex.quote(str(archive)) + "\n"
                        "for arg in \"$@\"; do [[ $arg != *mode=json* ]] || src="
                        + shlex.quote(str(release)) + "; done\n"
                        "cp \"$src\" \"${@: -1}\"\n")
        self.executable("gopls", "exit 0\n")
        tool = self.base / "uv/serena-agent/bin"
        tool.mkdir(parents=True)
        (tool / "python").symlink_to(sys.executable)
        return (f"HOME_DIR={shlex.quote(str(self.base))}\n"
                f"LOCAL_BIN={shlex.quote(str(self.bin))}\n"
                f"TMP_WORKDIR={shlex.quote(str(self.base))}\n"
                f"UV_TOOL_DIR={shlex.quote(str(self.base / 'uv'))}\n"
                "die() { echo \"$*\" >&2; exit 1; }\n"
                + function("install-serena-ubuntu.sh", "prepare_go") + "\nprepare_go\n")

    def test_arm64_download_and_checksum(self):
        self.run_shell(self.prepare_go())
        self.assertTrue((self.bin / "go").is_symlink())
        self.assertTrue((self.bin / "gofmt").is_file())

    def test_bad_checksum_does_not_install(self):
        result = self.run_shell(self.prepare_go(bad_checksum=True), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.bin / "go").exists())

    def test_existing_destination_is_preserved(self):
        code = self.prepare_go()
        dest = self.base / ".local/lib/go/go1.27.2"
        dest.mkdir(parents=True)
        (dest / "keep").write_text("original")
        self.assertNotEqual(self.run_shell(code, check=False).returncode, 0)
        self.assertEqual((dest / "keep").read_text(), "original")

    def test_existing_tools_skip_download(self):
        code = self.prepare_go()
        self.executable("go", "exit 0\n")
        self.executable("curl", "exit 99\n")
        self.run_shell(code)
        self.assertFalse((self.bin / "go").is_symlink())

    def test_gopls_install_limits_compilation(self):
        code = self.prepare_go()
        (self.bin / "gopls").unlink()
        self.executable("go", 'if [[ "$1" == install ]]; then\n'
                        ' [[ "$GOMAXPROCS" == 2 && "$2" == -p=1 ]]\n'
                        ' printf "#!/bin/sh\\nexit 0\\n" > "$GOBIN/gopls"\n'
                        ' chmod 700 "$GOBIN/gopls"\nfi\n')
        self.run_shell(code)
        self.assertTrue((self.bin / "gopls").exists())

    def test_corrupt_rule_block_is_not_overwritten(self):
        target, source = self.base / "AGENTS.md", self.base / "rule.md"
        original = "User rules\n<!-- six-addons:serena:begin -->\n"
        target.write_text(original)
        source.write_text("New rule")
        code = ("ADDON=serena\nassert_regular_or_absent() { :; }\nbackup_path() { :; }\n"
                + function("install-serena-ubuntu.sh", "write_managed_rule") + "\n"
                + f"write_managed_rule {shlex.quote(str(target))} {shlex.quote(str(source))}\n")
        self.assertNotEqual(self.run_shell(code, check=False).returncode, 0)
        self.assertEqual(target.read_text(), original)

    def test_managed_rules_preserve_other_instructions(self):
        for script, addon in [("install-serena-ubuntu.sh", "serena"),
                              ("install-context7-ubuntu.sh", "context7")]:
            with self.subTest(addon=addon):
                target, source = self.base / "AGENTS.md", self.base / "rule.md"
                target.write_text("Existing user instructions\n")
                source.write_text("Use " + addon + "\n")
                code = (f"ADDON={addon}\n"
                        "assert_regular_or_absent() { :; }\nbackup_path() { :; }\n"
                        + function(script, "write_managed_rule") + "\n"
                        + f"write_managed_rule {shlex.quote(str(target))} {shlex.quote(str(source))}\n")
                self.run_shell(code)
                first = target.read_text()
                self.run_shell(code)
                self.assertEqual(target.read_text(), first)
                self.assertTrue(first.startswith("Existing user instructions\n"))
                source.write_text("Updated rule\n")
                self.run_shell(code)
                self.assertIn("Updated rule", target.read_text())
                self.assertNotIn("Use " + addon, target.read_text())

    def test_dry_run_has_no_files(self):
        home = self.base / "empty-home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), CODEX_HOME=str(home / ".codex"),
                   XDG_STATE_HOME=str(home / "state"))
        result = subprocess.run(["bash", str(ROOT / "install-serena-ubuntu.sh"),
                                 "--clients", "codex", "--with-go", "--check-go-project",
                                 "/tmp/project", "--dry-run"], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(list(home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
