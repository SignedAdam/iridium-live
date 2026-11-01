"""Vegeta: speech to text through Citadel, the estate GPU behind an OpenAI-compatible API.

Finals, the phrases the segmenter closes, go out the moment they close and may come back in any order; they are
handed on in the order they were spoken. Partials, the captions while a phrase is still open, are one request at a
time on the audio so far, at most every PARTIAL_EVERY_S, and an answer for a phrase that has closed is dropped.
A final that fails either moves the rest of its take to Phonon-2 on this Mac (fallback "local") or fails the take
(fallback "fail"); the next take tries Vegeta again. The take's audio is on disk either way (takes.py).

With a live stream (vegeta_live.py, engine "vegeta-live") finals and captions go over its socket first; a final the
socket cannot answer gives the stream up for the rest of the take, and that phrase and the rest take the path above.
"""
from __future__ import annotations

import http.client
import io
import json
import os
import queue
import sys
import threading
import time
import uuid
import wave
from urllib.parse import urlsplit

import numpy as np

from segmenter import SAMPLE_RATE

ENGINE = "vegeta"
BASE = "https://citadel.albastov.com/v1"
KEY_ENV = "CITADEL_API_KEY"
USER_AGENT = "Iridium Live"  # Cloudflare in front of Citadel refuses the Python urllib default
QUEUE_TIMEOUT_S = 10  # how long a dictation job may wait in Vegeta's queue
PARTIAL_EVERY_S = 1.0
LOCAL_LOAD_TIMEOUT_S = 75.0
IDLE_CONNECTIONS = 4
RELEASE = "release"


class Unavailable(RuntimeError):
    """Vegeta did not answer with text. The message is in plain words, for the status line."""

    def __init__(self, message: str, status: int = 0):
        super().__init__(message)
        self.status = status


def say(status: int, code: str = "") -> str:
    """What an HTTP failure from Citadel means, in plain words."""
    if code in ("queued", "queue-timeout", "gpu-busy"):
        return "Vegeta is busy"
    if code == "model_loading":
        return "Vegeta is loading the model"
    if status == 401:
        return "Vegeta: key rejected"
    if status == 403:
        return "Vegeta: key not allowed"
    if status == 404:
        return "Vegeta: no such model"
    if status == 413:
        return "Vegeta: recording too long"
    if status == 429:
        return "Vegeta: too many requests"
    if status in (400, 415, 422):
        return "Vegeta refused the request"
    if status >= 500:
        return "Vegeta is offline"
    return f"Vegeta answered {status}"


def error_code(data: bytes) -> str:
    """The `code` of an error body: `{"error": {"code"}}` on the OpenAI-shaped routes, `{"error": "<code>"}` else."""
    try:
        error = json.loads(data).get("error")
    except Exception:
        return ""
    if isinstance(error, dict):
        return str(error.get("code") or "")
    return error if isinstance(error, str) else ""


def explain(exc: BaseException) -> str:
    """A failed call to Citadel in plain words: errors that already are come through unchanged."""
    if isinstance(exc, TimeoutError):
        return "Vegeta did not answer in time"
    if isinstance(exc, (OSError, http.client.HTTPException)):
        return "Vegeta is offline"
    return str(exc)


def pcm16(samples: np.ndarray) -> bytes:
    """16 kHz mono float samples as little-endian 16-bit PCM."""
    return (np.clip(np.round(np.asarray(samples, dtype=np.float32) * 32767.0), -32768, 32767)
            .astype("<i2").tobytes())


def wav_bytes(samples: np.ndarray) -> bytes:
    out = io.BytesIO()
    with wave.open(out, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm16(samples))
    return out.getvalue()


def multipart(fields: dict[str, str], wav: bytes) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
             for name, value in fields.items()]
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="phrase.wav"\r\n'
                 f"Content-Type: audio/wav\r\n\r\n".encode() + wav + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def _seconds(header: str | None) -> float | None:
    try:
        return max(0.0, float(header)) if header else None
    except ValueError:
        return None


