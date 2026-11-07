"""Vegeta Live: speech to text and cleanup over one WebSocket to Vegeta, opened through a Citadel session.

`POST {base}/v1/dictation/sessions` with the Citadel key files the session and answers `{session_id, ticket,
endpoints}`; the first endpoint that connects (in list order, CONNECT_TIMEOUT_S each) carries it, the ticket sent as
`X-Dictation-Ticket`. The socket opens when a recording starts, so it is warm for the first phrase, stays open
while it records and KEEP_S after the last use, and opens on demand for a request outside a recording.

Protocol (specs/dictation-stream.md), one socket, JSON control and binary audio:
    {"op":"transcribe","id":n,"final":bool} then one binary frame, 16 kHz mono PCM16  →  {"op":"text","id":n,"text","ms"}
    {"op":"chat","id":n,"body":{OpenAI chat body}}  →  {"op":"delta","id":n,…} … {"op":"done","id":n,"usage","ms"}
    {"op":"ping"} → {"op":"pong"};  {"op":"cancel","id":n};  {"op":"error","id":n,"code","message"}
A newer caption replaces the one still unanswered, here and at Vegeta; finals never wait behind captions.

A socket that drops, or goes quiet past a ping, is opened again and every unanswered request is sent again (the audio
is still here). When it cannot be opened, every waiting and later request fails with vegeta.Unavailable until the
next recording starts, and the callers take the Vegeta HTTP path (vegeta.py, cleanup.py) for the rest of that take.
"""
from __future__ import annotations

import asyncio
import http.client
import itertools
import json
import os
import socket
import sys
import threading
import time
from typing import NamedTuple
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import numpy as np
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed, InvalidStatus, WebSocketException

import remote as vegeta  # the Citadel HTTP side, now remote.py
from segmenter import SAMPLE_RATE

ENGINE = "vegeta-live"
BASE = "https://citadel.albastov.com"
CLIENT = "Iridium Live"
SESSION_TIMEOUT_S = 4.0
CONNECT_TIMEOUT_S = 2.0
KEEP_S = 60.0  # open this long after the recording stopped or the last answer came
OPEN_TRIES = 2
OPEN_PAUSE_S = 0.25
TICK_S = 0.25
QUIET_S = 1.5  # requests waiting and nothing heard this long: ping
IDLE_PING_S = 15.0
PONG_TIMEOUT_S = 3.0
CAPTION_EVERY_S = 0.5
CAPTION_REPLACE_S = 2.0  # a caption unanswered this long is replaced by a newer one
LONGEST_MS = 1e7  # a larger `ms` value is a clock, not a duration


class Refused(RuntimeError):
    """Vegeta answered one request with an error; the socket itself is fine."""

    def __init__(self, message: str, code: str = "", status: int = 0):
        super().__init__(message)
        self.code = code
        self.status = status


class Answer(NamedTuple):
    text: str
    ms: dict  # Vegeta's timings for it, durations only
    round_trip_ms: int


class Chat(NamedTuple):
    text: str
    finish: str | None
    usage: dict
    ms: dict
    ttft_ms: int | None  # the first delta, as this Mac saw it
    round_trip_ms: int


def durations(ms) -> dict:
    """The values of a reply's `ms` that are durations: a model state or a clock reading is left out."""
    if not isinstance(ms, dict):
        return {}
    return {str(name): round(float(value), 1) for name, value in ms.items()
            if isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value < LONGEST_MS}


def explain(exc: BaseException) -> str:
    """Why the stream failed a request, in plain words."""
    if isinstance(exc, TimeoutError):
        return "Vegeta Live did not answer in time"
    if isinstance(exc, (vegeta.Unavailable, Refused)):
        return str(exc)
    return f"Vegeta Live failed: {exc}"


