import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STEPS = {"bootstrap": "install-dependencies-ubuntu.sh", "claude": "install-claude-ubuntu.sh",
         "codex": "install-codex-ubuntu.sh", "kimi": "install-kimi-ubuntu.sh",
         "cline": "install-cline-ubuntu.sh", "opencode": "install-opencode-ubuntu.sh",
         "copilot": "install-copilot-ubuntu.sh", "antigravity": "install-antigravity-ubuntu.sh"}


class InstallAllTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def orchestrate(self, config, *args, fail=None):
        # Fake installers log their arguments; `fail` maps a name to a shell condition that exits 3.
        workdir, log = self.base / "pkg", self.base / "calls.log"
        workdir.mkdir(exist_ok=True)
        shutil.copy(ROOT / "install-all-ubuntu.sh", workdir)
        shutil.copytree(ROOT / "lib", workdir / "lib", dirs_exist_ok=True)
        for name, script in STEPS.items():
            check = f"if {fail[name]}; then exit 3; fi\n" if fail and name in fail else ""
            (workdir / script).write_text(f"echo {name} \"$*\" >> {shlex.quote(str(log))}\n{check}")
        (workdir / "addons.json").write_text(config if isinstance(config, str) else json.dumps(config))
        log.write_text("")
        result = subprocess.run(["bash", str(workdir / "install-all-ubuntu.sh"), *args],
                                env=dict(os.environ, HOME=str(self.base)), capture_output=True, text=True)
        return result, log.read_text().splitlines(), workdir / "addons.json"

    def run_calls(self, calls):
        return [c for c in calls if not c.endswith("--dry-run")]

    def test_plan_follows_clients(self):
        cases = [
            ({}, ["bootstrap", "claude", "codex"]),
            ({"clients": "all"}, ["bootstrap", "claude", "codex", "kimi", "cline", "opencode", "copilot", "antigravity"]),
            ({"clients": ["antigravity", "copilot", "claude"]}, ["bootstrap", "claude", "copilot", "antigravity"]),
            ({"clients": "cline", "bootstrap": False}, ["cline"]),
        ]
        for config, expected in cases:
            with self.subTest(config=config):
                result, calls, _ = self.orchestrate(config)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([c.split()[0] for c in self.run_calls(calls)], expected)

    def test_arguments_for_bootstrap_and_providers(self):
        config = {"clients": ["claude", "vscode"], "bootstrap": {"upgrade": True, "with-opencode": False}}
        result, calls, path = self.orchestrate(config)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_calls(calls), [
            "bootstrap --clients claude,vscode --upgrade",
            f"claude --config {path}",
            f"copilot --config {path} --surfaces vscode"])
        # Preflight dry-runs the providers only, before anything runs.
        self.assertEqual(calls[:2], [f"claude --config {path} --dry-run",
                                     f"copilot --config {path} --surfaces vscode --dry-run"])

    def test_copilot_surfaces(self):
        for clients, surfaces in ((["copilot"], "cli"), (["vscode", "copilot"], "cli,vscode")):
            with self.subTest(clients=clients):
                _, calls, path = self.orchestrate({"clients": clients, "bootstrap": False})
                self.assertEqual(self.run_calls(calls), [f"copilot --config {path} --surfaces {surfaces}"])

    def test_bootstrap_without_clients_uses_its_default(self):
        _, calls, _ = self.orchestrate({"bootstrap": {"clients": ["codex"]}})
        self.assertEqual(self.run_calls(calls)[0], "bootstrap --clients codex")
        _, calls, _ = self.orchestrate({})
        self.assertEqual(self.run_calls(calls)[0], "bootstrap ")

    def test_dry_run_changes_nothing(self):
        result, calls, _ = self.orchestrate({"clients": "all"}, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 7)
        self.assertTrue(all(c.endswith("--dry-run") for c in calls))
        self.assertIn("Simulacao concluida", result.stdout)

    def test_bad_config_is_refused_before_running(self):
        for config in ('{"addons": {"unknown": true}}', '{"clients": "all", "clients": "codex"}',
                       '{"addons": {"rtk": {"Bad_Key": 1}}}', '{"bootstrap": {"mode": "x"}}',
                       '{"addons": {"rtk": {"dry-run": true}}}', '{"options": {"clients": "all"}}',
                       '{"addons": {"rtk": false}}', '{"addons": {"engram": {"clients": "claude"}}}',
                       '{"clients": "openrouter"}', "[]", "{broken"):
            with self.subTest(config=config):
                result, calls, _ = self.orchestrate(config)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_preflight_failure_installs_nothing(self):
        result, calls, _ = self.orchestrate({}, fail={"codex": '[[ " $* " == *" --dry-run "* ]]'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Opcoes invalidas para codex", result.stderr)
        self.assertEqual(self.run_calls(calls), [])

    def test_stops_at_first_failure(self):
        result, calls, _ = self.orchestrate({"clients": "all"}, fail={"cline": '[[ " $* " != *" --dry-run "* ]]'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Falha em cline", result.stderr)
        self.assertEqual([c.split()[0] for c in self.run_calls(calls)], ["bootstrap", "claude", "codex", "kimi", "cline"])

    def test_missing_lib_or_config_fails_clearly(self):
        workdir = self.base / "alone"
        workdir.mkdir()
        shutil.copy(ROOT / "install-all-ubuntu.sh", workdir)
        result = subprocess.run(["bash", str(workdir / "install-all-ubuntu.sh")], capture_output=True, text=True)
        self.assertIn("Pasta lib/ ausente", result.stderr)
        result = subprocess.run(["bash", str(ROOT / "install-all-ubuntu.sh"), "--config", str(self.base / "x.json")],
                                capture_output=True, text=True)
        self.assertIn("Arquivo de configuracao nao encontrado", result.stderr)

    def test_shipped_configs_pass_real_dry_runs(self):
        home = self.base / "home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), CONTEXT7_API_KEY="test-key", XDG_STATE_HOME=str(home / "state"))
        for key in ("XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME", "KIMI_CODE_HOME"):
            env.pop(key, None)
        for name in ("addons.json", "addons.exemple.json"):
            with self.subTest(config=name):
                result = subprocess.run(["bash", str(ROOT / "install-all-ubuntu.sh"), "--config", str(ROOT / name),
                                         "--dry-run"], cwd="/", env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.count("argumentos conferidos"), 7)
                self.assertIn("Superficies: cli,vscode", result.stdout)
        self.assertEqual(list(home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
