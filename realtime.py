"""Live speech to text over an OpenAI-style realtime transcription socket (OpenAI's published events only).

`GET {base}/realtime?intent=transcription` as ws(s), `Authorization: Bearer {key}`. Once it opens: `session.update`
with `session.type: "transcription"`, `audio.input.format` pcm at 24 kHz, `audio.input.transcription.model` and
`audio.input.turn_detection: null`: Iridium's own segmenter says where a phrase ends. While a phrase is open its audio
goes out as `input_audio_buffer.append` (16 kHz resampled to 24 kHz, base64 PCM16); when it closes the rest follows
and `input_audio_buffer.commit`. The server answers `input_audio_buffer.committed` with the phrase's `item_id`, then
`conversation.item.input_audio_transcription.delta` events and `.completed` with the transcript, or `.failed`.
Completions of different phrases may come in any order: they are matched by `item_id`.

Captions are the `.delta` events of the phrase still open (servers that stream as audio arrives, such as
gpt-live-transcribe, send them before the commit); a server that sends deltas only after the commit gives no captions.
A phrase dropped before its commit (a cancelled recording) is cleared with `input_audio_buffer.clear`.

The socket opens when a recording starts, stays open while it records and KEEP_S after the last use. One that drops
is opened again and every unanswered phrase is sent again (the audio is still here). When it cannot be opened, or an
`error` or `.failed` comes, the stream gives up until the next recording starts, and the lane (remote.py) sends that
phrase and the rest of the take to `POST {base}/audio/transcriptions`.
"""
from __future__ import annotations

import asyncio
import base64
import itertools
import json
import sys
import threading
import time
from typing import NamedTuple
from urllib.parse import urlsplit, urlunsplit

import numpy as np
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed, InvalidStatus, WebSocketException

import remote
from segmenter import SAMPLE_RATE

ENGINE = "api-live"
RATE = 24000  # what OpenAI's realtime API takes as audio/pcm
CHUNK = RATE // 2  # samples per append when a whole phrase goes out at once
KEEP_S = 60.0  # open this long after the recording stopped or the last answer came
CONNECT_TIMEOUT_S = 3.0
OPEN_TRIES = 2
OPEN_PAUSE_S = 0.25
TICK_S = 0.25
PING_S = 10.0  # WebSocket pings, so a socket that went quiet is noticed


class Refused(RuntimeError):
    """The server answered one phrase with `error` or `.failed`."""

    def __init__(self, message: str, code: str = ""):
        super().__init__(message)
        self.code = code


class Answer(NamedTuple):
    text: str
    ms: dict | None
    round_trip_ms: int


def covered(samples: int) -> int:
    """How many 24 kHz samples `samples` 16 kHz samples cover."""
    return 0 if samples <= 0 else (samples - 1) * RATE // SAMPLE_RATE + 1


def upsample(audio: np.ndarray, start: int, end: int) -> np.ndarray:
    """24 kHz samples [start, end) of 16 kHz `audio`, interpolated at their absolute positions, so pieces resampled
    one after another join without a seam."""
    return np.interp(np.arange(start, end) * (SAMPLE_RATE / RATE), np.arange(len(audio)), audio).astype(np.float32)


def socket_url(base: str) -> str:
    split = urlsplit(base)
    scheme = {"https": "wss", "http": "ws"}.get(split.scheme, split.scheme)
    return urlunsplit((scheme, split.netloc, split.path.rstrip("/") + "/realtime", "intent=transcription", ""))


def session_update(model: str) -> dict:
    return {"type": "session.update", "event_id": "session",
            "session": {"type": "transcription",
                        "audio": {"input": {"format": {"type": "audio/pcm", "rate": RATE},
                                            "transcription": {"model": model},
                                            "turn_detection": None}}}}


class Request:
    """One phrase: open while the segmenter still adds audio, final once it closed."""

    def __init__(self, number: int, key, audio: np.ndarray):
        self.number = number
        self.key = key  # (take, started), as the segmenter names the phrase
        self.audio = audio  # 16 kHz
        self.final = False
        self.generation = 0  # the socket the counts below are about
        self.sent = 0  # 24 kHz samples sent
        self.committed = False
        self.item: str | None = None
        self.done = threading.Event()
        self.text = ""
        self.error: BaseException | None = None
        self.sent_at = 0.0