class Client:
    """`POST /audio/transcriptions` over a few kept-alive connections, safe to call from several threads."""

    def __init__(self, base: str = BASE, model: str = "parakeet", timeout_s: float = 8.0):
        self.base = base.rstrip("/")
        self.model = model
        self.timeout_s = timeout_s
        self.idle: list[http.client.HTTPConnection] = []
        self.closed = False
        self.lock = threading.Lock()

    def transcribe(self, samples: np.ndarray) -> str:
        key = os.environ.get(KEY_ENV)
        if not key:
            raise Unavailable("Vegeta: no key")
        timeout_s = self.timeout_s
        deadline = time.monotonic() + timeout_s
        body, content_type = multipart({"model": self.model, "response_format": "json"}, wav_bytes(samples))
        headers = {"Authorization": f"Bearer {key}", "Content-Type": content_type, "User-Agent": USER_AGENT,
                   "X-Queue-Timeout": str(QUEUE_TIMEOUT_S), "Connection": "keep-alive"}
        while True:
            status, retry_after, data = self._post("/audio/transcriptions", body, headers, deadline, timeout_s)
            if status == 200:
                try:
                    text = json.loads(data)["text"]
                except Exception:
                    raise Unavailable("Vegeta sent no text", status) from None
                return " ".join(str(text or "").split())
            code = error_code(data)
            # The same body is the same job (Citadel derives an idempotency key from it): asking again waits for it.
            if (status == 503 and code == "queued" and retry_after is not None
                    and time.monotonic() + retry_after < deadline):
                time.sleep(retry_after)
                continue
            raise Unavailable(say(status, code), status)

    def _post(self, path: str, body: bytes, headers: dict, deadline: float,
              timeout_s: float) -> tuple[int, float | None, bytes]:
        for attempt in (0, 1):
            left = deadline - time.monotonic()
            if left <= 0:
                raise Unavailable(f"Vegeta did not answer in {timeout_s:g} s")
            conn, reused = self._connection(left)
            try:
                conn.timeout = left
                if conn.sock is not None:
                    conn.sock.settimeout(left)
                conn.request("POST", urlsplit(self.base).path + path, body, headers)
                if conn.sock is not None:
                    conn.sock.settimeout(max(0.01, deadline - time.monotonic()))
                response = conn.getresponse()
                data = response.read()
            except TimeoutError:
                conn.close()
                raise Unavailable(f"Vegeta did not answer in {timeout_s:g} s") from None
            except (OSError, http.client.HTTPException):
                conn.close()
                if reused and attempt == 0:
                    continue  # a kept-alive connection the server had already closed
                raise Unavailable("Vegeta is offline") from None
            if response.will_close:
                conn.close()
            else:
                self._release(conn)
            return response.status, _seconds(response.getheader("retry-after")), data
        raise Unavailable("Vegeta is offline")

    def _connection(self, timeout: float) -> tuple[http.client.HTTPConnection, bool]:
        with self.lock:
            if self.idle:
                return self.idle.pop(), True
        split = urlsplit(self.base)
        kind = http.client.HTTPSConnection if split.scheme == "https" else http.client.HTTPConnection
        return kind(split.hostname, split.port, timeout=timeout), False

    def _release(self, conn: http.client.HTTPConnection) -> None:
        with self.lock:
            if not self.closed and len(self.idle) < IDLE_CONNECTIONS:
                self.idle.append(conn)
                return
        conn.close()

    def close(self) -> None:
        """Closes the kept-alive connections, and those of requests still under way when they end."""
        with self.lock:
            idle, self.idle, self.closed = self.idle, [], True
        for conn in idle:
            conn.close()


class Partials:
    """Captions while a phrase is open: one request at a time on the audio so far, at most every `every_s`."""

    def __init__(self, client: Client, every_s: float = PARTIAL_EVERY_S):
        self.client = client
        self.every_s = every_s
        self.lock = threading.Lock()
        self.busy = False
        self.sent_at = float("-inf")
        self.phrase = None
        self.answer: tuple[str, float] | None = None

    def offer(self, audio: np.ndarray, phrase) -> tuple[str, float] | None:
        """Never waits. Returns the newest answer for this phrase not handed out yet: its text and audio seconds."""
        with self.lock:
            if phrase != self.phrase:
                self.phrase, self.answer = phrase, None
            answer, self.answer = self.answer, None
            if not self.busy and time.monotonic() - self.sent_at >= self.every_s:
                self.busy, self.sent_at = True, time.monotonic()
                threading.Thread(target=self._ask, args=(np.array(audio, dtype=np.float32), phrase),
                                 daemon=True).start()
        return answer

    def _ask(self, audio: np.ndarray, phrase) -> None:
        try:
            text = self.client.transcribe(audio)
        except Exception:
            text = ""  # a caption that does not come is only a caption
        with self.lock:
            self.busy = False
            if text and phrase == self.phrase:
                self.answer = (text, len(audio) / SAMPLE_RATE)


