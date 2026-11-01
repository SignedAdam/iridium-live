"""A stand-in for Citadel and Vegeta's dictation stream, for the tests and, by hand, for replay.py.

HTTP (Citadel): POST /v1/dictation/sessions, /v1/audio/transcriptions and /v1/chat/completions.
WebSocket (Vegeta through Citadel's relay): /v1/dictation/stream?session=…, the ticket as `Authorization: Bearer`.
Each socket has one speech worker, like Vegeta's single CPU Parakeet: finals in the order they came and always before
captions, and one caption slot that a newer caption replaces. Chats start at once and stream as deltas.

    python tests/stream_stub.py [--port 8790]      then: python replay.py take.wav --base http://127.0.0.1:8790
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import socket
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from websockets.sync.server import serve

SAMPLE_RATE = 16000


class StubError(Exception):
    """Raised by a script: the stub answers with {"op":"error","code","message"}."""

    def __init__(self, code: str, message: str = ""):
        super().__init__(message or code)
        self.code = code


def mark_of(pcm: bytes) -> int:
    """Test audio is a constant tone: every sample is mark / 100."""
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
    """One stream connection: its speech worker and its writer."""

    def __init__(self, stub: StreamStub, ws, number: int):
        self.stub, self.ws, self.number = stub, ws, number
        self.lock = threading.Lock()
        self.work = threading.Condition()
        self.finals: collections.deque = collections.deque()
        self.caption = None
        self.closed = False
        threading.Thread(target=self._speak, daemon=True).start()

    def send(self, message: dict) -> None:
        if self.stub.hung(self.number):
            return
        with self.lock:
            try:
                self.ws.send(json.dumps(message))
            except Exception:
                pass

    def drop(self) -> None:
        """Gone without a goodbye, as a network that fails."""
        try:
            self.ws.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def queue(self, header: dict, pcm: bytes, received: float) -> None:
        job = (header, mark_of(pcm), len(pcm) / 2 / SAMPLE_RATE, received)
        with self.work:
            if header.get("final"):
                self.finals.append(job)
            else:
                if self.caption is not None:
                    self.stub.replaced.append(self.caption[0]["id"])
                self.caption = job
            self.work.notify()

    def cancel(self, number: int) -> None:
        with self.work:
            self.finals = collections.deque(job for job in self.finals if job[0]["id"] != number)
            if self.caption is not None and self.caption[0]["id"] == number:
                self.caption = None

    def _speak(self) -> None:
        while True:
            with self.work:
                self.work.wait_for(lambda: self.closed or self.finals or self.caption)
                if self.closed:
                    return
                if self.finals:
                    job = self.finals.popleft()
                else:
                    job, self.caption = self.caption, None
            if self.stub.parallel and job[0].get("final"):
                threading.Thread(target=self._run, args=job, daemon=True).start()
            else:
                self._run(*job)

    def _run(self, header: dict, mark: int, seconds: float, received: float) -> None:
        final = bool(header.get("final"))
        started = time.monotonic()
        with self.stub.lock:
            self.stub.ran.append(("final" if final else "caption", mark))
            attempt = self.stub.attempts[mark] = self.stub.attempts.get(mark, 0) + 1
        try:
            delay, text = self.stub.speak(mark, final, seconds, attempt)
        except StubError as exc:
            self.send({"op": "error", "id": header["id"], "code": exc.code, "message": str(exc)})
            return
        time.sleep(delay)
        self.send({"op": "text", "id": header["id"], "text": text,
                   "ms": {"received": round(time.time() * 1000), "queued": round((started - received) * 1000, 1),
                          "inference": round(delay * 1000, 1), "model": "warm"}})

    def chat(self, header: dict) -> None:
        sent = time.monotonic()
        try:
            pieces = self.stub.chat(header["body"])
        except StubError as exc:
            self.send({"op": "error", "id": header["id"], "code": exc.code, "message": str(exc)})
            return
        first = None
        for delay, piece in pieces:
            time.sleep(delay)
            first = first if first is not None else time.monotonic()
            self.send({"op": "delta", "id": header["id"], "text": piece})
        self.send({"op": "done", "id": header["id"], "finish_reason": "stop",
                   "usage": {"prompt_tokens": 100, "completion_tokens": len(pieces)},
                   "ms": {"ttft": round(((first or time.monotonic()) - sent) * 1000, 1),
                          "total": round((time.monotonic() - sent) * 1000, 1)}})


class StreamStub:

    def __init__(self, port: int = 0, speak=None, chat=None, http_speak=None, http_chat=None):
        self.speak = speak or (lambda mark, final, seconds, attempt: (0.0, f"{'final' if final else 'caption'} {mark}"))
        self.chat = chat or (lambda body: [(0.0, piece) for piece in re.findall(r"\S+\s*", echo(body))])
        self.http_speak = http_speak or (lambda mark: (200, {"text": f"http {mark}"}))
        self.http_chat = http_chat or (lambda body: (200, {"choices": [{"message": {"content": echo(body)},
                                                                         "finish_reason": "stop"}]}))
        self.lock = threading.Lock()
        self.session_status = 200
        self.refuse_sockets = False
        self.parallel = False  # finals at once, so their answers may come back out of order
        self.drop_on = lambda header, mark: False  # True: the socket fails when this request arrives
        self.hang = set()  # socket numbers that stop answering anything, pings included
        self.endpoints = None  # session id → endpoint list; the stub's own socket by default
        self.sessions: list[dict] = []
        self.connections: list[dict] = []
        self.received: list[tuple[int, str, int]] = []  # socket number, op, mark or request id
        self.ran: list[tuple[str, int]] = []
        self.attempts: dict[int, int] = {}
        self.replaced: list[int] = []
        self.cancelled: list[int] = []
        self.chats: list[dict] = []
        self.http: list[str] = []
        self.sockets: list[Socket] = []

        self.ws_server = serve(self._serve, "127.0.0.1", 0, process_request=self._check, max_size=None,
                               compression=None)
        threading.Thread(target=self.ws_server.serve_forever, daemon=True).start()
        self.ws_url = f"ws://127.0.0.1:{self.ws_server.socket.getsockname()[1]}/v1/dictation/stream"
        stub = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                status, payload = stub._http(self.path, dict(self.headers), body)
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.http_server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.http_server.daemon_threads = True
        threading.Thread(target=self.http_server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.http_server.server_address[1]}"

    def hung(self, number: int) -> bool:
        return number in self.hang

    def close(self) -> None:
        for sock in self.sockets:
            sock.drop()
        self.ws_server.shutdown()
        self.http_server.shutdown()
        self.http_server.server_close()

    def _http(self, path: str, headers: dict, body: bytes) -> tuple[int, dict]:
        with self.lock:
            self.http.append(path)
        if path == "/v1/dictation/sessions":
            if self.session_status != 200:
                return self.session_status, {"error": {"code": "refused"}}
            with self.lock:
                number = len(self.sessions) + 1
                session = {"id": f"ds_{number}", "ticket": f"tk_{number}", "key": headers.get("Authorization"),
                           "body": json.loads(body or b"{}")}
                self.sessions.append(session)
            endpoints = (self.endpoints(session["id"]) if self.endpoints
                         else [{"kind": "relay", "url": self.ws_url}])
            return 200, {"session_id": session["id"], "ticket": session["ticket"], "endpoints": endpoints}
        if path == "/v1/audio/transcriptions":
            wav = body[body.index(b"RIFF"):body.rindex(b"\r\n--")]
            return self.http_speak(mark_of(wav[44:46]))
        if path == "/v1/chat/completions":
            return self.http_chat(json.loads(body))
        return 404, {"error": {"code": "not_found"}}

    def _check(self, connection, request):
        query = parse_qs(urlsplit(request.path).query)
        session = next((item for item in self.sessions if item["id"] == query.get("session", [""])[0]), None)
        if self.refuse_sockets:
            return connection.respond(HTTPStatus.SERVICE_UNAVAILABLE, "busy\n")
        if (session is None or request.headers.get("Authorization") != f"Bearer {session['ticket']}"
                or session.get("expired")):
            return connection.respond(HTTPStatus.UNAUTHORIZED, "bad ticket\n")
        with self.lock:
            self.connections.append({"session": session["id"], "user_agent": request.headers.get("User-Agent")})
        return None

    def _serve(self, ws) -> None:
        ws.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)  # as a real server: no 40 ms Nagle waits
        with self.lock:
            number = len(self.connections)
        conn = Socket(self, ws, number)
        self.sockets.append(conn)
        waiting = None
        try:
            for message in ws:
                received = time.monotonic()
                if isinstance(message, bytes):
                    header, waiting = waiting, None
                    if header is None:
                        continue
                    mark = mark_of(message)
                    with self.lock:
                        self.received.append((number, "final" if header.get("final") else "caption", mark))
                    if self.drop_on(header, mark):
                        conn.drop()
                        return
                    conn.queue(header, message, received)
                    continue
                header = json.loads(message)
                op = header.get("op")
                if op == "ping":
                    conn.send({"op": "pong"})
                elif op == "cancel":
                    self.cancelled.append(header["id"])
                    conn.cancel(header["id"])
                elif op == "transcribe":
                    waiting = header
                elif op == "chat":
                    with self.lock:
                        self.received.append((number, "chat", header["id"]))
                        self.chats.append(header["body"])
                    if self.drop_on(header, None):
                        conn.drop()
                        return
                    threading.Thread(target=conn.chat, args=(header,), daemon=True).start()
        except Exception:
            pass
        finally:
            with conn.work:
                conn.closed = True
                conn.work.notify()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--stt-ms", type=float, default=150, help="inference time per final, per 4 s of audio")
    parser.add_argument("--token-ms", type=float, default=15, help="time per streamed chat token")
    args = parser.parse_args()
    finals = [0]

    def speak(mark, final, seconds, attempt):
        if final:
            finals[0] += 1
        words = " ".join(["word"] * max(1, round(seconds * 2.5)))
        return args.stt_ms / 1000 * max(seconds, 0.5) / 4, f"phrase {finals[0] + (0 if final else 1)} {words}"

    def chat(body):
        pieces = re.findall(r"\S+\s*", echo(body))
        return [(0.12 if i == 0 else args.token_ms / 1000, piece) for i, piece in enumerate(pieces)]

    stub = StreamStub(args.port, speak=speak, chat=chat)
    print(f"Citadel stub at {stub.base}, stream at {stub.ws_url}", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        stub.close()


if __name__ == "__main__":
    main()