class Stream:
    """One realtime transcription session at the API; safe to call from any thread."""

    ENGINE = ENGINE

    def __init__(self, endpoint: remote.Endpoint = remote.api, model: str = "parakeet", notice=None):
        self.endpoint = endpoint
        self.model = model
        self.notice = notice or (lambda text: None)
        self.lock = threading.Lock()
        self.order: list[Request] = []  # unanswered phrases, in the order they were spoken
        self.numbers = itertools.count(1)
        self.down: str | None = None  # why live gave up; cleared when the next recording starts
        self.recording = False
        self.used = float("-inf")
        self.clearing = False  # a dropped phrase left audio in the server's buffer
        self.caption: tuple | None = None  # (phrase, text, seconds) not handed out yet
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True, name="realtime")
        self.thread.start()
        # used on the loop's thread only
        self.ws = None
        self.task: asyncio.Task | None = None
        self.generation = 0
        self.waiting: list[Request] = []  # committed on this socket, `committed` not heard yet
        self.items: dict[str, Request] = {}
        self.open_item: str | None = None  # the item the deltas of the phrase in the buffer belong to
        self.closed_items: set[str] = set()  # items committed whose `committed` event has not come yet
        self.parts: dict[str, list[str]] = {}
        self.sending = asyncio.Lock()

    # Callers

    def begin(self) -> None:
        """A recording starts: open the socket now, and try live again if it gave up on the last take."""
        with self.lock:
            self.recording, self.down, self.used = True, None, time.monotonic()
        self._wake()

    def end(self) -> None:
        """The recording stopped: the socket stays KEEP_S for its last phrases and the next take."""
        with self.lock:
            self.recording, self.used = False, time.monotonic()

    def configure(self, model: str | None = None) -> None:
        """A new model, base or key: the next socket carries it; an open one is closed and its phrases sent again."""
        with self.lock:
            self.model = model or self.model
        self.loop.call_soon_threadsafe(self._drop)

    def offer(self, audio: np.ndarray, phrase) -> tuple[str, float] | None:
        """Never waits. The open phrase's audio so far goes out; returns its newest caption not handed out yet."""
        with self.lock:
            if self.down is not None:
                return None
            request = self._request(phrase)
            if not request.final:
                request.audio = np.asarray(audio, dtype=np.float32)
            caption, self.caption = self.caption, None
            self.used = time.monotonic()
        self._wake()
        if caption is None or caption[0] != phrase:
            return None
        return caption[1], caption[2]

    def transcribe(self, samples: np.ndarray, timeout_s: float = 8.0, phrase=None) -> Answer:
        """The phrase closed: the rest of its audio and the commit go out; waits for its transcript."""
        deadline = time.monotonic() + timeout_s
        with self.lock:
            if self.down is not None:
                raise remote.Unavailable(self.down)
            request = self._request(phrase)
            request.audio, request.final = np.asarray(samples, dtype=np.float32), True
            self.used = time.monotonic()
        self._wake()
        if not request.done.wait(max(0.0, deadline - time.monotonic())):
            raise TimeoutError(f"{self.endpoint.name} live did not answer in time")
        if request.error is not None:
            raise request.error
        return Answer(request.text, None, round((time.monotonic() - request.sent_at) * 1000))

    def forget(self, take) -> None:
        """A cancelled or failed take: its phrases are dropped, and what of them is in the server's buffer cleared."""
        with self.lock:
            dropped = [request for request in self.order if request.key and request.key[0] == take]
            if not dropped:
                return
            self.clearing = self.clearing or any(not request.committed and request.sent for request in dropped)
            self.order = [request for request in self.order if request not in dropped]
        for request in dropped:
            request.error = remote.Unavailable("dropped")
            request.done.set()
        self._wake()

    def give_up(self, reason: BaseException | str) -> None:
        """Live failed this take: what waits and what comes until the next recording fails at once, so the lane
        takes the HTTP path. Says so once."""
        reason = reason if isinstance(reason, str) else self._explain(reason)
        with self.lock:
            if self.down is not None:
                return
            self.down = reason
            waiting, self.order, self.caption = self.order, [], None
        print(f"realtime: {reason}", file=sys.stderr, flush=True)
        self.notice(f"{reason}: using {self.endpoint.name} over HTTP")
        for request in waiting:
            request.error = remote.Unavailable(reason)
            request.done.set()
        self._wake()

    def close(self) -> None:
        with self.lock:
            self.recording, self.used, self.down = False, float("-inf"), self.down or "closed"
        asyncio.run_coroutine_threadsafe(self._shut(), self.loop).result(5)
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(5)
        self.loop.close()

    def _explain(self, exc: BaseException) -> str:
        name = self.endpoint.name
        if isinstance(exc, TimeoutError):
            return f"{name} live did not answer in time"
        if isinstance(exc, (remote.Unavailable, Refused)):
            return str(exc)
        return f"{name} live failed: {exc}"

    def _request(self, phrase) -> Request:
        """Under the lock: the request for this phrase, new at the end of the order if there is none."""
        if phrase is not None:
            for request in self.order:
                if request.key == phrase:
                    return request
        request = Request(next(self.numbers), phrase, np.zeros(0, dtype=np.float32))
        self.order.append(request)
        return request

    def _wanted(self) -> bool:
        with self.lock:
            return self.down is None and (self.recording or bool(self.order)
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

    def _drop(self) -> None:
        if self.ws is not None:
            self.ws.transport.abort()

    async def _guarded(self) -> None:
        try:
            await self._keep()
        except Exception as exc:  # a bug here must not leave phrases waiting for nothing
            self.give_up(f"{self.endpoint.name} live failed: {exc}")

    async def _keep(self) -> None:
        """Holds a socket while one is wanted: opens it, sends what waits, reopens it when it drops."""
        opened, tries = False, 0
        while self._wanted():
            try:
                ws = await self._open()
            except remote.Unavailable as exc:
                tries += 1
                if tries < OPEN_TRIES:
                    await asyncio.sleep(OPEN_PAUSE_S)
                    continue
                self.give_up(f"{self.endpoint.name} live dropped" if opened else str(exc))
                return
            if opened:
                print(f"realtime: reopened, sending {len(self.order)} again", file=sys.stderr, flush=True)
            opened, tries = True, 0
            self.generation += 1
            self.waiting, self.items, self.parts, self.open_item, self.closed_items = [], {}, {}, None, set()
            with self.lock:
                self.clearing = False  # a new session starts with an empty buffer
                model = self.model
            self.ws = ws
            idle = False
            try:
                await ws.send(json.dumps(session_update(model)))
                await self._flush(ws)
                idle = await self._serve(ws)
            except ConnectionClosed:
                pass
            finally:
                self.ws = None
                if idle:
                    await ws.close()
                else:
                    ws.transport.abort()

    async def _open(self):
        name, key = self.endpoint.name, self.endpoint.key()
        if not key:
            raise remote.Unavailable(f"{name}: no key")
        try:
            return await connect(socket_url(self.endpoint.base),
                                 additional_headers={"Authorization": f"Bearer {key}"},
                                 user_agent_header=remote.USER_AGENT, open_timeout=CONNECT_TIMEOUT_S,
                                 compression=None, ping_interval=PING_S, ping_timeout=PING_S, close_timeout=1.0,
                                 max_size=None, proxy=None)
        except InvalidStatus as exc:
            status = exc.response.status_code
            raise remote.Unavailable(f"{name} has no live transcription" if status == 404
                                     else remote.say(status, "", name)) from None
        except (OSError, TimeoutError, WebSocketException):
            raise remote.Unavailable(f"{name} live did not connect") from None

    async def _serve(self, ws) -> bool:
        """Reads until the socket goes away (False) or is no longer wanted (True)."""
        reader = asyncio.ensure_future(self._read(ws))
        try:
            while True:
                await asyncio.wait({reader}, timeout=TICK_S)
                if reader.done():
                    return False
                if not self._wanted():
                    return True
        finally:
            reader.cancel()

    async def _read(self, ws) -> None:
        try:
            async for message in ws:
                if isinstance(message, bytes):
                    continue
                try:
                    event = json.loads(message)
                except ValueError:
                    continue
                if isinstance(event, dict) and not self._dispatch(event):
                    return
        except ConnectionClosed:
            pass

    def _dispatch(self, event: dict) -> bool:
        """One server event; False when the session itself failed."""
        kind = event.get("type")
        if kind == "input_audio_buffer.committed":
            if self.waiting:
                request = self.waiting.pop(0)
                request.item = str(event.get("item_id") or "")
                self.items[request.item] = request
                self.closed_items.discard(request.item)
            return True
        if kind == "conversation.item.input_audio_transcription.delta":
            item = str(event.get("item_id") or "")
            self.parts.setdefault(item, []).append(str(event.get("delta") or ""))
            if item not in self.items and item not in self.closed_items:
                self.open_item = item
                self._caption(" ".join("".join(self.parts[item]).split()))
            return True
        if kind == "conversation.item.input_audio_transcription.completed":
            item = str(event.get("item_id") or "")
            self.parts.pop(item, None)
            self._answer(self.items.pop(item, None), text=" ".join(str(event.get("transcript") or "").split()))
            return True
        if kind == "conversation.item.input_audio_transcription.failed":
            item = str(event.get("item_id") or "")
            error = event.get("error") if isinstance(event.get("error"), dict) else {}
            self._answer(self.items.pop(item, None), error=Refused(
                f"{self.endpoint.name}: {error.get('message') or 'transcription failed'}", str(error.get("code") or "")))
            return True
        if kind == "error":
            error = event.get("error") if isinstance(event.get("error"), dict) else {}
            message = f"{self.endpoint.name}: {error.get('message') or error.get('code') or 'error'}"
            number = str(error.get("event_id") or "").removeprefix("commit-")
            request = next((request for request in self.waiting if str(request.number) == number), None)
            if request is not None:
                self.waiting.remove(request)
                self._answer(request, error=Refused(message, str(error.get("code") or "")))
                return True
            print(f"realtime: session error: {message}", file=sys.stderr, flush=True)
            self.give_up(message)
            return False
        return True  # session.created, session.updated and the rest

    def _caption(self, text: str) -> None:
        """A delta for the phrase in the server's buffer: the first one not committed yet."""
        with self.lock:
            request = next((request for request in self.order if not request.committed), None)
            if request is not None and text:
                self.caption = (request.key, text, len(request.audio) / SAMPLE_RATE)

    def _answer(self, request: Request | None, text: str = "", error: BaseException | None = None) -> None:
        if request is None:
            return
        with self.lock:
            if request not in self.order:
                return  # dropped or given up
            self.order.remove(request)
            self.used = time.monotonic()
        request.text, request.error = text, error
        request.done.set()

    async def _flush(self, ws) -> None:
        """Sends what this socket has not carried yet, in spoken order: an open phrase's audio so far, a closed
        phrase's rest and its commit. Nothing goes past an open phrase: the buffer holds one phrase at a time."""
        async with self.sending:
            if self.ws is not ws:
                return
            with self.lock:
                clearing, self.clearing = self.clearing, False
            try:
                if clearing:
                    if self.open_item is not None:
                        self.closed_items.add(self.open_item)
                        self.open_item = None
                    await ws.send(json.dumps({"type": "input_audio_buffer.clear"}))
                while True:
                    with self.lock:
                        request = next((request for request in self.order
                                        if request.generation != self.generation or not request.committed), None)
                        if request is None:
                            return
                        if request.generation != self.generation:
                            request.generation, request.sent, request.committed = self.generation, 0, False
                        audio, final, start = request.audio, request.final, request.sent
                        end = covered(len(audio))
                        if not final and end - start <= 0:
                            return
                        request.sent = max(start, end)
                        if final:
                            request.committed, request.sent_at = True, time.monotonic()
                    for at in range(start, end, CHUNK):
                        piece = remote.pcm16(upsample(audio, at, min(end, at + CHUNK)))
                        await ws.send(json.dumps({"type": "input_audio_buffer.append",
                                                  "audio": base64.b64encode(piece).decode()}))
                    if not final:
                        return
                    self.waiting.append(request)
                    if self.open_item is not None:  # its late deltas are not the next phrase's captions
                        self.closed_items.add(self.open_item)
                        self.open_item = None
                    await ws.send(json.dumps({"type": "input_audio_buffer.commit",
                                              "event_id": f"commit-{request.number}"}))
            except ConnectionClosed:
                return  # the reader sees it; all that is unanswered goes again on the next socket

    async def _shut(self) -> None:
        if self.task is not None and not self.task.done():
            self.task.cancel()
            try:
                await self.task
            except BaseException:
                pass
        if self.ws is not None:
            self.ws.transport.abort()
