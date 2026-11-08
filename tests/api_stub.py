"""A stand-in for an OpenAI-compatible API, for the tests and, by hand, for replay.py. Everything on one port:

    GET  /v1/models                        `auto` (unless `auto=False`) and two models
    POST /v1/audio/transcriptions          multipart, `{"text"}`
    POST /v1/chat/completions              the phrase given back, streamed as server-sent events when asked;
                                           `auto` answers as qwen3.8-27b-gguf, named in `model` and X-Model-Resolved
    GET  /v1/realtime?intent=transcription the realtime transcription socket, OpenAI's events only: session.created,
                                           session.update → session.updated, input_audio_buffer.append / .commit /
                                           .clear → .committed / .cleared, conversation.item.input_audio_transcription
                                           .delta / .completed / .failed, error

Test audio is a constant tone: every sample is mark / 100, and the transcript names the mark. With `live_deltas` the
socket sends a delta for the phrase in the buffer as its audio arrives, before the commit, as gpt-live-transcribe does.

    python tests/api_stub.py [--port 8791]
    then: CITADEL_API_KEY=x python replay.py take.wav --base http://127.0.0.1:8791/v1
"""
from __future__ import annotations

import argparse
import base64
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from websockets.datastructures import Headers
from websockets.frames import Opcode
from websockets.http11 import Request
from websockets.protocol import State
from websockets.server import ServerProtocol

RATE = 24000
AUTO_MODEL = "qwen3.8-27b-gguf"


class StubError(Exception):
    """Raised by a script: the transcription fails with this code and message."""

    def __init__(self, code: str, message: str = ""):
        super().__init__(message or code)
        self.code = code


def mark_of(pcm: bytes) -> int:
    return round(int.from_bytes(pcm[:2], "little", signed=True) / 32767 * 100) if len(pcm) >= 2 else 0


def echo(body: dict) -> str:
    """What a chat body asked to clean up, given back: the text after the prompt's last lead-in."""
    content = next((message["content"] for message in reversed(body.get("messages", []))
                    if message.get("role") == "user"), "")
    for lead in ("Output the text only:\n", "output only it:\n", "Phrase:\n"):
        if lead in content:
            content = content.rsplit(lead, 1)[1]
            break
    if body.get("response_format", {}).get("type") == "json_object":
        return json.dumps({"text": content, "edit": None})
    return content