def piece(reply: dict) -> str:
    """The text a `delta` carries: `text`, `content` or `delta`, or an OpenAI chunk's `choices[0].delta.content`."""
    for name in ("text", "content", "delta"):
        value = reply.get(name)
        if isinstance(value, str):
            return value
        if isinstance(value, dict) and isinstance(value.get("content"), str):
            return value["content"]
    try:
        return reply["choices"][0]["delta"].get("content") or ""
    except (KeyError, IndexError, TypeError, AttributeError):
        return ""


class Request:

    def __init__(self, header: dict, audio: bytes | None, answered=None):
        self.header, self.audio, self.answered = header, audio, answered
        self.id = header["id"]
        self.caption = header["op"] == "transcribe" and not header.get("final")
        self.done = threading.Event()
        self.reply: dict = {}
        self.error: BaseException | None = None
        self.parts: list[str] = []
        self.finish: str | None = None
        self.sent_at = 0.0
        self.first_at: float | None = None
        self.generation = 0  # the socket it was last sent on


class Stream:
    """One live session with Vegeta, shared by speech to text and cleanup; safe to call from any thread."""

    ENGINE = ENGINE

    def __init__(self, base: str = BASE, notice=None):
        self.base = base.rstrip("/")
        self.notice = notice or (lambda text: None)
        self.lock = threading.Lock()
        self.requests: dict[int, Request] = {}  # unanswered, in the order they were made
        self.ids = itertools.count(1)
        self.down: str | None = None  # why live gave up; cleared when the next recording starts
        self.recording = False
        self.used = float("-inf")
        self.captions = Captions(self)
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True, name="vegeta-live")
        self.thread.start()
        # used on the loop's thread only
        self.ws = None
        self.task: asyncio.Task | None = None
        self.session: dict | None = None
        self.endpoint = ""
        self.generation = 0
        self.heard_at = 0.0
        self.ping_at: float | None = None
        self.sending = asyncio.Lock()

    # Callers

    def begin(self) -> None:
        """A recording starts: open the socket now, and try live again if it gave up on the last take."""
        with self.lock:
            self.recording, self.down, self.used = True, None, time.monotonic()
        self._wake()

    def end(self) -> None:
        """The recording stopped: the socket stays KEEP_S for its last phrases, the polish and the next take."""
        with self.lock:
            self.recording, self.used = False, time.monotonic()

    def offer(self, audio: np.ndarray, phrase) -> tuple[str, float] | None:
        return self.captions.offer(audio, phrase)

    def transcribe(self, samples: np.ndarray, final: bool = True, timeout_s: float = 8.0, phrase=None) -> Answer:
        deadline = time.monotonic() + timeout_s
        request = self._send({"op": "transcribe", "final": final}, vegeta.pcm16(samples))
        reply = self._wait(request, deadline)
        return Answer(" ".join(str(reply.get("text") or "").split()), durations(reply.get("ms")),
                      round((time.monotonic() - request.sent_at) * 1000))

    def caption(self, samples: np.ndarray, answered) -> bool:
        """Never waits. A caption on the audio so far; it replaces any caption still unanswered. `answered(reply)`
        runs on the stream's thread. False when no socket is open: a caption does not open one."""
        audio = vegeta.pcm16(samples)
        with self.lock:
            if self.down is not None or self.ws is None:
                return False
            for old in [request for request in self.requests.values() if request.caption]:
                del self.requests[old.id]
            self._new({"op": "transcribe", "final": False}, audio, answered)
        self._wake()
        return True

    def chat(self, body: dict, deadline: float) -> Chat:
        """One OpenAI chat body, answered as a stream of deltas; `deadline` is on time.monotonic()."""
        request = self._send({"op": "chat", "body": body}, None)
        reply = self._wait(request, deadline)
        first = None if request.first_at is None else round((request.first_at - request.sent_at) * 1000)
        return Chat("".join(request.parts) or str(reply.get("text") or ""),
                    reply.get("finish_reason") or request.finish, reply.get("usage") or {},
                    durations(reply.get("ms")), first, round((time.monotonic() - request.sent_at) * 1000))

    def give_up(self, reason: BaseException | str) -> None:
        """Live failed this take: what waits and what comes until the next recording fails at once, so the callers
        take the HTTP path. Says so once."""
        reason = reason if isinstance(reason, str) else explain(reason)
        with self.lock:
            if self.down is not None:
                return
            self.down = reason
            waiting = list(self.requests.values())
            self.requests.clear()
        print(f"vegeta live: {reason}", file=sys.stderr, flush=True)
        self.notice(f"{reason}: using Vegeta")
        for request in waiting:
            request.error = vegeta.Unavailable(reason)
            request.done.set()
        self._wake()

    def close(self) -> None:
        with self.lock:
            self.recording, self.used, self.down = False, float("-inf"), self.down or "Vegeta Live closed"
        asyncio.run_coroutine_threadsafe(self._shut(), self.loop).result(5)
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(5)
        self.loop.close()

    def _new(self, header: dict, audio: bytes | None, answered=None) -> Request:
        """Under the lock."""
        request = Request({"op": header["op"], "id": next(self.ids), **header}, audio, answered)
        self.requests[request.id] = request
        self.used = time.monotonic()
        return request

    def _send(self, header: dict, audio: bytes | None) -> Request:
        with self.lock:
            if self.down is not None:
                raise vegeta.Unavailable(self.down)
            request = self._new(header, audio)
        self._wake()
        return request

    def _wait(self, request: Request, deadline: float) -> dict:
        if not request.done.wait(max(0.0, deadline - time.monotonic())):
            with self.lock:
                waiting = self.requests.pop(request.id, None) is not None
            if waiting:
                asyncio.run_coroutine_threadsafe(self._post({"op": "cancel", "id": request.id}), self.loop)
            raise TimeoutError("Vegeta Live did not answer in time")
        if request.error is not None:
            raise request.error
        return request.reply

    def _wanted(self) -> bool:
        with self.lock:
            return self.down is None and (self.recording or bool(self.requests)
                                          or time.monotonic() - self.used < KEEP_S)

    # The loop's thread

    def _wake(self) -> None:
        self.loop.call_soon_threadsafe(self._woken)

    def _woken(self) -> None:
        if self.task is None or self.task.done():
            if self._wanted():
                self.task = self.loop.create_task(self._guarded())
        elif self.ws is not None:
            self.loop.create_task(self._flush(self.ws))

    async def _guarded(self) -> None:
        try:
            await self._keep()
        except Exception as exc:  # a bug here must not leave requests waiting for nothing
            self.give_up(f"Vegeta Live failed: {exc}")

    async def _keep(self) -> None:
        """Holds a socket while one is wanted: opens it, sends what waits, reopens it when it drops."""
        self.session = None  # a new session each time the socket opens from idle
        opened, tries = False, 0
        while self._wanted():
            try:
                ws = await self._open()
            except vegeta.Unavailable as exc:
                tries += 1
                if tries < OPEN_TRIES:
                    await asyncio.sleep(OPEN_PAUSE_S)
                    continue
                self.give_up("Vegeta Live dropped" if opened else str(exc))
                return
            if opened:
                print(f"vegeta live: reopened, sending {len(self.requests)} again", file=sys.stderr, flush=True)
            opened, tries = True, 0
            self.generation += 1
            self.ws, self.heard_at, self.ping_at = ws, time.monotonic(), None
            idle = False
            try:
                await self._flush(ws)
                idle = await self._serve(ws)
            finally:
                self.ws = None
                if idle:
                    await ws.close()
                else:
                    ws.transport.abort()

    async def _open(self):
        if self.session is None:
            self.session = await asyncio.to_thread(self._new_session)
        for renewed in (False, True):
            session, reason = self.session, "Vegeta Live did not connect"
            for url in session["endpoints"]:
                try:
                    ws = await connect(url, additional_headers={"X-Dictation-Ticket": session["ticket"]},
                                       user_agent_header=vegeta.USER_AGENT, open_timeout=CONNECT_TIMEOUT_S,
                                       compression=None, ping_interval=None, close_timeout=1.0, max_size=None,
                                       proxy=None)
                except InvalidStatus as exc:
                    status = exc.response.status_code
                    reason = ("Vegeta Live: session refused" if status in (401, 403)
                              else vegeta.say(status, "", "Vegeta Live"))
                    if status in (401, 403) and not renewed:
                        break  # the ticket expired: a new session, once
                except (OSError, TimeoutError, WebSocketException):
                    continue
                else:
                    self.endpoint = url
                    return ws
            else:
                raise vegeta.Unavailable(reason)
            self.session = await asyncio.to_thread(self._new_session)
        raise vegeta.Unavailable(reason)

    def _new_session(self) -> dict:
        key = os.environ.get(vegeta.KEY_ENV)
        if not key:
            raise vegeta.Unavailable("Vegeta Live: no key")
        split = urlsplit(self.base)
        kind = http.client.HTTPSConnection if split.scheme == "https" else http.client.HTTPConnection
        conn = kind(split.hostname, split.port, timeout=SESSION_TIMEOUT_S)
        body = json.dumps({"client": CLIENT})  # `device` names the Vegeta side (Citadel picks it), not this Mac
        headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                   "User-Agent": vegeta.USER_AGENT}
        try:
            conn.request("POST", split.path.rstrip("/") + "/v1/dictation/sessions", body, headers)
            response = conn.getresponse()
            data = response.read()
        except TimeoutError:
            raise vegeta.Unavailable("Vegeta Live did not answer in time") from None
        except (OSError, http.client.HTTPException):
            raise vegeta.Unavailable("Vegeta Live is offline") from None
        finally:
            conn.close()
        if response.status not in (200, 201):
            raise vegeta.Unavailable("Vegeta Live is not available" if response.status == 404 else
                                     vegeta.say(response.status, vegeta.error_code(data), "Vegeta Live"))
        try:
            answer = json.loads(data)
            session = {"id": str(answer["session_id"]), "ticket": str(answer["ticket"])}
            session["endpoints"] = [self._url(endpoint["url"], session["id"]) for endpoint in answer["endpoints"]
                                    if endpoint.get("url")]
        except (ValueError, KeyError, TypeError, AttributeError):
            raise vegeta.Unavailable("Vegeta Live sent no session") from None
        if not session["endpoints"]:
            raise vegeta.Unavailable("Vegeta Live sent no endpoint")
        print(f"vegeta live: session {session['id']}", file=sys.stderr, flush=True)
        return session

    def _url(self, url: str, session_id: str) -> str:
        """An endpoint as a ws(s) URL that names the session; a path is on the base's host."""
        split = urlsplit(url if "://" in url else self.base + "/" + url.lstrip("/"))
        scheme = {"https": "wss", "http": "ws"}.get(split.scheme, split.scheme)
        query = dict(parse_qsl(split.query))
        query.setdefault("session", session_id)
        return urlunsplit((scheme, split.netloc, split.path, urlencode(query), ""))

    async def _serve(self, ws) -> bool:
        """Reads until the socket goes away or is no longer wanted (True); pings when it has been quiet."""
        reader = asyncio.ensure_future(self._read(ws))
        try:
            while True:
                await asyncio.wait({reader}, timeout=TICK_S)
                if reader.done():
                    return False
                if not self._wanted():
                    return True
                now = time.monotonic()
                if self.ping_at is not None:
                    if now - self.ping_at > PONG_TIMEOUT_S:
                        print("vegeta live: no answer to a ping, reopening", file=sys.stderr, flush=True)
                        return False
                elif now - self.heard_at > (QUIET_S if self.requests else IDLE_PING_S):
                    self.ping_at = now
                    await self._post({"op": "ping"})
        finally:
            reader.cancel()

    async def _read(self, ws) -> None:
        try:
            async for message in ws:
                self.heard_at, self.ping_at = time.monotonic(), None
                if isinstance(message, bytes):
                    continue
                try:
                    reply = json.loads(message)
                except ValueError:
                    continue
                if isinstance(reply, dict) and not self._dispatch(reply):
                    return
        except ConnectionClosed:
            pass

    def _dispatch(self, reply: dict) -> bool:
        """One reply; False when the session itself was refused and the socket must be opened anew."""
        op, number = reply.get("op"), reply.get("id")
        if op == "error" and number is None:
            print(f"vegeta live: session error {reply.get('code')}: {reply.get('message')}", file=sys.stderr,
                  flush=True)
            self.session = None
            return False
        now = time.monotonic()
        with self.lock:
            request = self.requests.get(number)
            if request is None:
                return True  # replaced, cancelled or given up
            if op == "delta":
                request.parts.append(piece(reply))
                if request.first_at is None:
                    request.first_at = now
                try:
                    request.finish = reply.get("finish_reason") or reply["choices"][0].get("finish_reason")
                except (KeyError, IndexError, TypeError, AttributeError):
                    pass
                return True
            if op not in ("text", "done", "error"):
                return True
            del self.requests[number]
            self.used = now
        if op == "error":
            code = str(reply.get("code") or "")
            request.error = Refused(str(reply.get("message") or code or "error"), code, int(reply.get("status") or 0))
        else:
            request.reply = reply
        request.done.set()
        if request.answered is not None and op == "text":
            request.answered(reply)
        return True

    async def _flush(self, ws) -> None:
        """Sends what this socket has not carried yet: finals and chats first, then the caption."""
        async with self.sending:
            if self.ws is not ws:
                return
            with self.lock:
                due = sorted((request for request in self.requests.values() if request.generation != self.generation),
                             key=lambda request: request.caption)
                for request in due:
                    request.generation = self.generation
            for request in due:
                with self.lock:
                    if request.id not in self.requests:
                        continue
                    request.parts.clear()
                    request.first_at = None
                    request.sent_at = time.monotonic()
                try:
                    await ws.send(json.dumps(request.header))
                    if request.audio is not None:
                        await ws.send(request.audio)
                except ConnectionClosed:
                    return  # the reader sees it; all that is unanswered goes again on the next socket

    async def _post(self, message: dict) -> None:
        async with self.sending:
            if self.ws is None:
                return
            try:
                await self.ws.send(json.dumps(message))
            except ConnectionClosed:
                pass

    async def _shut(self) -> None:
        if self.task is not None and not self.task.done():
            self.task.cancel()
            try:
                await self.task
            except BaseException:
                pass
        if self.ws is not None:
            self.ws.transport.abort()


