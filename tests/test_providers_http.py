"""Exercise the shipped PowerShell CLI against real local HTTP fixtures."""
import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ProviderFixture(BaseHTTPRequestHandler):
    fail_messages = False
    fail_tools = False

    def log_message(self, *_):
        pass

    def respond(self, body, status=200):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/api/v1/models":
            return self.respond({"models": [{"type": "llm", "key": "fixture-large", "display_name": "Large", "publisher": "fixture", "size_bytes": 12000000000,
                "params_string": "12B", "max_context_length": 65536, "loaded_instances": []},
                {"type": "embedding", "key": "not-a-chat-model"}]})
        if self.path == "/api/tags":
            return self.respond({"models": [{"name": "fixture:latest", "size": 5000000000, "details": {"family": "qwen", "parameter_size": "8B"}},
                                           {"name": "fixture:cloud", "size": 0, "details": {}}]})
        if self.path == "/v1/models":
            return self.respond({"data": [{"id": "fixture-custom", "owned_by": "local"}]})
        self.respond({"error": "unknown"}, 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if self.path == "/api/v1/models/load":
            return self.respond({"status": "loaded", "instance_id": "fixture-instance", "load_config": {"context_length": body.get("context_length", 32768)}})
        if self.path == "/api/show":
            return self.respond({"model_info": {"qwen.context_length": 65536}})
        if self.path == "/api/create":
            return self.respond({"status": "success"})
        if self.path == "/v1/messages":
            if self.fail_messages:
                return self.respond({"error": "fixture failure"}, 503)
            if "tools" in body:
                if self.fail_tools:
                    return self.respond({"type": "message", "role": "assistant", "content": [{"type": "text", "text": "No tool call"}]})
                content = [{"type": "tool_use", "id": "probe", "name": "local_probe", "input": {"value": "OK"}}]
            else:
                content = [{"type": "text", "text": "OK"}]
            return self.respond({"type": "message", "role": "assistant", "model": body["model"], "content": content})
        if self.path == "/v1/chat/completions":
            return self.respond({"choices": [{"message": {"content": "OK"}, "finish_reason": "stop"}]})
        self.respond({"error": "unknown"}, 404)


@unittest.skipUnless(os.name == "nt", "Windows PowerShell required")
class PowerShellHttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), ProviderFixture)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def cli(self, state, *args):
        result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "lmstudio_alias_switcher_gui.ps1"),
            "-Headless", "-StateRoot", str(state), *args], capture_output=True, timeout=30)
        return result

    def test_all_four_provider_bindings(self):
        for kind, model, context in [("LMStudio", "fixture-large", 32768), ("Ollama", "fixture:latest", 32768),
                                     ("Anthropic", "fixture-custom", 0), ("OpenAI", "fixture-custom", 0)]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix="Switcher project ") as state:
                result = self.cli(state, "-Backend", kind, "-BaseUrl", self.base, "-Alias", "sonnet", "-ModelKey", model, "-ContextLength", str(context), "-TestAlias")
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                config = json.loads((Path(state) / "switcher.json").read_text(encoding="utf-8-sig"))
                self.assertEqual(config["provider"]["Kind"], kind)
                self.assertEqual(config["bindings"]["sonnet"]["ModelKey"], model)

    def test_failed_endpoint_preserves_mapping_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as state:
            result = self.cli(state, "-Backend", "Anthropic", "-BaseUrl", self.base, "-ModelKey", "fixture-custom")
            self.assertEqual(result.returncode, 0)
            path = Path(state) / "switcher.json"
            original = path.read_bytes()
            ProviderFixture.fail_messages = True
            try:
                result = self.cli(state, "-ModelKey", "fixture-custom")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(path.read_bytes(), original)
                result = self.cli(state, "-TestAlias")
                self.assertNotEqual(result.returncode, 0)
            finally:
                ProviderFixture.fail_messages = False

    def test_ollama_catalog_excludes_cloud(self):
        with tempfile.TemporaryDirectory() as state:
            result = self.cli(state, "-Backend", "Ollama", "-BaseUrl", self.base, "-ListModels")
            self.assertEqual(result.returncode, 0)
            self.assertIn(b"fixture:latest", result.stdout)
            self.assertNotIn(b"fixture:cloud", result.stdout)

    def test_guided_gui_async_connection_and_model_checks(self):
        result = subprocess.run(["powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tests" / "test_gui_workflow.ps1"), "-BaseUrl", self.base], capture_output=True, timeout=50)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn(b"PASS:", result.stdout)

    def test_chat_reset_preserves_account_and_mapping(self):
        with tempfile.TemporaryDirectory() as state:
            state = Path(state)
            projects = state / "claude" / "projects" / "fixture"
            projects.mkdir(parents=True)
            (projects / "chat.jsonl").write_text("fixture chat")
            credentials = state / "claude" / ".credentials.json"
            credentials.write_text("fixture-login")
            mapping = state / "switcher.json"
            mapping.write_text("{}")
            result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "reset_local_chats.ps1"), "-StateRoot", str(state)], capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertFalse(projects.exists())
            self.assertEqual(credentials.read_text(), "fixture-login")
            self.assertEqual(mapping.read_text(), "{}")

    def test_guided_gui_tool_failure_preserves_mapping_and_gates(self):
        ProviderFixture.fail_tools = True
        try:
            result = subprocess.run(["powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "tests" / "test_gui_workflow.ps1"), "-BaseUrl", self.base, "-ExpectToolFailure"], capture_output=True, timeout=50)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertIn(b"PASS:", result.stdout)
        finally:
            ProviderFixture.fail_tools = False


if __name__ == "__main__":
    unittest.main()