class Socket:
    """One realtime connection, spoken over websockets' sans-I/O protocol on the HTTP handler's own socket."""

    def __init__(self, stub: ApiStub, handler: BaseHTTPRequestHandler, number: int):
        self.stub, self.handler, self.number = stub, handler, number
        self.protocol = ServerProtocol(max_size=None, state=State.OPEN)  # frames; the handshake has its own
        self.lock = threading.Lock()
        self.buffer = b""
        self.items = 0
        self.item = self._next_item()
        self.previous: str | None = None
        self.commits = 0
        self.closed = False

    def _next_item(self) -> str:
        self.items += 1
        return f"item_{self.number}_{self.items}"

    def handshake(self, path: str) -> None:
        headers = Headers()
        for name, value in self.handler.headers.items():
            headers[name] = value
        # the handler has read the request already: one protocol answers it, a fresh one in OPEN parses frames
        shake = ServerProtocol()
        shake.send_response(shake.accept(Request(path, headers)))
        for data in shake.data_to_send():
            self.handler.wfile.write(data)

    def send(self, event: dict) -> None:
        with self.lock:
            if self.closed:
                return
            self.protocol.send_text(json.dumps(event).encode())
            self._write()

    def _write(self) -> None:
        for data in self.protocol.data_to_send():
            try:
                if data:
                    self.handler.wfile.write(data)
                    self.handler.wfile.flush()
            except OSError:
                self.closed = True

    def drop(self) -> None:
        """Gone without a goodbye, as a network that fails."""
        self.closed = True
        try:
            self.handler.connection.shutdown(2)
        except OSError:
            pass

    def serve(self) -> None:
        self.send({"type": "session.created", "event_id": "event_1",
                   "session": {"type": "transcription", "id": f"sess_{self.number}"}})
        while not self.closed:
            try:
                data = self.handler.rfile.read1(65536)
            except OSError:
                break
            with self.lock:
                if data:
                    self.protocol.receive_data(data)
                else:
                    self.protocol.receive_eof()
                frames = self.protocol.events_received()
                self._write()
            for frame in frames:
                if frame.opcode == Opcode.TEXT:
                    self._event(json.loads(frame.data))
            if not data or self.protocol.close_expected():
                break
        self.closed = True

    def _event(self, event: dict) -> None:
        kind = event.get("type")
        with self.stub.lock:
            self.stub.received.append((self.number, kind))
        if kind == "session.update":
            with self.stub.lock:
                self.stub.sessions.append(event)
            self.send({"type": "session.updated", "event_id": "event_2", "session": event.get("session")})
        elif kind == "input_audio_buffer.append":
            first = not self.buffer
            self.buffer += base64.b64decode(event.get("audio", ""))
            if first and self.stub.live_deltas:
                self.send({"type": "conversation.item.input_audio_transcription.delta", "item_id": self.item,
                           "content_index": 0, "delta": f"hearing {mark_of(self.buffer)}"})
        elif kind == "input_audio_buffer.clear":
            self.buffer, self.item = b"", self._next_item()
            self.send({"type": "input_audio_buffer.cleared"})
        elif kind == "input_audio_buffer.commit":
            if not self.buffer:
                self.send({"type": "error", "error": {"type": "invalid_request_error",
                                                      "code": "input_audio_buffer_commit_empty",
                                                      "message": "buffer too small", "event_id": event.get("event_id")}})
                return
            audio, item, self.buffer = self.buffer, self.item, b""
            self.item = self._next_item()
            self.send({"type": "input_audio_buffer.committed", "item_id": item, "previous_item_id": self.previous})
            self.previous = item
            self.commits += 1
            with self.stub.lock:
                self.stub.committed.append((mark_of(audio), len(audio) / 2 / RATE))
                drop = self.stub.drop_after is not None and self.commits >= self.stub.drop_after and self.number == 1
            if drop:
                self.drop()
                return
            threading.Thread(target=self._transcribe, args=(item, audio), daemon=True).start()

    def _transcribe(self, item: str, audio: bytes) -> None:
        mark, seconds = mark_of(audio), len(audio) / 2 / RATE
        with self.stub.lock:
            attempt = self.stub.attempts[mark] = self.stub.attempts.get(mark, 0) + 1
        try:
            delay, text = self.stub.speak(mark, seconds, attempt)
        except StubError as exc:
            self.send({"type": "conversation.item.input_audio_transcription.failed", "item_id": item,
                       "content_index": 0, "error": {"type": "transcription_error", "code": exc.code,
                                                     "message": str(exc)}})
            return
        time.sleep(delay)
        self.send({"type": "conversation.item.input_audio_transcription.delta", "item_id": item,
                   "content_index": 0, "delta": text})
        self.send({"type": "conversation.item.input_audio_transcription.completed", "item_id": item,
                   "content_index": 0, "transcript": text})