class Captions:
    """Captions over the socket: the open phrase's audio so far at most every `every_s`, the next only once the last
    is answered or older than `replace_s`, when the newer replaces it. An answer for a closed phrase is dropped."""

    def __init__(self, stream: Stream, every_s: float = CAPTION_EVERY_S, replace_s: float = CAPTION_REPLACE_S):
        self.stream = stream
        self.every_s = every_s
        self.replace_s = replace_s
        self.lock = threading.Lock()
        self.phrase = None
        self.answer: tuple[str, float] | None = None
        self.asked = 0
        self.busy = False
        self.sent_at = float("-inf")

    def offer(self, audio: np.ndarray, phrase) -> tuple[str, float] | None:
        """Never waits. Returns the newest answer for this phrase not handed out yet: its text and audio seconds."""
        with self.lock:
            if phrase != self.phrase:
                self.phrase, self.answer, self.busy = phrase, None, False
            answer, self.answer = self.answer, None
            now = time.monotonic()
            if now - self.sent_at >= self.every_s and (not self.busy or now - self.sent_at >= self.replace_s):
                self.asked += 1
                number, seconds = self.asked, len(audio) / SAMPLE_RATE
                if self.stream.caption(audio, lambda reply: self._answered(reply, phrase, number, seconds)):
                    self.busy, self.sent_at = True, now
        return answer

    def _answered(self, reply: dict, phrase, number: int, seconds: float) -> None:
        text = " ".join(str(reply.get("text") or "").split())
        with self.lock:
            if number != self.asked:
                return
            self.busy = False
            if text and phrase == self.phrase:
                self.answer = (text, seconds)
