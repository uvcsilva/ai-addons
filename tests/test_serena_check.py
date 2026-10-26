from contextlib import asynccontextmanager, redirect_stdout
import io
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

from test_installers import function


class SerenaGoCheckTest(unittest.TestCase):
    def run_check(self, field, failed=False, text='{"0": [{"name": "main"}]}'):
        source = function("lib/tools.sh", "check_go_project")
        source = source.split("<<'PYCHECK'\n", 1)[1].rsplit("\nPYCHECK", 1)[0]
        result = SimpleNamespace(content=[SimpleNamespace(text=text)], **{field: failed})
        starts, calls = [], []

        class Session:
            def __init__(self, read, write):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                pass

            async def initialize(self):
                pass

            async def call_tool(self, name, arguments):
                calls.append((name, arguments))
                return result

        @asynccontextmanager
        async def stdio_client(params, errlog):
            starts.append(params)
            yield None, None

        mcp, client, stdio = ModuleType("mcp"), ModuleType("mcp.client"), ModuleType("mcp.client.stdio")
        mcp.ClientSession, mcp.StdioServerParameters = Session, SimpleNamespace
        stdio.stdio_client = stdio_client
        with tempfile.TemporaryDirectory() as project:
            (Path(project) / "main.go").write_text("package main\nfunc main() {}\n")
            output = io.StringIO()
            with patch.dict(sys.modules, {"mcp": mcp, "mcp.client": client, "mcp.client.stdio": stdio}), \
                    patch.object(sys, "argv", ["-", "/bin/serena", project]), redirect_stdout(output):
                exec(compile(source, "check_go_project", "exec"), {})
        self.assertEqual(starts[0].command, "/bin/serena")
        interface = starts[0].args.index("--agent-interface")
        self.assertEqual(starts[0].args[interface + 1], "tools")
        self.assertEqual(calls, [("get_symbols_overview", {
            "relative_path": "main.go", "depth": 0, "max_answer_chars": 10000})])
        return output.getvalue()

    def test_current_and_legacy_sdk_success(self):
        for field in ("is_error", "isError"):
            with self.subTest(field=field):
                self.assertIn("leitura real de simbolos confirmada", self.run_check(field))

    def test_current_and_legacy_sdk_errors_fail(self):
        for field in ("is_error", "isError"):
            with self.subTest(field=field), self.assertRaisesRegex(SystemExit, "backend failed"):
                self.run_check(field, failed=True, text="backend failed")

    def test_text_error_fails(self):
        with self.assertRaisesRegex(SystemExit, "Error executing tool"):
            self.run_check("is_error", text="Error executing tool: no language server")

    def test_empty_symbols_fail(self):
        with self.assertRaisesRegex(SystemExit, "LSP nao retornou simbolos"):
            self.run_check("is_error", text="{}")


if __name__ == "__main__":
    unittest.main()
