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

    def test_claude_mcp_timeout_raises_but_never_lowers(self):
        settings = self.base / "settings.json"
        for script in ("install-serena-ubuntu.sh", "install-context7-ubuntu.sh"):
            code = (f"CLAUDE_SETTINGS={shlex.quote(str(settings))}\n"
                    + function(script, "set_claude_mcp_timeout") + "\nset_claude_mcp_timeout\n")
            for before, after in [(None, "60000"), ({"MCP_TIMEOUT": "30000"}, "60000"),
                                  ({"MCP_TIMEOUT": "90000"}, "90000")]:
                with self.subTest(script=script, before=before):
                    settings.write_text(json.dumps({"model": "x", **({"env": before} if before else {})}))
                    self.run_shell(code)
                    data = json.loads(settings.read_text())
                    self.assertEqual(data["env"]["MCP_TIMEOUT"], after)
                    self.assertEqual(data["model"], "x")
            settings.write_text('{"env": []}')
            self.assertNotEqual(self.run_shell(code, check=False).returncode, 0)
            self.assertEqual(settings.read_text(), '{"env": []}')

    def test_shared_helpers_are_identical(self):
        # Scripts stay standalone, so every helper copy must change together.
        copies = {}
        for script in sorted(ROOT.glob("install-*-ubuntu.sh")):
            if script.name == "install-dependencies-ubuntu.sh":
                continue
            for m in re.finditer(r"^(\w+)\(\) \{\n.*?^\}", script.read_text(), re.M | re.S):
                if m.group(1) == "usage" or (m.group(1) == "all_mcp" and "serena" in script.name):
                    continue
                copies.setdefault(m.group(1), {})[script.name] = m.group()
        for name, bodies in copies.items():
            with self.subTest(function=name):
                self.assertEqual(len(set(bodies.values())), 1, f"{name} diverge: {sorted(bodies)}")

    def test_plugin_backup_skips_caches(self):
        plugins, backups = self.base / "plugins", self.base / "backups"
        for rel in ("cache/x", "marketplaces/y", "data/z", "installed_plugins.json", ".staging/w"):
            (plugins / rel).parent.mkdir(parents=True, exist_ok=True)
            (plugins / rel).write_text("1")
        backups.mkdir()
        script = "install-engram-ubuntu.sh"
        self.run_shell(f"BACKUP_DIR={shlex.quote(str(backups))}\n"
                       + function(script, "backup_path") + "\n"
                       + function(script, "backup_plugins_dir") + "\n"
                       + f"backup_plugins_dir {shlex.quote(str(plugins))}\n"
                       + f"backup_plugins_dir {shlex.quote(str(self.base / 'missing'))}\n")
        self.assertEqual(sorted(p.name.rsplit("_plugins_", 1)[1] for p in backups.iterdir()),
                         ["data", "installed_plugins.json"])

    def test_native_memory_checked_per_client(self):
        settings, config = self.base / "settings.json", self.base / "config.toml"
        good_toml = ("[features]\nmemories = false\n\n"
                     "[memories]\nuse_memories = false\ngenerate_memories = false\n")
        settings.write_text('{"autoMemoryEnabled": false}')
        func = function("install-engram-ubuntu.sh", "verify_native_memory_off")
        def check(clients):
            return self.run_shell(f"CLAUDE_SETTINGS={shlex.quote(str(settings))}\n"
                                  f"CODEX_CONFIG={shlex.quote(str(config))}\nCLIENTS={clients}\n"
                                  + func + "\nverify_native_memory_off\n", check=False).returncode
        self.assertEqual(check("claude"), 0)  # no config.toml needed
        config.write_text("[features]\nmemories = false\n")
        self.assertNotEqual(check("codex"), 0)
        config.write_text(good_toml)
        self.assertEqual(check("claude,codex"), 0)

    LEGACY = '["npx","-y","@upstash/context7-mcp"]'

    def edit_json(self, target, kind="cline", legacy=None, mode="apply", command="/bin/c7"):
        script = "install-context7-ubuntu.sh"
        return self.run_shell(
            (f"export LEGACY_MCP_ARGV={shlex.quote(legacy)}\n" if legacy else "")
            + "OPENCODE_MAJOR=\nassert_regular_or_absent() { :; }\nbackup_path() { :; }\n"
            + function(script, "edit_client_json") + "\n"
            + f"edit_client_json {mode} {shlex.quote(str(target))} {kind} context7 {command}\n",
            check=False)

    def test_jsonc_edit_keeps_comments_and_is_idempotent(self):
        target = self.base / "mcp.jsonc"
        target.write_text('{\n  // keep me\n  "url": "http://x//y", /* block */\n'
                          '  "mcpServers": {\n    "other": {"command": "o"},\n  },\n}\n')
        self.assertEqual(self.edit_json(target).returncode, 0)
        first = target.read_text()
        for kept in ("// keep me", "/* block */", '"http://x//y"', '"other"'):
            self.assertIn(kept, first)
        self.assertEqual(self.edit_json(target).returncode, 0)
        self.assertEqual(target.read_text(), first)
        self.assertEqual(self.edit_json(target, mode="verify").returncode, 0)

    def test_jsonc_conflict_and_legacy_migration(self):
        target = self.base / "mcp.json"
        npx = self.bin / "npx"
        self.executable("npx", "exit 0\n")
        legacy = {"mcpServers": {"context7": {"command": str(npx), "args": ["-y", "@upstash/context7-mcp"],
                                              "disabled": False, "autoApprove": []}}}
        target.write_text(json.dumps(legacy))
        before = target.read_text()
        self.assertNotEqual(self.edit_json(target).returncode, 0)  # no legacy hint: conflict
        self.assertEqual(target.read_text(), before)
        self.assertNotEqual(self.edit_json(target, legacy='["npx","-y","other"]').returncode, 0)
        self.assertEqual(target.read_text(), before)
        self.assertEqual(self.edit_json(target, legacy=self.LEGACY).returncode, 0)
        self.assertEqual(json.loads(target.read_text())["mcpServers"]["context7"]["command"], "/bin/c7")

    def test_claude_mcp_legacy_entry_is_migrated(self):
        claude_json = self.base / ".claude.json"
        log = self.base / "claude.log"
        new = {"type": "stdio", "command": "/bin/c7", "args": []}
        old = {"type": "stdio", "command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
        # Fake CLI: log calls and write the new entry on add.
        self.executable("claude", f"echo \"$*\" >> {shlex.quote(str(log))}\n"
                        f"[[ $2 != add ]] || echo {shlex.quote(json.dumps({'mcpServers': {'context7': new}}))}"
                        f" > {shlex.quote(str(claude_json))}\n")
        script = "install-context7-ubuntu.sh"
        code = (f"CLAUDE_JSON={shlex.quote(str(claude_json))}\n"
                "die() { echo \"$*\" >&2; exit 1; }\n"
                + function(script, "claude_mcp_state") + "\n"
                + function(script, "ensure_claude_mcp") + "\n")
        for entry, legacy, ok in [(old, self.LEGACY, True), (old, None, False),
                                  ({**old, "args": ["x"]}, self.LEGACY, False), (new, self.LEGACY, True)]:
            with self.subTest(entry=entry, legacy=legacy):
                claude_json.write_text(json.dumps({"mcpServers": {"context7": entry}}))
                log.write_text("")
                result = self.run_shell((f"export LEGACY_MCP_ARGV={shlex.quote(legacy)}\n" if legacy else "")
                                        + code + "ensure_claude_mcp context7 /bin/c7\n", check=False)
                self.assertEqual(result.returncode == 0, ok, result.stderr)
                calls = log.read_text()
                if entry is old and ok:
                    self.assertIn("mcp remove --scope user context7", calls)
                    self.assertIn("migrado", result.stdout)
                elif entry is new:
                    self.assertEqual(calls, "")

    def test_codex_toml_memory_edit_is_minimal(self):
        import tomllib
        config = self.base / "config.toml"
        code = (f"CODEX_CONFIG={shlex.quote(str(config))}\n"
                + function("install-engram-ubuntu.sh", "set_codex_native_memory_off")
                + "\nset_codex_native_memory_off\n")
        config.write_text('model = "x"\n\n[features]\nother = true # note\n\n'
                          '[mcp_servers.foo]\ncommand = "foo"\n')
        before = tomllib.loads(config.read_text())
        self.run_shell(code)
        after = tomllib.loads(config.read_text())
        self.assertEqual(after["features"], {"other": True, "memories": False})
        self.assertEqual(after["memories"], {"use_memories": False, "generate_memories": False})
        self.assertEqual({k: v for k, v in after.items() if k != "memories"},
                         {**before, "features": after["features"]})
        self.assertIn("# note", config.read_text())
        first = config.read_text()
        self.run_shell(code)
        self.assertEqual(config.read_text(), first)
        duplicated = "[features]\na = 1\n[features]\nb = 2\n"
        config.write_text(duplicated)
        self.assertNotEqual(self.run_shell(code, check=False).returncode, 0)
        self.assertEqual(config.read_text(), duplicated)
        config.unlink()
        self.run_shell(code)
        self.assertEqual(tomllib.loads(config.read_text())["features"], {"memories": False})

    def test_prune_old_node_keeps_current(self):
        root = self.base / "nodejs"
        for d in ("node-v22.0.0-linux-x64", "node-v24.21.0-linux-arm64"):
            (root / d / "bin").mkdir(parents=True)
        (root / "current").symlink_to("node-v24.21.0-linux-arm64")
        (root / "outro").write_text("x")
        self.run_shell(f"NODE_ROOT={shlex.quote(str(root))}\nNODE_DIST=node-v24.21.0-linux-arm64\n"
                       "die() { echo \"$*\" >&2; exit 1; }\n"
                       + function("install-dependencies-ubuntu.sh", "prune_old_node") + "\nprune_old_node\n")
        self.assertEqual(sorted(p.name for p in root.iterdir()),
                         ["current", "node-v24.21.0-linux-arm64", "outro"])

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