class Phrase:
    """One closed phrase on its way to text."""

    def __init__(self, take: str | None, audio: np.ndarray, meta):
        self.take, self.audio, self.meta = take, audio, meta
        self.text = ""
        self.error = ""
        self.local = False
        self.live = False
        self.via: str | None = ENGINE  # who transcribed it: "vegeta", "vegeta-live", or None for this Mac
        self.stream_ms: dict | None = None  # the live stream's `ms` for it
        self.done = False
        self.dropped = False
        self.sent_at = 0.0
        self.answered_at = 0.0
        self.waiter: threading.Event | None = None


class Lane:
    """Finals to Vegeta, handed to `emit` in the order they were submitted, whatever order the answers come in."""

    def __init__(self, client: Client, emit, *, fallback: str = "local", load_local=None, release_local=None,
                 notice=None, live=None):
        self.client = client
        self.emit = emit
        self.fallback = fallback
        self.load_local = load_local
        self.release_local = release_local or (lambda: None)
        self.notice = notice or (lambda text: None)
        self.partials = Partials(client)
        self.live = live  # a vegeta_live.Stream, for phrases submitted live
        self.lock = threading.Lock()
        self.order: list[Phrase] = []
        self.outstanding: dict[str | None, int] = {}
        self.fallen: dict[str | None, str] = {}
        self.failed: dict[str | None, str] = {}
        self.local_jobs: queue.Queue = queue.Queue()
        threading.Thread(target=self._local_work, daemon=True).start()

    def configure(self, model: str | None = None, timeout_s: float | None = None, fallback: str | None = None,
                  base: str | None = None) -> None:
        if model:
            self.client.model = model
        if timeout_s:
            self.client.timeout_s = min(max(float(timeout_s), 1.0), 60.0)
        if fallback in ("local", "fail"):
            self.fallback = fallback
        if base:  # Citadel's origin, for the replay script and tests; the app never sends it
            self.client.base = base.rstrip("/") + "/v1"
            if self.live is not None:
                self.live.base = base.rstrip("/")

    def submit(self, audio: np.ndarray, take: str | None, meta=None, live: bool = False) -> Phrase:
        phrase = Phrase(take, audio, meta)
        phrase.live = live and self.live is not None
        with self.lock:
            self.outstanding[take] = self.outstanding.get(take, 0) + 1
            self.order.append(phrase)
            failed = self.failed.get(take)
            local = take in self.fallen
        if failed is not None:
            phrase.error = failed
            self._finish(phrase)
        elif local:
            self.local_jobs.put(phrase)
        else:
            threading.Thread(target=self._remote, args=(phrase,), daemon=True).start()
        return phrase

    def troubled(self, take: str | None) -> bool:
        """Vegeta failed this take: it runs on this Mac or has failed, and gets no captions from Vegeta."""
        with self.lock:
            return take in self.fallen or take in self.failed

    def pending(self, take: str | None = ...) -> int:
        """Phrases submitted and not yet `done` by the caller: for one take, or for all."""
        with self.lock:
            if take is ...:
                return sum(self.outstanding.values())
            return self.outstanding.get(take, 0)

    def done(self, phrase: Phrase) -> None:
        """The caller has handled an emitted phrase."""
        with self.lock:
            if phrase.dropped or phrase.take not in self.outstanding:
                return
            self.outstanding[phrase.take] -= 1
            if self.outstanding[phrase.take] <= 0:
                del self.outstanding[phrase.take]

    def forget(self, take: str | None) -> None:
        """Drop everything of a take that was cancelled or failed for another reason."""
        with self.lock:
            for phrase in self.order:
                if phrase.take == take:
                    phrase.dropped = True
            self.outstanding.pop(take, None)
            self._flush()
        self.close(take)

    def close(self, take: str | None) -> None:
        """The take is over: the next one tries Vegeta again, and this Mac's model goes once no take needs it."""
        with self.lock:
            self.fallen.pop(take, None)
            self.failed.pop(take, None)
            idle = not self.fallen
        if idle:
            self.local_jobs.put(RELEASE)

    def release(self) -> None:
        self.local_jobs.put(RELEASE)

    def transcribe_now(self, audio: np.ndarray, live: bool = False) -> str:
        """Blocking, for a retake: the live stream when asked, then Vegeta, else this Mac when the fallback is local."""
        if live and self.live is not None:
            try:
                return self.live.transcribe(audio, timeout_s=self.client.timeout_s).text
            except Exception as exc:
                self.live.give_up(exc)
        try:
            return self.client.transcribe(audio)
        except Unavailable as exc:
            if self.fallback != "local":
                raise
            self.notice(f"{exc}: using this Mac")
        phrase = Phrase(None, audio, None)
        phrase.waiter = threading.Event()
        self.local_jobs.put(phrase)
        phrase.waiter.wait()
        if phrase.error:
            raise Unavailable(phrase.error)
        return phrase.text

    def _remote(self, phrase: Phrase) -> None:
        phrase.sent_at = time.time()
        if phrase.live:
            try:
                answer = self.live.transcribe(phrase.audio, timeout_s=self.client.timeout_s)
            except Exception as exc:
                self.live.give_up(exc)  # this phrase and the rest of the take go the HTTP way
            else:
                phrase.text, phrase.stream_ms, phrase.via = answer.text, answer.ms, self.live.ENGINE
                phrase.answered_at = time.time()
                self._finish(phrase)
                return
        try:
            phrase.text = self.client.transcribe(phrase.audio)
        except Exception as exc:
            self._failed(phrase, explain(exc))
            return
        phrase.answered_at = time.time()
        self._finish(phrase)

    def _failed(self, phrase: Phrase, reason: str) -> None:
        with self.lock:
            if phrase.dropped:
                return
            local = self.fallback == "local"
            first = phrase.take not in (self.fallen if local else self.failed)
            (self.fallen if local else self.failed).setdefault(phrase.take, reason)
        if not local:
            phrase.error = reason
            self._finish(phrase)
            return
        if first:
            self.notice(f"{reason}: using this Mac")
        self.local_jobs.put(phrase)

    def _finish(self, phrase: Phrase) -> None:
        with self.lock:
            phrase.done = True
            self._flush()

    def _flush(self) -> None:
        while self.order and (self.order[0].done or self.order[0].dropped):
            head = self.order.pop(0)
            if not head.dropped:
                self.emit(head)

    def _local_work(self) -> None:
        model, wedged = None, False
        while True:
            job = self.local_jobs.get()
            if job == RELEASE:
                with self.lock:
                    idle = not self.fallen
                if idle and model is not None and self.local_jobs.empty():
                    model = None
                    self.release_local()
                continue
            phrase: Phrase = job
            if phrase.dropped:
                continue
            if model is None and not wedged:
                model, wedged = self._load()
            if model is None:
                phrase.error = "The speech model did not load"
            else:
                phrase.sent_at = time.time()
                try:
                    phrase.text, _, _ = model.transcribe_array(phrase.audio)
                    phrase.local, phrase.via = True, None
                except Exception as exc:
                    phrase.error = f"This Mac could not transcribe: {exc}"
                phrase.answered_at = time.time()
            if phrase.waiter is not None:
                phrase.waiter.set()
            else:
                self._finish(phrase)

    def _load(self):
        """This Mac's model, or None; a load that outlives the watchdog is given up on for good."""
        if self.load_local is None:
            return None, True
        result: list = []

        def load() -> None:
            try:
                result.append(self.load_local())
            except Exception as exc:
                print(f"vegeta fallback: the speech model did not load: {exc}", file=sys.stderr, flush=True)
        loader = threading.Thread(target=load, daemon=True)
        loader.start()
        loader.join(LOCAL_LOAD_TIMEOUT_S)
        if loader.is_alive():
            return None, True
        return (result[0] if result else None), False


class Speech:
    """What the segmenter talks to in vegeta mode. Deferred: finals go to the lane and come back as events.
    Live: finals and captions go over the lane's live stream while it holds."""

    ready = True

    def __init__(self, lane: Lane, deferred: bool = True, live: bool = False):
        self.lane = lane
        self.deferred = deferred
        self.live = live

    def partial(self, audio: np.ndarray, phrase) -> tuple[str, float] | None:
        if self.lane.troubled(phrase[0]):
            return None
        if self.live and not self.lane.live.down:
            return self.lane.live.captions.offer(audio, phrase)
        return self.lane.partials.offer(audio, phrase)

    def submit(self, audio: np.ndarray, take: str | None, meta) -> None:
        self.lane.submit(audio, take, meta, live=self.live)

    def transcribe_array(self, audio: np.ndarray):
        return self.lane.transcribe_now(audio, self.live), None, None

    def blocking(self) -> Speech:
        """The same speech for a retake, which waits for each phrase."""
        return Speech(self.lane, deferred=False, live=self.live)
