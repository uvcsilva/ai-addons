import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PREFLIGHT = ROOT / "bin/graphify-preflight"

# Writes a minimal node-link graph like `graphify extract --code-only` / `graphify update`; update drops _meta.
FAKE_GRAPHIFY = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f:
    f.write(" ".join(args[:1] + args[2:]) + "\n")
if args[0] in ("extract", "update"):
    out = pathlib.Path(args[1]) / "graphify-out"
    out.mkdir(exist_ok=True)
    (out / "graph.json").write_text(json.dumps({"directed": False, "graph": {"schema_version": 1},
                                                "nodes": [{"id": "main"}], "links": []}))
'''


class GraphifyPreflightTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.repo, self.bin, self.calls = base / "repo", base / "bin", base / "calls"
        self.repo.mkdir()
        self.bin.mkdir()
        graphify = self.bin / "graphify"
        graphify.write_text(FAKE_GRAPHIFY)
        graphify.chmod(0o700)
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", CALLS=str(self.calls), HOME=str(base),
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@t", GIT_CONFIG_GLOBAL="/dev/null")
        self.git("init", "-q")
        (self.repo / "app.py").write_text("def main():\n    pass\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "init")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def preflight(self, *args, cwd=None):
        return subprocess.run(["bash", str(PREFLIGHT), *args], cwd=cwd or self.repo, env=self.env,
                              capture_output=True, text=True, timeout=30)

    def meta(self):
        return json.loads((self.repo / "graphify-out/graph.json").read_text())["_meta"]

    def calls_made(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_missing_graph_is_built_and_then_current_without_rebuilding(self):
        self.assertEqual(self.preflight("check").returncode, 2)
        result = self.preflight()  # ensure is the default
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls_made(), ["extract --code-only"])
        meta = self.meta()
        self.assertEqual(meta["git_commit"], self.git("rev-parse", "HEAD"))
        self.assertEqual(meta["git_tree_hash"], self.git("rev-parse", "HEAD^{tree}"))
        self.assertIs(meta["dirty"], False)
        self.assertEqual(meta["generator"], "graphify-preflight")
        self.assertEqual(list(json.loads((self.repo / "graphify-out/graph.json").read_text()))[0], "_meta")
        # graphify-out/ goes to .git/info/exclude: the tree stays clean and nothing is versioned.
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertIn("graphify-out/", (self.repo / ".git/info/exclude").read_text().splitlines())
        check = self.preflight("check")
        self.assertEqual(check.returncode, 0)
        self.assertIn("arvore limpa", check.stdout)
        self.preflight("ensure")
        self.assertEqual(self.calls_made(), ["extract --code-only"])  # current graph: no rebuild

    def test_changes_make_it_stale_until_rebuilt_and_commit_keeps_it_current(self):
        self.preflight("build")
        (self.repo / "app.py").write_text("def main():\n    return 1\n")
        (self.repo / "new.py").write_text("x = 1\n")
        stale = self.preflight("check")
        self.assertEqual(stale.returncode, 1)
        self.assertIn("arquivos alterados", stale.stdout)
        self.assertEqual(self.preflight("ensure").returncode, 0)
        self.assertEqual(self.calls_made()[-1], "update --force")
        self.assertIs(self.meta()["dirty"], True)
        self.assertEqual(self.preflight("check").returncode, 0)
        # Committing exactly what the graph saw keeps it current.
        self.git("add", "-A")
        self.git("commit", "-qm", "change")
        self.assertEqual(self.preflight("check").returncode, 0)
        # A new commit with other content does not.
        (self.repo / "app.py").write_text("def main():\n    return 2\n")
        self.git("commit", "-qam", "again")
        stale = self.preflight("check")
        self.assertEqual(stale.returncode, 1)
        self.assertIn("HEAD", stale.stdout)

    def test_graph_without_meta_is_stale(self):
        out = self.repo / "graphify-out"
        out.mkdir()
        (out / "graph.json").write_text(json.dumps({"nodes": [], "links": []}))
        result = self.preflight("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("sem _meta", result.stdout)

    def test_subdirectory_and_non_git_paths(self):
        (self.repo / "pkg").mkdir()
        self.preflight("build")
        self.assertEqual(self.preflight("check", cwd=self.repo / "pkg").returncode, 0)
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        self.assertEqual(self.preflight("check", str(outside)).returncode, 3)

    def test_build_without_graphify_fails_clearly(self):
        (self.bin / "graphify").unlink()
        result = self.preflight("build")
        self.assertEqual(result.returncode, 4)
        self.assertIn("graphify ausente", result.stderr)


if __name__ == "__main__":
    unittest.main()