class ApiStub:

    def __init__(self, port: int = 0, auto: bool = True):
        self.lock = threading.Lock()
        self.auto = auto
        self.live_deltas = True
        self.drop_after: int | None = None  # the first socket drops after this many commits
        self.speak = lambda mark, seconds, attempt: (0.05, f"final {mark}")
        self.transcribe = lambda mark, seconds, attempt: (0.05, 200, {"text": f"http {mark}"})
        self.received: list[tuple[int, str]] = []
        self.sessions: list[dict] = []
        self.committed: list[tuple[int, float]] = []
        self.attempts: dict[int, int] = {}
        self.connections: list[dict] = []
        self.http: list[dict] = []
        self.chats: list[dict] = []
        self.sockets: list[Socket] = []
        stub = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _json(self, status: int, payload: dict, headers: dict | None = None) -> None:
                data = json.dumps(payload).encode()
                self.send_response(status)
                for name, value in {"Content-Type": "application/json", "Content-Length": str(len(data)),
                                    **(headers or {})}.items():
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                path = urlsplit(self.path).path
                if path == "/v1/models":
                    with stub.lock:
                        stub.http.append({"path": path, "headers": dict(self.headers)})
                    ids = (["auto"] if stub.auto else []) + [AUTO_MODEL, "parakeet"]
                    self._json(200, {"object": "list", "data": [{"id": id, "object": "model"} for id in ids]})
                elif path == "/v1/realtime" and self.headers.get("Upgrade", "").lower() == "websocket":
                    with stub.lock:
                        number = len(stub.connections) + 1
                        stub.connections.append({"path": self.path, "headers": dict(self.headers)})
                    socket = Socket(stub, self, number)
                    stub.sockets.append(socket)
                    socket.handshake(self.path)
                    socket.serve()
                    self.close_connection = True
                else:
                    self._json(404, {"error": {"message": "not found"}})

            def do_POST(self):
                path = urlsplit(self.path).path
                body = self.rfile.read(int(self.headers["Content-Length"]))
                with stub.lock:
                    stub.http.append({"path": path, "headers": dict(self.headers)})
                if path == "/v1/audio/transcriptions":
                    wav = body[body.index(b"RIFF"):body.rindex(b"\r\n--")]
                    mark = mark_of(wav[44:46])
                    with stub.lock:
                        attempt = stub.attempts[mark] = stub.attempts.get(mark, 0) + 1
                    delay, status, payload = stub.transcribe(mark, (len(wav) - 44) / 2 / 16000, attempt)
                    time.sleep(delay)
                    self._json(status, payload)
                elif path == "/v1/chat/completions":
                    request = json.loads(body)
                    with stub.lock:
                        stub.chats.append(request)
                    model = AUTO_MODEL if request.get("model") == "auto" else request.get("model")
                    text = echo(request)
                    resolved = {"X-Model-Resolved": model}
                    if not request.get("stream"):
                        self._json(200, {"model": model, "choices": [{"message": {"role": "assistant",
                                                                                  "content": text},
                                                                      "finish_reason": "stop"}],
                                         "usage": {"prompt_tokens": 10, "completion_tokens": 3}}, resolved)
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Transfer-Encoding", "chunked")
                    for name, value in resolved.items():
                        self.send_header(name, value)
                    self.end_headers()
                    half = len(text) // 2
                    chunks = [{"model": model, "choices": [{"index": 0, "delta": {"role": "assistant",
                                                                                  "content": text[:half]}}]},
                              {"model": model, "choices": [{"index": 0, "delta": {"content": text[half:]},
                                                            "finish_reason": "stop"}]},
                              {"model": model, "choices": [], "usage": {"prompt_tokens": 10,
                                                                        "completion_tokens": 3}}]
                    for chunk in [*(f"data: {json.dumps(chunk)}\n\n" for chunk in chunks), "data: [DONE]\n\n"]:
                        data = chunk.encode()
                        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                    self.wfile.write(b"0\r\n\r\n")
                else:
                    self._json(404, {"error": {"message": "not found"}})

        self.server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}/v1"

    def kinds(self, number: int | None = None) -> list[str]:
        with self.lock:
            return [kind for at, kind in self.received if number is None or at == number]

    def close(self) -> None:
        for socket in self.sockets:
            socket.drop()
        self.server.shutdown()
        self.server.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8791)
    args = parser.parse_args()
    stub = ApiStub(args.port)
    print(f"API stub at {stub.base}", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        stub.close()


if __name__ == "__main__":
    main()
