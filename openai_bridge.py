"""Loopback-only Anthropic Messages -> local OpenAI chat-completions adapter.

No third-party Python packages, cloud fallback, prompt logging or client credential
forwarding. The upstream and model allowlist come from the isolated switcher state.
"""
import argparse
import json
import os
import secrets
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def text_content(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        raise ValueError("Expected text or a list of content blocks")
    parts = []
    for block in content:
        if block.get("type") != "text":
            raise ValueError("This content requires a backend with native Anthropic support")
        parts.append(block.get("text", ""))
    return "\n".join(parts)


def convert_request(body):
    messages = []
    if body.get("system"):
        messages.append({"role": "system", "content": text_content(body["system"])})
    for message in body.get("messages", []):
        role = message.get("role")
        if role not in ("user", "assistant"):
            raise ValueError("Invalid message role")
        content = message.get("content", "")
        if isinstance(content, str):
            messages.append({"role": role, "content": content})
            continue
        parts, calls, results = [], [], []
        for block in content:
            kind = block.get("type")
            if kind == "text":
                parts.append({"type": "text", "text": block.get("text", "")})
            elif kind == "image":
                source = block["source"]
                if source.get("type") != "base64":
                    raise ValueError("Only base64 image sources are supported")
                parts.append({"type": "image_url", "image_url": {
                    "url": f"data:{source['media_type']};base64,{source['data']}"}})
            elif kind == "tool_use" and role == "assistant":
                calls.append({"id": block["id"], "type": "function", "function": {
                    "name": block["name"], "arguments": json.dumps(block.get("input", {}), ensure_ascii=False)}})
            elif kind == "tool_result" and role == "user":
                result = text_content(block.get("content", ""))
                if block.get("is_error"):
                    result = "Tool error: " + result
                results.append({"role": "tool", "tool_call_id": block["tool_use_id"], "content": result})
            elif kind == "thinking" and role == "assistant":
                # Prior reasoning is not a tool or user instruction.
                continue
            else:
                raise ValueError(f"Unsupported content block: {kind}")
        if results:
            messages.extend(results)
        if parts or calls or not results:
            converted = {"role": role, "content": parts or None}
            if calls:
                converted["tool_calls"] = calls
            messages.append(converted)
    result = {"model": body["model"], "messages": messages, "max_tokens": body.get("max_tokens", 1024),
              "stream": bool(body.get("stream", False))}
    for key in ("temperature", "top_p"):
        if key in body:
            result[key] = body[key]
    if body.get("stop_sequences"):
        result["stop"] = body["stop_sequences"]
    if body.get("tools"):
        tools = []
        for tool in body["tools"]:
            if "input_schema" not in tool or "name" not in tool:
                raise ValueError("Hosted/deferred tools require native Anthropic support")
            tools.append({"type": "function", "function": {
                "name": tool["name"], "description": tool.get("description", ""), "parameters": tool["input_schema"]}})
        result["tools"] = tools
        choice = body.get("tool_choice", {})
        if choice.get("type") == "tool":
            result["tool_choice"] = {"type": "function", "function": {"name": choice["name"]}}
        elif choice.get("type") == "any":
            result["tool_choice"] = "required"
        elif choice.get("type") in ("auto", "none"):
            result["tool_choice"] = choice["type"]
        if "disable_parallel_tool_use" in choice:
            result["parallel_tool_calls"] = not choice["disable_parallel_tool_use"]
    return result


def stop_reason(reason):
    return {"tool_calls": "tool_use", "function_call": "tool_use", "length": "max_tokens", "stop": "end_turn"}.get(reason, "end_turn")


def convert_response(response, model):
    if "error" in response or not response.get("choices"):
        raise ValueError("Invalid upstream chat-completions response")
    choice = response["choices"][0]
    message = choice.get("message", {})
    content = []
    if message.get("content"):
        content.append({"type": "text", "text": message["content"]})
    for call in message.get("tool_calls", []):
        function = call["function"]
        arguments = json.loads(function.get("arguments") or "{}")
        if not isinstance(arguments, dict):
            raise ValueError("Tool arguments must be a JSON object")
        content.append({"type": "tool_use", "id": call["id"], "name": function["name"], "input": arguments})
    if not content:
        raise ValueError("The upstream model returned no text or tool calls")
    usage = response.get("usage") or {}
    return {"id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant", "model": model,
            "content": content, "stop_reason": stop_reason(choice.get("finish_reason")), "stop_sequence": None,
            "usage": {"input_tokens": usage.get("prompt_tokens", 0), "output_tokens": usage.get("completion_tokens", 0)}}


def stream_response(lines, model):
    """Translate deltas as they arrive, without buffering the entire generation."""
    message = {"id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant", "model": model,
               "content": [], "stop_reason": None, "stop_sequence": None,
               "usage": {"input_tokens": 0, "output_tokens": 0}}
    yield "message_start", {"type": "message_start", "message": message}
    blocks, tools = [], {}
    text_index = None
    finish, output_tokens, saw_choice = None, 0, False
    for raw in lines:
        line = raw.decode("utf-8").strip() if isinstance(raw, bytes) else raw.strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        chunk = json.loads(data)
        if "error" in chunk:
            raise ValueError("The upstream stream failed")
        usage = chunk.get("usage") or {}
        output_tokens = usage.get("completion_tokens", output_tokens)
        choices = chunk.get("choices", [])
        if not choices:
            continue
        saw_choice = True
        choice = choices[0]
        delta = choice.get("delta", {})
        if delta.get("content"):
            if text_index is None:
                text_index = len(blocks)
                blocks.append(text_index)
                yield "content_block_start", {"type": "content_block_start", "index": text_index, "content_block": {"type": "text", "text": ""}}
            yield "content_block_delta", {"type": "content_block_delta", "index": text_index,
                                          "delta": {"type": "text_delta", "text": delta["content"]}}
        for call in delta.get("tool_calls", []):
            key = call["index"]
            state = tools.setdefault(key, {"id": "", "name": "", "index": None})
            state["id"] += call.get("id", "")
            function = call.get("function", {})
            state["name"] += function.get("name", "")
            if state["index"] is not None and function.get("name"):
                raise ValueError("Function name changed after its tool stream started")
            if state["index"] is None and state["name"] and function.get("arguments"):
                state["index"] = len(blocks)
                blocks.append(state["index"])
                yield "content_block_start", {"type": "content_block_start", "index": state["index"],
                    "content_block": {"type": "tool_use", "id": state["id"] or "toolu_" + uuid.uuid4().hex, "name": state["name"], "input": {}}}
            if function.get("arguments"):
                if state["index"] is None:
                    raise ValueError("Tool stream is missing its function name")
                yield "content_block_delta", {"type": "content_block_delta", "index": state["index"],
                    "delta": {"type": "input_json_delta", "partial_json": function["arguments"]}}
        if choice.get("finish_reason"):
            finish = choice["finish_reason"]
    for state in tools.values():
        if state["index"] is None and state["name"]:
            state["index"] = len(blocks)
            blocks.append(state["index"])
            yield "content_block_start", {"type": "content_block_start", "index": state["index"],
                "content_block": {"type": "tool_use", "id": state["id"] or "toolu_" + uuid.uuid4().hex, "name": state["name"], "input": {}}}
    if not saw_choice or finish is None or not blocks:
        raise ValueError("Incomplete upstream stream")
    for index in blocks:
        yield "content_block_stop", {"type": "content_block_stop", "index": index}
    yield "message_delta", {"type": "message_delta", "delta": {"stop_reason": stop_reason(finish), "stop_sequence": None},
                            "usage": {"output_tokens": output_tokens}}
    yield "message_stop", {"type": "message_stop"}


class BridgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def authorized(self):
        token = self.headers.get("x-api-key", "")
        if not token:
            token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        return secrets.compare_digest(token, self.server.client_token)

    def send_json(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def fail(self, status, message):
        self.send_json(status, {"type": "error", "error": {"type": "api_error", "message": message}})

    def do_GET(self):
        if not self.authorized():
            return self.fail(401, "Invalid local adapter token")
        if self.path == "/health":
            return self.send_json(200, {"adapter": "claude-local-openai", "config": str(self.server.config_path), "pid": os.getpid()})
        if self.path == "/v1/models":
            config = self.server.read_config()
            return self.send_json(200, {"data": [{"id": b["ModelId"], "type": "model"} for b in config["bindings"].values()]})
        self.fail(404, "Unknown adapter endpoint")

    def do_POST(self):
        if not self.authorized():
            return self.fail(401, "Invalid local adapter token")
        if self.path not in ("/v1/messages", "/v1/messages/count_tokens"):
            return self.fail(404, "Unknown adapter endpoint")
        if self.path.endswith("/count_tokens"):
            return self.fail(501, "Exact token counting requires a native Anthropic backend")
        upstream = None
        streaming = False
        try:
            size = int(self.headers.get("Content-Length", 0))
            if not 0 < size <= 32 * 1024 * 1024:
                return self.fail(413, "Invalid or oversized request")
            body = json.loads(self.rfile.read(size))
            config = self.server.read_config()
            provider = config["provider"]
            if provider["Kind"] != "OpenAI":
                return self.fail(409, "Provider changed; restart local VS Code")
            model = body.get("model")
            allowed = {b["ModelId"] for b in config["bindings"].values()}
            if model not in allowed:
                return self.fail(400, "Model is not bound in this isolated local profile")
            base = provider["BaseUrl"].rstrip("/")
            parsed = urllib.parse.urlparse(base)
            if parsed.hostname not in ("localhost", "127.0.0.1", "::1") or parsed.scheme not in ("http", "https"):
                raise ValueError("Upstream must be a loopback local server")
            converted = convert_request(body)
            request = urllib.request.Request(base + "/v1/chat/completions", json.dumps(converted, ensure_ascii=False).encode(),
                {"Content-Type": "application/json", "Authorization": "Bearer " + self.server.upstream_token})
            # Disable environment proxies and redirects: credentials stay at the selected local endpoint.
            upstream = self.server.opener.open(request, timeout=300)
            if not converted["stream"]:
                return self.send_json(200, convert_response(json.load(upstream), model))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            streaming = True
            for event, data in stream_response(upstream, model):
                self.wfile.write(("event: " + event + "\ndata: " + json.dumps(data, ensure_ascii=False) + "\n\n").encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            # Never expose upstream response bodies, credentials or prompts in errors.
            message = "Local upstream request failed; check the server and model capabilities"
            status = 502
            if isinstance(exc, (ValueError, KeyError, TypeError)):
                status, message = 400, str(exc) if isinstance(exc, ValueError) else "Malformed API request or response"
            if streaming:
                self.wfile.write(("event: error\ndata: " + json.dumps({"type": "error", "error": {"type": "api_error", "message": message}}) + "\n\n").encode())
            else:
                self.fail(status, message)
        finally:
            if upstream:
                upstream.close()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), BridgeHandler)
    server.daemon_threads = True
    server.config_path = args.config.resolve()
    server.client_token = os.environ.pop("LOCAL_SWITCHER_CLIENT_TOKEN")
    server.upstream_token = os.environ.pop("LOCAL_SWITCHER_UPSTREAM_TOKEN")
    server.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    server.read_config = lambda: json.loads(server.config_path.read_text(encoding="utf-8-sig"))
    args.ready_file.write_text(json.dumps({"port": server.server_port, "pid": os.getpid()}), encoding="utf-8")
    # A failed launcher must not leave an orphaned adapter; a launched VS Code keeps it alive.
    parent_pid = int(os.environ.pop("LOCAL_SWITCHER_PARENT_PID", "0"))
    if parent_pid:
        def watch_parent():
            import ctypes
            from ctypes import wintypes
            kernel = ctypes.windll.kernel32
            kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
            kernel.OpenProcess.restype = wintypes.HANDLE
            kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
            kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
            handle = kernel.OpenProcess(0x100000, False, parent_pid)
            if handle:
                kernel.WaitForSingleObject(handle, 0xFFFFFFFF)
                kernel.CloseHandle(handle)
                server.shutdown()
        threading.Thread(target=watch_parent, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
