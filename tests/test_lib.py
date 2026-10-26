import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "lib"


class LibTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def run_lib(self, code, *libs, check=True):
        sources = "".join(f". {shlex.quote(str(LIB / name))}\n" for name in libs)
        env = dict(os.environ, HOME=str(self.base), PATH="/usr/bin:/bin")
        env.pop("XDG_CONFIG_HOME", None)
        result = subprocess.run(["bash", "-c", "set -Eeuo pipefail\n" + sources + code],
                                env=env, text=True, capture_output=True, timeout=20)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def config(self, data):
        path = self.base / "addons.json"
        path.write_text(data if isinstance(data, str) else json.dumps(data))
        return path

    def load(self, data, code="", check=True):
        path = self.config(data)
        return self.run_lib(f"config_load {shlex.quote(str(path))}\n{code}",
                            "common.sh", "config.sh", "addons.sh", check=check)

    def test_repository_configs_load_unchanged(self):
        for name in ("addons.json", "addons.exemple.json"):
            with self.subTest(config=name):
                result = self.run_lib(f"config_load {shlex.quote(str(ROOT / name))}\nconfig_clients",
                                      "config.sh")
                self.assertEqual(result.stdout, "claude,codex,cline,opencode,copilot,vscode,antigravity")

    def test_values_are_normalized(self):
        result = self.load({
            "options": {"project-dir": "~/app", "opencode-major": 2},
            "addons": {"serena": {"enabled": True, "modes": ["a", "b"], "with-go": True, "log-level": None},
                       "ccusage": {"settings": {"defaults": {"offline": False}}},
                       "engram": True}},
            'printf "%s|" "$(config_opt serena modes)" "$(config_opt serena with-go)" '
            '"$(config_opt serena log-level x)" "$(config_option opencode-major)" '
            '"$(config_opt ccusage settings)" "$(config_opt serena project-dir)" "$(config_clients)"')
        self.assertEqual(result.stdout.split("|")[:-1], [
            "a,b", "true", "x", "2", '{"defaults": {"offline": false}}', str(self.base / "app"),
            "claude,codex"])

    def test_addon_path_option_overrides_root_option(self):
        result = self.load({"options": {"project-dir": "/global"},
                            "addons": {"serena": {"project-dir": "/only-serena"}}},
                           'printf "%s|%s" "$(config_opt serena project-dir)" "$(config_opt engram project-dir)"')
        self.assertEqual(result.stdout, "/only-serena|/global")

    def test_missing_config_uses_defaults(self):
        result = self.run_lib('config_load\nprintf "%s|%s" "$(config_clients)" "$(config_opt engram tools agent)"',
                              "config.sh")
        self.assertEqual(result.stdout, "claude,codex|agent")
        missing = self.run_lib(f"config_load {shlex.quote(str(self.base / 'none.json'))}", "config.sh", check=False)
        self.assertEqual(missing.returncode, 2)

    def test_all_and_bom_are_accepted(self):
        result = self.load("﻿" + json.dumps({"clients": "all"}), "config_clients")
        self.assertEqual(result.stdout, "claude,codex,cline,opencode,copilot,vscode,antigravity")

    def test_invalid_configs_are_refused(self):
        cases = {
            "duplicada": '{"clients": "codex", "clients": "claude"}',
            "desconhecidas na raiz": {"extra": 1},
            "OpenRouter": {"clients": ["cline", "openrouter"]},
            "cliente desconhecido": {"clients": "claude,,codex"},
            "use clients na raiz": {"options": {"clients": "codex"}},
            "options aceita somente": {"options": {"mode": "ultra"}},
            "addons desconhecidos": {"addons": {"other": {}}},
            "opcoes desconhecidas": {"addons": {"engram": {"mode": "ultra"}}},
            "remova o false": {"addons": {"rtk": False}},
            "remova o false ": {"addons": {"rtk": {"enabled": False}}},
            "remova clients": {"addons": {"engram": {"clients": "claude"}}},
            "quebra de linha": {"addons": {"ponytail": {"mode": "a\nb"}}},
            "sem virgula": {"addons": {"serena": {"modes": ["a,b"]}}},
            "bootstrap aceita somente": {"bootstrap": {"mode": 1}},
        }
        for expected, data in cases.items():
            with self.subTest(expected=expected):
                result = self.load(data, check=False)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(expected.strip(), result.stderr)
                self.assertIn("Configuracao invalida", result.stderr)

    def test_addon_options_are_validated(self):
        ok = self.load({"addons": {"serena": {"modes": ["no-onboarding"], "tool-timeout": 240,
                                              "open-web-dashboard": False},
                                   "rtk": {"init-mode": "hook-only", "trust-filters": True}}},
                       "addons_load_options\n"
                       'printf "%s " "${SERENA_EXTRA[@]}" "|" "${RTK_CLAUDE_FLAGS[@]}" "${RTK_INIT_FLAGS[@]}" '
                       '"$ENGRAM_TOOLS" "$PONYTAIL_MODE"')
        self.assertEqual(ok.stdout.split(), [
            "--open-web-dashboard", "false", "--tool-timeout", "240", "--add-mode", "no-onboarding",
            "|", "--hook-only", "--trust-filters", "agent", "ultra"])
        bad = {"addons.ponytail.mode": {"ponytail": {"mode": "max"}},
               "no-memories": {"serena": {"modes": ["no-memories"]}},
               "addons.engram.tools": {"engram": {"tools": "Agent"}},
               "CONTEXT7_API_KEY": {"context7": {"api-key-from-env": True}}}
        for expected, addons in bad.items():
            with self.subTest(expected=expected):
                path = self.config({"addons": addons})
                result = self.run_lib(f"config_load {shlex.quote(str(path))}\naddons_load_options",
                                      "common.sh", "config.sh", "addons.sh", check=False)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(expected, result.stderr)

    def test_addon_rules_follow_ponytail_level(self):
        out = self.base / "rules.md"
        for mode, level in (("ultra", "## Level: ultra"), ("lite", "## Level: lite"), ("full", None)):
            with self.subTest(mode=mode):
                self.run_lib(f"PONYTAIL_MODE={mode}\naddon_rules ponytail {shlex.quote(str(out))}",
                             "common.sh", "addons.sh")
                text = out.read_text()
                self.assertTrue(text.startswith("<!-- Fonte oficial DietrichGebert/ponytail/AGENTS.md"))
                if level:
                    self.assertIn(level, text)
                else:
                    self.assertNotIn("## Level:", text)
        for addon, heading in (("engram", "# Engram"), ("serena", "## Serena"), ("context7", "## Context7")):
            with self.subTest(addon=addon):
                self.run_lib(f"addon_rules {addon} {shlex.quote(str(out))}", "common.sh", "addons.sh")
                self.assertTrue(out.read_text().startswith(heading))
        self.assertNotEqual(self.run_lib(f"addon_rules rtk {shlex.quote(str(out))}", "common.sh", "addons.sh",
                                         check=False).returncode, 0)

    def rule_code(self, action, target, addon, source=None):
        args = [str(target), str(source), addon] if action == "write" else [str(target), addon]
        return ("assert_regular_or_absent() { :; }\nbackup_path() { :; }\n"
                f"{action}_managed_rule {' '.join(shlex.quote(a) for a in args)}\n")

    def test_remove_managed_rule_keeps_other_blocks(self):
        target, source = self.base / "AGENTS.md", self.base / "rule.md"
        target.write_text("User rules\n")
        for addon in ("engram", "ponytail", "serena"):
            source.write_text(f"Use {addon}\n")
            self.run_lib(self.rule_code("write", target, addon, source), "common.sh")
        written = target.read_text()
        self.run_lib(self.rule_code("remove", target, "ponytail"), "common.sh")
        text = target.read_text()
        self.assertNotIn("six-addons:ponytail", text)
        self.assertNotIn("Use ponytail", text)
        self.assertEqual(text, written.replace(
            "\n\n<!-- six-addons:ponytail:begin -->\nUse ponytail\n<!-- six-addons:ponytail:end -->\n", ""))
        self.run_lib(self.rule_code("remove", target, "ponytail"), "common.sh")
        self.assertEqual(target.read_text(), text)

    def test_remove_last_block_restores_user_text(self):
        target, source = self.base / "AGENTS.md", self.base / "rule.md"
        target.write_text("User rules\n")
        source.write_text("Use rtk\n")
        self.run_lib(self.rule_code("write", target, "rtk", source), "common.sh")
        self.run_lib(self.rule_code("remove", target, "rtk"), "common.sh")
        self.assertEqual(target.read_text(), "User rules\n")
        self.run_lib(self.rule_code("remove", self.base / "absent.md", "rtk"), "common.sh")
        self.assertFalse((self.base / "absent.md").exists())

    @unittest.skipUnless(Path("/etc/os-release").exists() and "ID=ubuntu" in Path("/etc/os-release").read_text(),
                         "installer_begin requires Ubuntu")
    def test_installer_begin_opens_private_run(self):
        result = self.run_lib('installer_begin teste\nprintf "%s\\n" "$BACKUP_DIR" "$LOG_FILE" "$TMP_WORKDIR" "$PWD"',
                              "common.sh")
        backup, log, tmp, cwd = result.stdout.strip().splitlines()[-4:]
        state = self.base / ".local/state/six-addons-installer"
        self.assertTrue(Path(backup).is_dir() and Path(backup).parent == state / "backups")
        self.assertEqual(Path(log).stat().st_mode & 0o777, 0o600)
        self.assertEqual(cwd, tmp)
        self.assertFalse(Path(tmp).exists())  # removed by the EXIT trap
        self.assertIn("Instalador de teste", Path(log).read_text())
        missing = self.run_lib("installer_begin teste comando-inexistente", "common.sh", check=False)
        self.assertEqual(missing.returncode, 1)
        self.assertIn("Pre-requisitos ausentes: comando-inexistente", missing.stderr)

    def test_test_helper_finds_lib_functions(self):
        sys.path.insert(0, str(Path(__file__).parent))
        from test_installers import function
        self.assertTrue(function("install-sem-copia.sh", "remove_managed_rule").startswith("remove_managed_rule() {"))
        self.assertIn('"$OPENCODE_MAJOR"', function("install-claude-ubuntu.sh", "edit_client_json"))

    def test_remove_refuses_corrupt_block(self):
        target = self.base / "AGENTS.md"
        original = "User rules\n<!-- six-addons:ponytail:begin -->\n"
        target.write_text(original)
        result = self.run_lib(self.rule_code("remove", target, "ponytail"), "common.sh", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), original)


if __name__ == "__main__":
    unittest.main()
