"""Speech to text at an OpenAI-compatible API: Albastar (`https://api.albastov.com/v1`) or any other base URL and key.

After stop (engine "api"): a take's phrases are held while it records and, when it stops, all go out at once as
`POST {base}/audio/transcriptions`; they may come back in any order and are handed on in the order they were spoken.
Live (engine "api-live", realtime.py): phrases go over the realtime socket while the take records; one the socket
cannot answer gives the socket up for the rest of the take, and that phrase and the rest go the HTTP way at once.
A phrase the API fails either moves the rest of its take to Phonon-2 on this Mac (fallback "local") or fails the take
(fallback "fail"); the next take tries the API again. The take's audio is on disk either way (takes.py).
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

ENGINE = "api"
BASE = "https://api.albastov.com/v1"
KEY_ENV = "CITADEL_API_KEY"
NAME = "Albastar"
USER_AGENT = "Iridium Live"  # Cloudflare in front of Citadel refuses the Python urllib default
QUEUE_TIMEOUT_S = 10  # how long a job may wait in the server's queue
PARTIAL_EVERY_S = 1.0
LOCAL_LOAD_TIMEOUT_S = 75.0
MODELS_TIMEOUT_S = 10.0
IDLE_CONNECTIONS = 4
RELEASE = "release"


class Endpoint:
    """The API in use: its base URL, the environment variable that holds its key, and its name for the status line.
    Speech, the realtime socket and cleanup all read it at the moment they call, so a change applies to the next call."""

    def __init__(self, base: str = BASE, key_env: str = KEY_ENV, name: str = NAME):
        self.base, self.key_env, self.name = base.rstrip("/"), key_env, name

    def update(self, base: str | None = None, key_env: str | None = None, name: str | None = None) -> bool:
        """True when something changed."""
        before = (self.base, self.key_env, self.name)
        self.base = (base or self.base).rstrip("/")
        self.key_env = key_env or self.key_env
        self.name = name or self.name
        return before != (self.base, self.key_env, self.name)

    def key(self) -> str | None:
        return os.environ.get(self.key_env) or None

    def connection(self, timeout: float) -> http.client.HTTPConnection:
        split = urlsplit(self.base)
        kind = http.client.HTTPSConnection if split.scheme == "https" else http.client.HTTPConnection
        return kind(split.hostname, split.port, timeout=timeout)

    def path(self, route: str) -> str:
        return urlsplit(self.base).path + route


api = Endpoint()


class Unavailable(RuntimeError):
    """The API did not answer with text. The message is in plain words, for the status line."""

    def __init__(self, message: str, status: int = 0):
        super().__init__(message)
        self.status = status


def say(status: int, code: str = "", name: str = NAME) -> str:
    """What an HTTP failure from the API means, in plain words."""
    if code in ("queued", "queue-timeout", "gpu-busy"):
        return f"{name} is busy"
    if code in ("model_loading", "model_not_loaded"):
        return f"{name} is loading the model"
    if status == 401:
        return f"{name}: key rejected"
    if status == 403:
        return f"{name}: key not allowed"
    if status == 404:
        return f"{name}: no such model"
    if status == 413:
        return f"{name}: recording too long"
    if status == 429:
        return f"{name}: too many requests"
    if status in (400, 415, 422):
        return f"{name} refused the request"
    if status >= 500:
        return f"{name} is offline"
    return f"{name} answered {status}"


def error_code(data: bytes) -> str:
    """The `code` of an error body: `{"error": {"code"}}` on the OpenAI-shaped routes, `{"error": "<code>"}` else."""
    try:
        error = json.loads(data).get("error")
    except Exception:
        return ""
    if isinstance(error, dict):
        return str(error.get("code") or "")
    return error if isinstance(error, str) else ""


def explain(exc: BaseException, name: str = NAME) -> str:
    """A failed call to the API in plain words: errors that already are come through unchanged."""
    if isinstance(exc, TimeoutError):
        return f"{name} did not answer in time"
    if isinstance(exc, (OSError, http.client.HTTPException)):
        return f"{name} is offline"
    return str(exc)


def pcm16(samples: np.ndarray) -> bytes:
    """Mono float samples as little-endian 16-bit PCM."""
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


def models(endpoint: Endpoint = api) -> list[str]:
    """The model ids of `GET {base}/models`, in the order the API lists them. Raises Unavailable."""
    key = endpoint.key()
    if not key:
        raise Unavailable(f"{endpoint.name}: no key")
    conn = endpoint.connection(MODELS_TIMEOUT_S)
    try:
        conn.request("GET", endpoint.path("/models"), headers={"Authorization": f"Bearer {key}",
                                                              "User-Agent": USER_AGENT})
        response = conn.getresponse()
        data = response.read()
    except Exception as exc:
        raise Unavailable(explain(exc, endpoint.name)) from None
    finally:
        conn.close()
    if response.status != 200:
        raise Unavailable(say(response.status, error_code(data), endpoint.name), response.status)
    try:
        listed = json.loads(data)["data"]
        return [str(model["id"]) for model in listed if isinstance(model, dict) and model.get("id")]
    except (ValueError, KeyError, TypeError):
        raise Unavailable(f"{endpoint.name} sent no model list") from None


def choices(ids: list[str]) -> list[str]:
    """The cleanup model picker: `auto` first when the API lists it (and only then), the other ids as listed."""
    return (["auto"] if "auto" in ids else []) + [model for model in dict.fromkeys(ids) if model != "auto"]


class Client:
    """`POST {base}/audio/transcriptions` over a few kept-alive connections, safe to call from several threads."""

    def __init__(self, endpoint: Endpoint = api, model: str = "parakeet", timeout_s: float = 8.0):
        self.endpoint = endpoint
        self.model = model
        self.timeout_s = timeout_s
        self.idle: list[tuple[str, http.client.HTTPConnection]] = []
        self.closed = False
        self.lock = threading.Lock()

    def transcribe(self, samples: np.ndarray) -> str:
        name = self.endpoint.name
        key = self.endpoint.key()
        if not key:
            raise Unavailable(f"{name}: no key")
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
                    raise Unavailable(f"{name} sent no text", status) from None
                return " ".join(str(text or "").split())
            code = error_code(data)
            # The same body is the same job (Citadel derives an idempotency key from it): asking again waits for it.
            if (status == 503 and code == "queued" and retry_after is not None
                    and time.monotonic() + retry_after < deadline):
                time.sleep(retry_after)
                continue
            raise Unavailable(say(status, code, name), status)

    def _post(self, route: str, body: bytes, headers: dict, deadline: float,
              timeout_s: float) -> tuple[int, float | None, bytes]:
        name = self.endpoint.name
        for attempt in (0, 1):
            left = deadline - time.monotonic()
            if left <= 0:
                raise Unavailable(f"{name} did not answer in {timeout_s:g} s")
            base, conn, reused = self._connection(left)
            try:
                conn.timeout = left
                if conn.sock is not None:
                    conn.sock.settimeout(left)
                conn.request("POST", urlsplit(base).path + route, body, headers)
                if conn.sock is not None:
                    conn.sock.settimeout(max(0.01, deadline - time.monotonic()))
                response = conn.getresponse()
                data = response.read()
            except TimeoutError:
                conn.close()
                raise Unavailable(f"{name} did not answer in {timeout_s:g} s") from None
            except (OSError, http.client.HTTPException):
                conn.close()
                if reused and attempt == 0:
                    continue  # a kept-alive connection the server had already closed
                raise Unavailable(f"{name} is offline") from None
            if response.will_close:
                conn.close()
            else:
                self._release(base, conn)
            return response.status, _seconds(response.getheader("retry-after")), data
        raise Unavailable(f"{name} is offline")

    def _connection(self, timeout: float) -> tuple[str, http.client.HTTPConnection, bool]:
        base = self.endpoint.base
        with self.lock:
            for index, (at, conn) in enumerate(self.idle):
                if at == base:
                    del self.idle[index]
                    return base, conn, True
        return base, self.endpoint.connection(timeout), False

    def _release(self, base: str, conn: http.client.HTTPConnection) -> None:
        with self.lock:
            if not self.closed and base == self.endpoint.base and len(self.idle) < IDLE_CONNECTIONS:
                self.idle.append((base, conn))
                return
        conn.close()

    def close(self) -> None:
        """Closes the kept-alive connections, and those of requests still under way when they end."""
        with self.lock:
            idle, self.idle, self.closed = self.idle, [], True
        for _, conn in idle:
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
        self.live = None  # the realtime stream it goes over first, if any
        self.via: str | None = ENGINE  # who transcribed it: "api", "api-live", or None for this Mac
        self.done = False
        self.dropped = False
        self.sent_at = 0.0
        self.answered_at = 0.0
        self.waiter: threading.Event | None = None

    @property
    def key(self):
        """The phrase as captions name it: its take and when it started."""
        return self.take, (self.meta[0] if self.meta else None)


class Lane:
    """Finals to the API, handed to `emit` in the order they were submitted, whatever order the answers come in."""

    def __init__(self, client: Client, emit, *, fallback: str = "local", load_local=None, release_local=None,
                 notice=None):
        self.client = client
        self.emit = emit
        self.fallback = fallback
        self.load_local = load_local
        self.release_local = release_local or (lambda: None)
        self.notice = notice or (lambda text: None)
        self.partials = Partials(client)
        self.lock = threading.Lock()
        self.order: list[Phrase] = []
        self.outstanding: dict[str | None, int] = {}
        self.fallen: dict[str | None, str] = {}
        self.failed: dict[str | None, str] = {}
        self.holding: dict[str | None, list[Phrase]] = {}  # after stop: a recording's phrases, sent when it stops
        self.local_jobs: queue.Queue = queue.Queue()
        threading.Thread(target=self._local_work, daemon=True).start()

    def configure(self, model: str | None = None, timeout_s: float | None = None,
                  fallback: str | None = None) -> None:
        if model:
            self.client.model = model
        if timeout_s:
            self.client.timeout_s = min(max(float(timeout_s), 1.0), 60.0)
        if fallback in ("local", "fail"):
            self.fallback = fallback

    def hold(self, take: str | None) -> None:
        """This recording's phrases wait until `send_held`: transcription after stop."""
        with self.lock:
            self.holding.setdefault(take, [])

    def send_held(self, take: str | None) -> None:
        """The recording stopped: its held phrases all go out now, and later ones at once."""
        with self.lock:
            held = self.holding.pop(take, [])
        for phrase in held:
            self._start(phrase)

    def submit(self, audio: np.ndarray, take: str | None, meta=None, live=None) -> Phrase:
        phrase = Phrase(take, audio, meta)
        phrase.live = live
        with self.lock:
            self.outstanding[take] = self.outstanding.get(take, 0) + 1
            self.order.append(phrase)
            if take in self.holding:
                self.holding[take].append(phrase)
                return phrase
        self._start(phrase)
        return phrase

    def _start(self, phrase: Phrase) -> None:
        with self.lock:
            failed = self.failed.get(phrase.take)
            local = phrase.take in self.fallen
        if failed is not None:
            phrase.error = failed
            self._finish(phrase)
        elif local:
            self.local_jobs.put(phrase)
        else:
            threading.Thread(target=self._remote, args=(phrase,), daemon=True).start()

    def troubled(self, take: str | None) -> bool:
        """The API failed this take: it runs on this Mac or has failed, and gets no captions from the API."""
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
            self.holding.pop(take, None)
            self._flush()
        self.close(take)

    def close(self, take: str | None) -> None:
        """The take is over: the next one tries the API again, and this Mac's model goes once no take needs it."""
        with self.lock:
            self.fallen.pop(take, None)
            self.failed.pop(take, None)
            idle = not self.fallen
        if idle:
            self.local_jobs.put(RELEASE)

    def release(self) -> None:
        self.local_jobs.put(RELEASE)

    def transcribe_now(self, audio: np.ndarray) -> str:
        """Blocking, for a retake: the API over HTTP, else this Mac when the fallback is local."""
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
        live = phrase.live
        if live is not None and not live.down:
            try:
                answer = live.transcribe(phrase.audio, timeout_s=self.client.timeout_s, phrase=phrase.key)
            except Exception as exc:
                if phrase.dropped:
                    return  # cancelled: no answer is wanted, and the socket did nothing wrong
                live.give_up(exc)  # this phrase and the rest of the take go the HTTP way
            else:
                phrase.text, phrase.via = answer.text, live.ENGINE
                phrase.answered_at = time.time()
                self._finish(phrase)
                return
        try:
            phrase.text = self.client.transcribe(phrase.audio)
        except Exception as exc:
            self._failed(phrase, explain(exc, self.client.endpoint.name))
            return
        phrase.via = ENGINE
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
                print(f"api fallback: the speech model did not load: {exc}", file=sys.stderr, flush=True)
        loader = threading.Thread(target=load, daemon=True)
        loader.start()
        loader.join(LOCAL_LOAD_TIMEOUT_S)
        if loader.is_alive():
            return None, True
        return (result[0] if result else None), False


class Speech:
    """What the segmenter talks to for the API. Deferred: finals go to the lane and come back as events.
    `holds`: after stop, a recording's phrases wait for its end. `live`: a realtime stream that carries finals and
    captions while it holds."""

    ready = True

    def __init__(self, lane: Lane, deferred: bool = True, live=None, holds: bool = False):
        self.lane = lane
        self.deferred = deferred
        self.live = live
        self.holds = holds

    def partial(self, audio: np.ndarray, phrase) -> tuple[str, float] | None:
        if self.holds or self.lane.troubled(phrase[0]):
            return None
        if self.live is not None and not self.live.down:
            return self.live.offer(audio, phrase)
        return self.lane.partials.offer(audio, phrase)

    def submit(self, audio: np.ndarray, take: str | None, meta) -> None:
        self.lane.submit(audio, take, meta, live=self.live)

    def transcribe_array(self, audio: np.ndarray):
        return self.lane.transcribe_now(audio), None, None

    def blocking(self) -> Speech:
        """The same speech for a retake, which waits for each phrase."""
        return Speech(self.lane, deferred=False)
