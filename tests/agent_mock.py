"""Local model protocols for terminal tests. No tools, credentials or paid traffic."""
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time

MARKER = "VERTEX_AGENT_RESPONSE"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        data = json.dumps({"object": "list", "data": [{"id": "vertex-test", "object": "model", "created": 1, "owned_by": "vertex"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        self.server.requests.append({"path": self.path, "body": body})
        text = MARKER + "\n" + "界 é 👩‍💻 streamed terminal output\n" * 12
        if "count_tokens" in self.path:
            data = b'{"input_tokens":10}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def emit(event, data):
            payload = (f"event: {event}\n" if event else "") + "data: " + json.dumps(data) + "\n\n"
            self.wfile.write(payload.encode())
            self.wfile.flush()

        try:
            if "messages" in self.path:
                emit("message_start", {"type": "message_start", "message": {"id": "msg_vertex", "type": "message", "role": "assistant", "model": "claude-sonnet-4-6", "content": [], "stop_reason": None, "usage": {"input_tokens": 10, "output_tokens": 0}}})
                emit("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
                for line in text.splitlines(True):
                    emit("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": line}})
                    time.sleep(0.03)
                emit("content_block_stop", {"type": "content_block_stop", "index": 0})
                emit("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 60}})
                emit("message_stop", {"type": "message_stop"})
            elif "responses" in self.path:
                item = {"id": "msg_vertex", "type": "message", "role": "assistant", "status": "in_progress", "content": []}
                response = {"id": "resp_vertex", "object": "response", "created_at": 1, "model": "vertex-test", "status": "in_progress", "output": []}
                emit("response.created", {"type": "response.created", "response": response})
                emit("response.output_item.added", {"type": "response.output_item.added", "output_index": 0, "item": item})
                part = {"type": "output_text", "text": "", "annotations": []}
                emit("response.content_part.added", {"type": "response.content_part.added", "item_id": item["id"], "output_index": 0, "content_index": 0, "part": part})
                for line in text.splitlines(True):
                    emit("response.output_text.delta", {"type": "response.output_text.delta", "item_id": item["id"], "output_index": 0, "content_index": 0, "delta": line})
                    time.sleep(0.03)
                part["text"] = text
                item.update(status="completed", content=[part])
                emit("response.output_text.done", {"type": "response.output_text.done", "item_id": item["id"], "output_index": 0, "content_index": 0, "text": text})
                emit("response.content_part.done", {"type": "response.content_part.done", "item_id": item["id"], "output_index": 0, "content_index": 0, "part": part})
                emit("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item})
                response.update(status="completed", output=[item], usage={"input_tokens": 10, "output_tokens": 60, "total_tokens": 70})
                emit("response.completed", {"type": "response.completed", "response": response})
            else:
                for line in text.splitlines(True):
                    emit(None, {"id": "chat_vertex", "object": "chat.completion.chunk", "created": 1, "model": "vertex-test", "choices": [{"index": 0, "delta": {"role": "assistant", "content": line}, "finish_reason": None}]})
                    time.sleep(0.03)
                emit(None, {"id": "chat_vertex", "object": "chat.completion.chunk", "created": 1, "model": "vertex-test", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
                self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass


@contextlib.contextmanager
def model_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.requests = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", server.requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
