import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bridge", ROOT / "openai_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class ConversionTests(unittest.TestCase):
    def test_tool_round_trip(self):
        body = {"model": "local", "max_tokens": 100, "system": [{"type": "text", "text": "rules"}], "messages": [
            {"role": "assistant", "content": [{"type": "tool_use", "id": "call_1", "name": "read_file", "input": {"path": "x.py"}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "call_1", "content": "contents"}, {"type": "text", "text": "continue"}]}],
            "tools": [{"name": "read_file", "input_schema": {"type": "object"}}], "tool_choice": {"type": "any"}}
        converted = bridge.convert_request(body)
        self.assertEqual(converted["messages"][2]["role"], "tool")
        self.assertEqual(converted["messages"][2]["tool_call_id"], "call_1")
        self.assertEqual(converted["messages"][3]["role"], "user")
        self.assertEqual(converted["tool_choice"], "required")
        response = bridge.convert_response({"choices": [{"message": {"tool_calls": [{"id": "call_2", "function": {"name": "read_file", "arguments": '{"path":"y.py"}'}}]}, "finish_reason": "tool_calls"}]}, "local")
        self.assertEqual(response["content"][0]["input"], {"path": "y.py"})
        self.assertEqual(response["stop_reason"], "tool_use")

    def test_unsupported_document_is_explicit(self):
        with self.assertRaises(ValueError):
            bridge.convert_request({"model": "local", "messages": [{"role": "user", "content": [{"type": "document"}]}]})

    def test_invalid_tool_json_rejected(self):
        with self.assertRaises(ValueError):
            bridge.convert_response({"choices": [{"message": {"tool_calls": [{"id": "x", "function": {"name": "f", "arguments": "bad"}}]}}]}, "local")

    def test_streaming_fragmented_parallel_tools(self):
        chunks = [
            {"choices": [{"delta": {"content": "hello "}}]},
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "a", "function": {"name": "read", "arguments": '{"path":'}}, {"index": 1, "id": "b", "function": {"name": "list", "arguments": "{}"}}]}}]},
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": '"x"}'}}]}, "finish_reason": "tool_calls"}]},
            {"choices": [], "usage": {"completion_tokens": 12}}]
        events = list(bridge.stream_response(["data: " + json.dumps(c) for c in chunks] + ["data: [DONE]"], "local"))
        starts = [data for name, data in events if name == "content_block_start"]
        self.assertEqual([x["index"] for x in starts], [0, 1, 2])
        deltas = [data["delta"]["partial_json"] for name, data in events if name == "content_block_delta" and data["index"] == 1]
        self.assertEqual(json.loads("".join(deltas)), {"path": "x"})
        self.assertEqual(events[-2][1]["usage"]["output_tokens"], 12)
        self.assertEqual(events[-1][0], "message_stop")

    def test_truncated_stream_is_failure(self):
        with self.assertRaises(ValueError):
            list(bridge.stream_response(['data: {"choices":[{"delta":{"content":"partial"}}]}'], "local"))

    def test_streamed_name_fragments_and_empty_arguments(self):
        chunks = [
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call", "function": {"name": "read_", "arguments": ""}}]}}]},
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"name": "file", "arguments": "{}"}}]}}]},
            {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}]
        events = list(bridge.stream_response(["data: " + json.dumps(c) for c in chunks], "local"))
        starts = [data for event, data in events if event == "content_block_start"]
        self.assertEqual(starts[0]["content_block"]["name"], "read_file")
        chunks[1]["choices"][0]["delta"]["tool_calls"][0]["function"]["arguments"] = ""
        events = list(bridge.stream_response(["data: " + json.dumps(c) for c in chunks], "local"))
        self.assertEqual(events[-1][0], "message_stop")


class FakeUpstream(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((self.path, dict(self.headers), body))
        self.send_response(200)
        if body.get("stream"):
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for chunk in [{"choices": [{"delta": {"content": "OK"}}]}, {"choices": [{"delta": {}, "finish_reason": "stop"}]}]:
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"choices": [{"message": {"content": "OK"}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 5, "completion_tokens": 2}}).encode())


class LiveAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 0), FakeUpstream)
        cls.thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        cls.thread.start()
        cls.temp = tempfile.TemporaryDirectory()
        cls.config_path = Path(cls.temp.name) / "switcher.json"
        cls.config = {"provider": {"Kind": "OpenAI", "BaseUrl": f"http://127.0.0.1:{cls.upstream.server_port}"}, "bindings": {"sonnet": {"ModelId": "fixture-model"}}}
        cls.config_path.write_text(json.dumps(cls.config), encoding="utf-8")
        ready = Path(cls.temp.name) / "ready.json"
        env = dict(os.environ, LOCAL_SWITCHER_CLIENT_TOKEN="client-fixture", LOCAL_SWITCHER_UPSTREAM_TOKEN="upstream-fixture")
        env.pop("LOCAL_SWITCHER_PARENT_PID", None)
        cls.process = subprocess.Popen([sys.executable, str(ROOT / "openai_bridge.py"), "--config", str(cls.config_path), "--ready-file", str(ready)], env=env)
        for _ in range(100):
            if ready.exists():
                break
            time.sleep(0.05)
        cls.base = "http://127.0.0.1:" + str(json.loads(ready.read_text())["port"])

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.upstream.shutdown()
        cls.upstream.server_close()
        cls.temp.cleanup()

    def request(self, body, token="client-fixture"):
        request = urllib.request.Request(self.base + "/v1/messages", json.dumps(body).encode(), {"Content-Type": "application/json", "x-api-key": token, "Authorization": "Bearer should-never-forward"})
        return urllib.request.urlopen(request, timeout=5)

    def test_real_http_translation_and_credentials(self):
        with self.request({"model": "fixture-model", "max_tokens": 10, "messages": [{"role": "user", "content": "OK?"}]}) as response:
            self.assertEqual(json.load(response)["content"][0]["text"], "OK")
        path, headers, body = FakeUpstream.requests[-1]
        self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(headers["Authorization"], "Bearer upstream-fixture")
        self.assertNotIn("X-Api-Key", headers)
        self.assertEqual(body["model"], "fixture-model")

    def test_real_http_stream(self):
        with self.request({"model": "fixture-model", "stream": True, "messages": [{"role": "user", "content": "OK?"}]}) as response:
            stream = response.read().decode()
        self.assertIn("event: content_block_delta", stream)
        self.assertIn("event: message_stop", stream)

    def test_wrong_token_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request({"model": "fixture-model"}, "wrong")
        self.assertEqual(caught.exception.code, 401)

    def test_unknown_model_rejected_without_upstream_request(self):
        count = len(FakeUpstream.requests)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request({"model": "claude-unknown"})
        self.assertEqual(caught.exception.code, 400)
        self.assertEqual(len(FakeUpstream.requests), count)

    def test_provider_change_stops_routing(self):
        changed = dict(self.config, provider={"Kind": "Ollama", "BaseUrl": "http://localhost:11434"})
        try:
            self.config_path.write_text(json.dumps(changed), encoding="utf-8")
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.request({"model": "fixture-model"})
            self.assertEqual(caught.exception.code, 409)
        finally:
            self.config_path.write_text(json.dumps(self.config), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
