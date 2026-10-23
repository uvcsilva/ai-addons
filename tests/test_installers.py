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
# The installers target Ubuntu; skip what needs its GNU tools when running elsewhere (e.g. macOS).
_BASE_ENV = dict(os.environ, PATH="/usr/bin:/bin")
HAS_BASH4 = subprocess.run(["bash", "-c", "((BASH_VERSINFO[0] >= 4))"], env=_BASE_ENV).returncode == 0
HAS_GNU_CP = subprocess.run(["cp", "--version"], env=_BASE_ENV, capture_output=True).returncode == 0
HAS_BASH44 = subprocess.run(["bash", "-c", "((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 404))"],
                            env=_BASE_ENV).returncode == 0
needs_bash4 = unittest.skipUnless(HAS_BASH4, "requires Bash 4+ (mapfile)")
needs_bash44 = unittest.skipUnless(HAS_BASH44, "requires Bash 4.4+ (mapfile -d)")
needs_gnu_cp = unittest.skipUnless(HAS_GNU_CP, "requires GNU cp (--reflink)")
needs_tomllib = unittest.skipUnless(sys.version_info >= (3, 11), "requires Python 3.11+ (tomllib)")


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

    @needs_bash4
    def test_arm64_download_and_checksum(self):
        self.run_shell(self.prepare_go())
        self.assertTrue((self.bin / "go").is_symlink())
        self.assertTrue((self.bin / "gofmt").is_file())

    @needs_bash4
    def test_bad_checksum_does_not_install(self):
        result = self.run_shell(self.prepare_go(bad_checksum=True), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.bin / "go").exists())

    @needs_bash4
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
            if script.name in ("install-dependencies-ubuntu.sh", "install-all-ubuntu.sh"):
                continue
            for m in re.finditer(r"^(\w+)\(\) \{\n.*?^\}", script.read_text(), re.M | re.S):
                if m.group(1) == "usage" or (m.group(1) == "all_mcp" and "serena" in script.name):
                    continue
                copies.setdefault(m.group(1), {})[script.name] = m.group()
        for name, bodies in copies.items():
            with self.subTest(function=name):
                self.assertEqual(len(set(bodies.values())), 1, f"{name} diverge: {sorted(bodies)}")

    @needs_gnu_cp
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

    def edit_json(self, target, kind="cline", legacy=None, mode="apply", command="/bin/c7", major=""):
        script = "install-context7-ubuntu.sh"
        return self.run_shell(
            (f"export LEGACY_MCP_ARGV={shlex.quote(legacy)}\n" if legacy else "")
            + f"OPENCODE_MAJOR={major}\nassert_regular_or_absent() {{ :; }}\nbackup_path() {{ :; }}\n"
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

    def test_opencode_entries_for_both_schemas(self):
        # Regression: the OpenCode schema check once shadowed the file reader and broke every apply.
        for major, path, flag in (("1", ("mcp", "context7"), {"enabled": True}),
                                  ("2", ("mcp", "servers", "context7"), {"disabled": False})):
            with self.subTest(major=major):
                target = self.base / f"opencode{major}.json"
                target.write_text('{\n  // user\n  "model": "x"\n}\n')
                self.assertEqual(self.edit_json(target, kind="opencode", major=major).returncode, 0)
                node = json.loads(re.sub(r"//.*", "", target.read_text()))
                for key in path:
                    node = node[key]
                self.assertEqual(node, {"type": "local", "command": ["/bin/c7"], **flag})
                first = target.read_text()
                self.assertEqual(self.edit_json(target, kind="opencode", major=major).returncode, 0)
                self.assertEqual(target.read_text(), first)
                self.assertEqual(self.edit_json(target, kind="opencode", major=major, mode="verify").returncode, 0)

    def test_empty_json_file_is_treated_as_object(self):
        target = self.base / "settings.json"
        target.write_text("")
        self.assertEqual(self.edit_json(target).returncode, 0)
        self.assertEqual(json.loads(target.read_text())["mcpServers"]["context7"]["command"], "/bin/c7")
        self.assertEqual(self.edit_json(target, mode="verify").returncode, 0)
        ag_target = self.base / "mcp_config.json"
        ag_target.write_text("")
        self.assertEqual(self.edit_json(ag_target, kind="antigravity").returncode, 0)
        self.assertEqual(json.loads(ag_target.read_text())["mcpServers"]["context7"],
                         {"command": "/bin/c7", "args": []})
        self.assertEqual(self.edit_json(ag_target, kind="antigravity", mode="verify").returncode, 0)

    def test_github_token_stays_out_of_argv(self):
        args, header = self.base / "curl-args", self.base / "curl-header"
        release = {"tag_name": "v1", "assets": [{"name": "x.tar.gz", "digest": "sha256:" + "0" * 64,
                   "browser_download_url": "https://github.com/o/r/releases/download/v1/x.tar.gz"}]}
        self.executable("curl", f"printf '%s\\n' \"$@\" >> {shlex.quote(str(args))}\n"
                        "prev=\nfor arg in \"$@\"; do\n"
                        f" [[ $prev != -H || $arg != @* ]] || cp \"${{arg#@}}\" {shlex.quote(str(header))}\n"
                        " prev=$arg\ndone\n"
                        f"echo {shlex.quote(json.dumps(release))} > \"${{@: -1}}\"\n")
        code = (f"TMP_WORKDIR={shlex.quote(str(self.base))}\n"
                + function("install-engram-ubuntu.sh", "release_asset_metadata") + "\n"
                + "release_asset_metadata o/r x.tar.gz\n")
        result = self.run_shell("export GITHUB_TOKEN=secret-token\n" + code)
        self.assertIn("v1\thttps://github.com/o/r/releases/download/v1/x.tar.gz\t" + "0" * 64, result.stdout)
        self.assertNotIn("secret-token", args.read_text())
        self.assertEqual(header.read_text(), "Authorization: Bearer secret-token\n")
        args.unlink(), header.unlink()
        self.run_shell(code)
        self.assertNotIn("Authorization", args.read_text())
        self.assertFalse(header.exists())

    def test_entry_using_installed_binary_gets_new_options(self):
        target = self.base / "mcp.json"
        target.write_text(json.dumps({"mcpServers": {"context7": {
            "command": "/bin/c7", "args": ["--api-key", "old"], "disabled": False, "autoApprove": []}}}))
        self.assertEqual(self.edit_json(target, command="/bin/c7").returncode, 0)
        self.assertEqual(json.loads(target.read_text())["mcpServers"]["context7"]["args"], [])
        # A relative command was not installed by this package: still a conflict.
        target.write_text(json.dumps({"mcpServers": {"context7": {"command": "c7", "args": ["x"]}}}))
        self.assertNotEqual(self.edit_json(target, command="c7").returncode, 0)

    def test_serena_extra_options_reach_every_client(self):
        code = ("CLIENTS=claude,cline,antigravity\nPROJECT_DIR=\nSERENA_EXTRA=(--log-level INFO --add-mode planning)\n"
                "selected() { [[ \",$CLIENTS,\" == *\",$1,\"* ]]; }\n"
                "ensure_claude_mcp() { echo \"claude $*\"; }\nnew_client_mcp() { echo \"$2 ${*:4}\"; }\n"
                + function("install-serena-ubuntu.sh", "all_mcp") + "\nall_mcp apply serena /bin/serena\n")
        lines = self.run_shell(code).stdout.splitlines()
        self.assertEqual(lines, [
            "claude serena /bin/serena start-mcp-server --context claude-code --project-from-cwd "
            "--add-mode no-memories --log-level INFO --add-mode planning",
            "cline /bin/serena start-mcp-server --context ide --add-mode no-memories --log-level INFO --add-mode planning",
            "antigravity /bin/serena start-mcp-server --context antigravity --project-from-cwd "
            "--add-mode no-memories --log-level INFO --add-mode planning"])

    @needs_tomllib
    def test_rtk_config_edit_keeps_other_settings(self):
        import tomllib
        config = self.base / "rtk/config.toml"
        def run(awareness="", exclude="", tracking="", history=""):
            return self.run_shell(f"RTK_CONFIG={shlex.quote(str(config))}\nRTK_AWARENESS={awareness}\n"
                                  f"RTK_EXCLUDE={shlex.quote(exclude)}\nRTK_TRACKING={tracking}\nRTK_HISTORY_DAYS={history}\n"
                                  + function("install-rtk-ubuntu.sh", "set_rtk_config") + "\nset_rtk_config\n",
                                  check=False)
        self.assertEqual(run().returncode, 0)  # nothing requested: no file
        self.assertFalse(config.exists())
        self.assertEqual(run("high", "curl, playwright", "false", "90").returncode, 0)
        self.assertEqual(tomllib.loads(config.read_text()), {
            "awareness": {"level": "high"}, "hooks": {"exclude_commands": ["curl", "playwright"]},
            "tracking": {"enabled": False, "history_days": 90}})
        config.write_text('# mine\n[display]\ncolors = false\n\n[tracking]\nenabled = true # keep note\n')
        self.assertEqual(run(tracking="false").returncode, 0)
        data = tomllib.loads(config.read_text())
        self.assertEqual(data, {"display": {"colors": False}, "tracking": {"enabled": False}})
        self.assertIn("# mine", config.read_text())
        first = config.read_text()
        self.assertEqual(run(tracking="false").returncode, 0)
        self.assertEqual(config.read_text(), first)
        # rtk itself writes multi-line arrays; the whole block is replaced, the rest kept.
        config.write_text('[hooks]\nexclude_commands = [\n    "a", # note ]\n    "b]",\n]\nsuppress_hook_warning = false\n')
        self.assertEqual(run(exclude="curl,playwright").returncode, 0)
        self.assertEqual(tomllib.loads(config.read_text()), {
            "hooks": {"exclude_commands": ["curl", "playwright"], "suppress_hook_warning": False}})
        for bad in ('[hooks]\nexclude_commands = [\n  "a",\n', 'awareness.level = "full"\n',
                    "[tracking]\nenabled = true\n[tracking]\nhistory_days = 1\n"):
            with self.subTest(bad=bad):
                config.write_text(bad)
                self.assertNotEqual(run("high", "x", "true").returncode, 0)
                self.assertEqual(config.read_text(), bad)

    def test_rtk_hook_only_never_reaches_codex(self):
        log = self.base / "rtk.log"
        # Fake rtk refuses the same flags as rtk init --codex / --agent antigravity (src/hooks/init/mod.rs).
        self.executable("rtk", f"echo \"$*\" >> {shlex.quote(str(log))}\n"
                        'if [[ (" $* " == *" --codex "* || " $* " == *" --agent antigravity "*) '
                        '&& " $* " =~ " --(hook-only|auto-patch|no-patch|claude-md) " ]]; then exit 1; fi\n')
        code = (f"LOCAL_BIN={shlex.quote(str(self.bin))}\nCLIENTS=claude,codex,antigravity\n"
                "RTK_CLAUDE_FLAGS=(--hook-only)\nRTK_INIT_FLAGS=(--no-trust-filters)\n"
                "selected() { [[ \",$CLIENTS,\" == *\",$1,\"* ]]; }\n"
                + function("install-rtk-ubuntu.sh", "run_rtk_init") + "\nrun_rtk_init\n")
        self.run_shell(code)
        self.assertEqual(log.read_text().splitlines(), [
            "init --global --auto-patch --hook-only --no-trust-filters",
            "init --global --codex --no-trust-filters",
            "init --global --agent antigravity --no-trust-filters"])

    def test_ccusage_settings_are_merged(self):
        config = self.base / "claude/ccusage.json"
        def run(settings):
            return self.run_shell(f"CCUSAGE_CONFIG={shlex.quote(str(config))}\nCCUSAGE_SETTINGS={shlex.quote(settings)}\n"
                                  "assert_regular_or_absent() { :; }\nbackup_path() { :; }\n"
                                  + function("install-ccusage-ubuntu.sh", "set_ccusage_settings")
                                  + "\nset_ccusage_settings\n", check=False)
        self.assertEqual(run('{"defaults": {"timezone": "UTC"}}').returncode, 0)
        self.assertEqual(json.loads(config.read_text()),
                         {"$schema": "https://ccusage.com/config-schema.json", "defaults": {"timezone": "UTC"}})
        config.write_text('{"defaults": {"breakdown": true, "timezone": "X"}, "commands": {"daily": {"order": "asc"}}}')
        self.assertEqual(run('{"defaults": {"timezone": "UTC"}, "commands": {"weekly": {"startOfWeek": "monday"}}}').returncode, 0)
        self.assertEqual(json.loads(config.read_text()), {
            "defaults": {"breakdown": True, "timezone": "UTC"},
            "commands": {"daily": {"order": "asc"}, "weekly": {"startOfWeek": "monday"}}})
        config.write_text("{broken")
        self.assertNotEqual(run('{"defaults": {}}').returncode, 0)
        self.assertEqual(config.read_text(), "{broken")

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

    @needs_tomllib
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

    def normalize_clients(self, clients, with_opencode="false"):
        script = "install-dependencies-ubuntu.sh"
        return self.run_shell(f"CLIENTS={shlex.quote(clients)}\nWITH_OPENCODE={with_opencode}\n"
                              "die() { echo \"$*\" >&2; exit 1; }\n"
                              "selected() { [[ \",$CLIENTS,\" == *\",$1,\"* ]]; }\n"
                              + function(script, "normalize_clients")
                              + "\nnormalize_clients\necho \"$CLIENTS\"\n", check=False)

    def test_bootstrap_client_selection(self):
        for clients, opencode, expected in [
                ("all", "false", "claude,codex,cline,opencode,copilot,vscode,antigravity"),
                ("claude", "false", "codex,claude"),
                ("codex", "true", "codex,opencode"),
                ("opencode,codex", "true", "opencode,codex")]:
            with self.subTest(clients=clients, opencode=opencode):
                result = self.normalize_clients(clients, opencode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
        for clients, message in [("foo", "Cliente desconhecido"), ("openrouter", "OpenRouter"),
                                 ("claude,,codex", "invalida"), (",codex", "invalida")]:
            with self.subTest(clients=clients):
                result = self.normalize_clients(clients)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
        result = subprocess.run(["bash", str(ROOT / "install-dependencies-ubuntu.sh"), "--clients"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Falta valor", result.stderr)

    def test_bootstrap_cli_install_and_upgrade(self):
        home, log = self.base / "home", self.base / "npm.log"
        prefix = home / ".local"
        # Fake npm: log the package and link the binary like a global npm install.
        self.executable("npm", f"echo \"${{@: -1}}\" >> {shlex.quote(str(log))}\n"
                        f"mkdir -p {shlex.quote(str(prefix))}/lib/node_modules/pkg {shlex.quote(str(prefix))}/bin\n"
                        f"printf '#!/bin/sh\\n' > {shlex.quote(str(prefix))}/lib/node_modules/pkg/cli\n"
                        f"chmod 700 {shlex.quote(str(prefix))}/lib/node_modules/pkg/cli\n"
                        f"ln -sfn ../lib/node_modules/pkg/cli {shlex.quote(str(prefix))}/bin/tool\n")
        def run(upgrade, upgradable="true"):
            log.write_text("")
            self.run_shell(f"export PATH={shlex.quote(str(prefix / 'bin'))}:$PATH\n"
                           f"HOME_DIR={shlex.quote(str(home))}\nNPM_REGISTRY=r\nUPGRADE={upgrade}\n"
                           "die() { echo \"$*\" >&2; exit 1; }\n"
                           + function("install-dependencies-ubuntu.sh", "install_client_cli")
                           + f"\ninstall_client_cli Tool tool pkg@latest {upgradable}\n")
            return log.read_text()
        self.assertEqual(run("false"), "pkg@latest\n")  # absent: installs
        self.assertEqual(run("false"), "")  # present: kept
        self.assertEqual(run("true"), "pkg@latest\n")  # npm-managed: upgraded
        self.assertEqual(run("true", "false"), "")  # e.g. OpenCode 2: never downgraded
        (prefix / "bin/tool").unlink()
        self.executable("tool", "exit 0\n")  # other origin: kept even with --upgrade
        self.assertEqual(run("true"), "")

    def test_ponytail_default_mode_keeps_other_settings(self):
        config = self.base / "ponytail/config.json"
        def run(mode):
            return self.run_shell(f"PONYTAIL_CONFIG={shlex.quote(str(config))}\nPONYTAIL_MODE={mode}\n"
                                  "assert_regular_or_absent() { :; }\nbackup_path() { :; }\n"
                                  + function("install-ponytail-ubuntu.sh", "set_ponytail_default_mode")
                                  + "\nset_ponytail_default_mode\n", check=False)
        self.assertEqual(run("ultra").returncode, 0)  # absent file is created
        self.assertEqual(json.loads(config.read_text()), {"defaultMode": "ultra"})
        config.write_text('{"quietStartup": true, "defaultMode": "full"}')
        self.assertEqual(run("ultra").returncode, 0)
        self.assertEqual(json.loads(config.read_text()), {"quietStartup": True, "defaultMode": "ultra"})
        self.assertEqual(run("lite\nPONYTAIL_QUIET=false\nPONYTAIL_HIDE=true").returncode, 0)
        self.assertEqual(json.loads(config.read_text()),
                         {"quietStartup": False, "defaultMode": "lite", "hideStatus": True})
        config.write_text("{broken")
        self.assertNotEqual(run("ultra").returncode, 0)
        self.assertEqual(config.read_text(), "{broken")

    def test_ponytail_rejects_unknown_mode(self):
        result = subprocess.run(["bash", str(ROOT / "install-ponytail-ubuntu.sh"), "--mode", "max", "--dry-run"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        result = subprocess.run(["bash", str(ROOT / "install-ponytail-ubuntu.sh"), "--mode", "lite", "--dry-run"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("nivel lite", result.stdout)

    SCRIPTS = {"bootstrap": "install-dependencies-ubuntu.sh", "engram": "install-engram-ubuntu.sh",
               "serena": "install-serena-ubuntu.sh", "context7": "install-context7-ubuntu.sh",
               "rtk": "install-rtk-ubuntu.sh", "ccusage": "install-ccusage-ubuntu.sh",
               "ponytail": "install-ponytail-ubuntu.sh"}

    def orchestrate(self, config, *args, fail=None):
        # Fake installers log their arguments; `fail` maps a name to a shell condition that exits 3.
        workdir, log = self.base / "pkg", self.base / "calls.log"
        workdir.mkdir(exist_ok=True)
        (workdir / "install-all-ubuntu.sh").write_text((ROOT / "install-all-ubuntu.sh").read_text())
        for name, script in self.SCRIPTS.items():
            check = f"if {fail[name]}; then exit 3; fi\n" if fail and name in fail else ""
            (workdir / script).write_text(f"echo {name} \"$*\" >> {shlex.quote(str(log))}\n{check}")
        (workdir / "addons.json").write_text(config if isinstance(config, str) else json.dumps(config))
        log.write_text("")
        env = dict(os.environ, HOME=str(self.base))
        result = subprocess.run(["bash", str(workdir / "install-all-ubuntu.sh"), *args],
                                env=env, capture_output=True, text=True)
        return result, log.read_text().splitlines()

    @needs_bash44
    def test_orchestrator_builds_arguments_in_order(self):
        config = {"clients": ["claude", "codex"], "options": {"cline-config": "~/cline.json"},
                  "bootstrap": {"upgrade": True},
                  "addons": {"serena": {"with-go": True, "check-go-project": None},
                             "ccusage": False, "ponytail": {"mode": "ultra", "clients": "codex"}}}
        result, calls = self.orchestrate(config)
        self.assertEqual(result.returncode, 0, result.stderr)
        cline = f"--cline-config {self.base}/cline.json"
        addons = [f"engram --clients claude,codex {cline}",
                  f"serena --clients claude,codex {cline} --with-go",
                  f"context7 --clients claude,codex {cline}",
                  f"rtk --clients claude,codex {cline}",
                  f"ponytail --clients codex {cline} --mode ultra"]
        self.assertEqual(calls, [c + " --dry-run" for c in addons]
                         + ["bootstrap --clients claude,codex --upgrade"] + addons)

    @needs_bash44
    def test_orchestrator_converts_lists_objects_and_value_booleans(self):
        config = {"bootstrap": False, "addons": {
            "engram": False, "serena": {"modes": ["planning", "editing"], "ls-dependencies": [],
                                        "open-web-dashboard": False, "enable-web-dashboard": None},
            "context7": False, "rtk": {"exclude-commands": ["curl"], "trust-filters": False, "tracking": True},
            "ccusage": {"settings": {"defaults": {"timezone": "UTC"}}},
            "ponytail": {"quiet-startup": True, "hide-status": None}}}
        result, calls = self.orchestrate(config, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            "serena --modes planning,editing --open-web-dashboard false --dry-run",
            "rtk --exclude-commands curl --trust-filters false --tracking true --dry-run",
            'ccusage --settings {"defaults": {"timezone": "UTC"}} --dry-run',
            "ponytail --quiet-startup true --dry-run"])

    @needs_bash44
    def test_shipped_configs_pass_real_dry_runs(self):
        home = self.base / "home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), CONTEXT7_API_KEY="test-key", XDG_STATE_HOME=str(home / "state"))
        env.pop("XDG_CONFIG_HOME", None)
        env.pop("CLAUDE_CONFIG_DIR", None)
        for name in ("addons.json", "addons.exemple.json"):
            with self.subTest(config=name):
                result = subprocess.run(["bash", str(ROOT / "install-all-ubuntu.sh"), "--config", str(ROOT / name),
                                         "--dry-run"], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.count("argumentos conferidos"), 6)
        self.assertEqual(list(home.iterdir()), [])

    @needs_bash44
    def test_orchestrator_dry_run_changes_nothing(self):
        result, calls = self.orchestrate({"bootstrap": False, "addons": {"ponytail": {"mode": "lite"}}},
                                         "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 6)
        self.assertTrue(all(c.endswith("--dry-run") for c in calls))
        self.assertIn("ponytail --mode lite --dry-run", calls)

    @needs_bash44
    def test_orchestrator_rejects_bad_config_before_running(self):
        for config in ('{"addons": {"unknown": true}}', '{"clients": "all", "clients": "codex"}',
                       '{"addons": {"rtk": {"Bad_Key": 1}}}', '{"bootstrap": {"mode": "x"}}',
                       '{"addons": {"rtk": {"dry-run": true}}}', '{"options": {"clients": "all"}}',
                       '{"addons": {"rtk": {"x": [1]}}}', "[]", "{broken"):
            with self.subTest(config=config):
                result, calls = self.orchestrate(config)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    @needs_bash44
    def test_orchestrator_preflight_failure_installs_nothing(self):
        result, calls = self.orchestrate({}, fail={"rtk": '[[ " $* " == *" --dry-run "* ]]'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rtk", result.stderr)
        self.assertFalse(any(c.startswith("bootstrap") for c in calls))
        self.assertTrue(all(c.endswith("--dry-run") for c in calls))

    @needs_bash44
    def test_orchestrator_stops_at_first_failure(self):
        result, calls = self.orchestrate({}, fail={"context7": '[[ " $* " != *" --dry-run "* ]]'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Falha em context7", result.stderr)
        self.assertEqual([c.split()[0] for c in calls if not c.endswith("--dry-run")],
                         ["bootstrap", "engram", "serena", "context7"])

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
