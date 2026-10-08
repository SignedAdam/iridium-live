# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "fermion-research==0.2.4",
#     "mlx==0.32.3",
#     "mlx-audio==0.5.7",
#     "onnxruntime==1.30.0",
#     "scipy",
#     "sounddevice",
#     "soundfile",
#     "zstandard",
# ]
# ///
import argparse
import ctypes
import faulthandler
import gc
import json
import math
import os
import re
import queue
import sys
import threading
import time
import wave
from pathlib import Path
from typing import NamedTuple

os.environ.setdefault("USE_TORCH", "0")

import mlx.core as mx
import numpy as np
import sounddevice as sd
from fermion._speech.engine import read_audio

import archive as archive_module
import asr
import cleanup as cleanup_model
import segmenter as seg

TYPE_HOLD_S = 0.7
STALL_S = 90.0
STOP_WAIT_S = 3.0
BLOCK = int(0.05 * seg.SAMPLE_RATE)
SILENT_AFTER_S = 1.0
CACHE_DIR = Path.home() / ".cache" / "iridium-live"
if not CACHE_DIR.exists() and (CACHE_DIR.parent / "phonon-live").exists():
    (CACHE_DIR.parent / "phonon-live").rename(CACHE_DIR)
STOP, QUIT, CONTROL, CANCEL, RESTART = "stop", "quit", "control", "cancel", "restart"


class Block(NamedTuple):
    at: float
    samples: np.ndarray


class Job(NamedTuple):
    kind: str
    data: tuple


class Dictation:

    def __init__(self) -> None:
        self.number = 0
        self.context = ""
        self.index = 0
        self.phrases: list[tuple[str, str]] = []

    def start(self, context: str) -> None:
        self.number += 1
        self.context = context
        self.index = 0
        self.phrases = []

    def claim(self) -> str:
        self.index += 1
        return f"{self.number}-{self.index}"

    def before(self) -> str:
        return " ".join(piece for piece in [self.context, *(text for _, text in self.phrases)] if piece)

    def add(self, phrase: str, text: str) -> None:
        self.phrases.append((phrase, text))

    def text(self) -> str:
        return " ".join(text for _, text in self.phrases if text)

    def apply(self, edit: cleanup_model.Edit) -> list[tuple[str, str]]:
        spans, at = [], 0
        for index, (_, text) in enumerate(self.phrases):
            if not text:
                continue
            if spans:
                at += 1
            spans.append((index, at, at + len(text)))
            at += len(text)
        start, end = edit.at, edit.at + len(edit.find)
        hit = [span for span in spans if span[1] < end and start < span[2]]
        if not hit:
            return []
        (first, first_at, _), (last, last_at, _) = hit[0], hit[-1]
        joined = (self.phrases[first][1][:max(0, start - first_at)] + edit.replace
                  + self.phrases[last][1][max(0, end - last_at):])
        joined = re.sub(r"\s+([,.;:?!])", r"\1", " ".join(joined.split()))
        changed = [(first, joined)] + [(index, "") for index, _, _ in hit[1:]]
        for index, text in changed:
            self.phrases[index] = (self.phrases[index][0], text)
        return [(self.phrases[index][0], text) for index, text in changed]

    def drop(self) -> None:
        self.phrases = []


class TimedSpeech:

    def __init__(self, speech):
        self.speech = speech
        self.decode_ms = 0.0
        self.audio_s = 0.0

    def transcribe_array(self, audio):
        start = time.perf_counter()
        result = self.speech.transcribe_array(audio)
        self.decode_ms = (time.perf_counter() - start) * 1000
        self.audio_s = len(audio) / seg.SAMPLE_RATE
        return result

    @property
    def ready(self) -> bool:
        return self.speech is not None


def shared_words(a: list[str], b: list[str]) -> int:
    return next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))


class StablePrefix:

    def __init__(self, hold_s: float):
        self.hold_s = hold_s
        self.reset()

    def reset(self) -> None:
        self.history: list[tuple[float, list[str]]] = []
        self.typed: list[str] = []

    def update(self, text: str, at_s: float) -> str | None:
        words = text.split()
        self.history.append((at_s, words))
        settled = [i for i, (t, _) in enumerate(self.history) if t <= at_s - self.hold_s]
        if not settled:
            return None
        self.history = self.history[settled[-1]:]
        agreed = max(len(words) - 1, 0)
        for _, older in self.history:
            agreed = min(agreed, shared_words(older, words))
        target = words[:agreed]
        if len(target) >= len(self.typed) and target != self.typed:
            self.typed = target
            return " ".join(target)
        return None


class Events:

    def __init__(self):
        self.lock = threading.Lock()

    def send(self, event: dict) -> None:
        with self.lock:
            try:
                print(json.dumps(event), flush=True)
            except BrokenPipeError:
                os._exit(0)


class Work:

    def __init__(self, events: Events):
        self.events = events
        self.pending = False
        self.lock = threading.Lock()

    def set(self, pending: bool) -> None:
        with self.lock:
            if pending != self.pending:
                self.pending = pending
                self.events.send({"kind": "work", "pending": pending})

    def done(self) -> None:
        with self.lock:
            self.pending = False
            self.events.send({"kind": "work", "pending": False})


class ModelSlot:

    def __init__(self, kind: str, events: Events, control: queue.Queue, audio: queue.Queue):
        self.kind, self.events, self.control, self.audio = kind, events, control, audio
        self.want: str | None = None
        self.key: str | None = None
        self.suspended = False
        self.model = None

    def say(self, state: str, key: str | None, **extra) -> None:
        self.events.send({"kind": self.kind, "state": state, "model": self.model_id(key), **extra})

    def model_id(self, key: str | None) -> str | None:
        if self.kind == "cleanup":
            return key
        return asr.MODELS.get(key) if key else None

    def remote(self, key: str | None) -> bool:
        return self.kind == "cleanup" and cleanup_model.provider(key) is not None

    def _hand_over(self) -> None:
        self.control.put(self)
        self.audio.put(CONTROL)

    def request(self, key: str | None) -> None:
        self.want = key
        if key is None:
            self.say("off", None)
            self._hand_over()
            return
        if self.kind == "cleanup":
            if not self.remote(key):
                self.say("error", key, message="cleanup runs at a provider: use groq:MODEL or openrouter:MODEL")
                self.want = self.key
                return
            if message := cleanup_model.missing_key(key):
                self.say("error", key, message=message)
                self.want = self.key
            self._hand_over()
            return

        def fetch() -> None:
            try:
                report = _throttled(lambda fraction: self.say("downloading", key, progress=fraction))
                asr.ensure(key, report)
            except Exception as exc:
                self.say("error", key, message=str(exc))
                self.want = self.key
                self._hand_over()
                return
            self._hand_over()
        threading.Thread(target=fetch, daemon=True).start()

    def suspend(self) -> None:
        self.suspended = True
        self._hand_over()

    def resume(self) -> None:
        self.suspended = False
        self._hand_over()

    @property
    def target(self) -> str | None:
        return self.want if self.remote(self.want) else (None if self.suspended else self.want)

    def changing(self) -> bool:
        return self.target != self.key

    def notify(self, state: str, message: str = "") -> None:
        self.say(state, self.key, **({"message": message} if message else {}))

    def apply(self) -> bool:
        key = self.target
        if key == self.key:
            return False
        if isinstance(self.model, cleanup_model.Remote):
            self.model.close()
        self.model, self.key = None, None
        gc.collect()
        mx.clear_cache()
        if key is None:
            if self.suspended and self.want:
                self.say("unloaded", self.want)
            return True
        if self.remote(key):
            self.model = cleanup_model.Remote(key, self.notify)
            self.key = key
            self.say("ready", key)
            return True
        self.say("loading", key)
        try:
            self.model = asr.load(key, CACHE_DIR)
        except Exception as exc:
            self.say("error", key, message=str(exc))
            self.want = None
            return True
        self.key = key
        self.say("ready", key)
        return True


def _throttled(report, every: float = 0.25):
    last = [0.0]

    def send(fraction: float) -> None:
        now = time.monotonic()
        if fraction >= 1.0 or now - last[0] >= every:
            last[0] = now
            report(fraction)
    return send


_IOKIT = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
_CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_IOKIT.IOServiceMatching.restype = ctypes.c_void_p
_IOKIT.IOServiceMatching.argtypes = [ctypes.c_char_p]
_IOKIT.IOServiceGetMatchingService.restype = ctypes.c_uint32
_IOKIT.IOServiceGetMatchingService.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
_IOKIT.IORegistryEntryCreateCFProperty.restype = ctypes.c_void_p
_IOKIT.IORegistryEntryCreateCFProperty.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32]
_IOKIT.IOObjectRelease.argtypes = [ctypes.c_uint32]
_CF.CFStringCreateWithCString.restype = ctypes.c_void_p
_CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
_CF.CFBooleanGetValue.restype = ctypes.c_bool
_CF.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
_CF.CFRelease.argtypes = [ctypes.c_void_p]
_CLAMSHELL = _CF.CFStringCreateWithCString(None, b"AppleClamshellState", 0x08000100)


def lid_closed() -> bool:
    root = _IOKIT.IOServiceGetMatchingService(0, _IOKIT.IOServiceMatching(b"IOPMrootDomain"))
    if not root:
        return False
    value = _IOKIT.IORegistryEntryCreateCFProperty(root, _CLAMSHELL, None, 0)
    _IOKIT.IOObjectRelease(root)
    if not value:
        return False
    closed = _CF.CFBooleanGetValue(value)
    _CF.CFRelease(value)
    return closed


class NoMicrophone(RuntimeError):
    pass


class Recorder:

    def __init__(self, wav: str | None, audio: queue.Queue, events: Events, on_stop=None, on_cancel=None):
        self.wav, self.audio, self.events = wav, audio, events
        self.on_stop = on_stop or (lambda: None)
        self.on_cancel = on_cancel or (lambda: None)
        self.lock = threading.Lock()
        self.close_source = None
        self.stuck = False
        self.take = 0
        self.heard = False
        self.microphone = ""

    def start(self) -> None:
        with self.lock:
            if self.close_source:
                return
            try:
                if self.stuck:
                    raise RuntimeError("the microphone is stuck; the engine is restarting")
                self.close_source = self._open_file() if self.wav else self._open_microphone()
            except Exception as exc:
                print(f"could not start recording: {exc}", file=sys.stderr, flush=True)
                self.events.send({"kind": "notice",
                                  "text": str(exc) if isinstance(exc, NoMicrophone) else "Microphone failed to start"})
                self.events.send({"kind": "state", "recording": False})
                self.events.send({"kind": "work", "pending": False})
                return
            self.take += 1
            self.heard = False
            threading.Timer(SILENT_AFTER_S, self._check_heard, args=(self.take,)).start()
        print(f"recording from {self.microphone}" if self.microphone else "recording", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": True})

    def stop(self) -> None:
        with self.lock:
            if not self.close_source:
                return
            self._close()
            self.audio.put(STOP)
            if self.stuck:
                self.audio.put(RESTART)
        print("stopped", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": False})
        self.on_stop()

    def cancel(self) -> None:
        with self.lock:
            if not self.close_source:
                return
            self.on_cancel()
            self._close()
            markers = []
            while True:
                try:
                    item = self.audio.get_nowait()
                except queue.Empty:
                    break
                if not isinstance(item, Block):
                    markers.append(item)
            for item in markers:
                self.audio.put(item)
            self.audio.put(CANCEL)
            if self.stuck:
                self.audio.put(RESTART)
        print("cancelled", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": False})

    def _close(self) -> None:
        closing = threading.Thread(target=self.close_source, daemon=True)
        closing.start()
        closing.join(STOP_WAIT_S)
        self.close_source = None
        if closing.is_alive():
            self.stuck = True
            print("the microphone did not close: the engine restarts after this recording", file=sys.stderr, flush=True)

    def _check_heard(self, take: int) -> None:
        with self.lock:
            if not self.close_source or take != self.take or self.heard:
                return
        print(f"no sound from {self.microphone}", file=sys.stderr, flush=True)
        self.events.send({"kind": "notice", "text": f"No sound from {self.microphone}"})

    def _capture(self, block: np.ndarray) -> None:
        if not self.heard and np.any(block):
            self.heard = True
        self.audio.put(Block(time.time() - block.size / seg.SAMPLE_RATE, block))
        rms = float(np.sqrt(np.mean(block * block))) + 1e-9
        self.events.send({"kind": "level", "value": round(min(max((20 * math.log10(rms) + 60) / 50, 0.0), 1.0), 3)})

    def _open_microphone(self):
        sd._terminate()
        sd._initialize()
        devices = sd.query_devices()
        built_in = next((i for i, d in enumerate(devices) if d["max_input_channels"] > 0
                         and d["name"].startswith("MacBook") and "Microphone" in d["name"]), None)
        device = built_in
        if built_in is None or lid_closed():
            device = sd.default.device[0]
            if device is None or device < 0 or device == built_in:
                raise NoMicrophone("Lid closed and no other microphone connected" if built_in is not None
                                   else "No microphone connected")
        self.microphone = devices[device]["name"]
        stream = sd.InputStream(device=device, samplerate=seg.SAMPLE_RATE, channels=1, dtype="float32",
                                blocksize=BLOCK, callback=lambda indata, *_: self._capture(indata[:, 0].copy()))
        stream.start()

        def close() -> None:
            stream.stop()
            stream.close()
        return close

    def _open_file(self):
        audio = read_audio(self.wav)
        closed = threading.Event()

        def play() -> None:
            started = time.monotonic()
            for i in range(0, len(audio), BLOCK):
                if closed.is_set():
                    return
                self._capture(audio[i:i + BLOCK])
                time.sleep(max(0.0, started + (i + BLOCK) / seg.SAMPLE_RATE - time.monotonic()))
            self.stop()
        threading.Thread(target=play, daemon=True).start()
        return closed.set


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--wav", help="on start, play this file at real time instead of opening the microphone")
    parser.add_argument("--asr", choices=sorted(asr.MODELS), default="phonon-2", help="the speech model to load")
    args = parser.parse_args()
    faulthandler.enable()

    events = Events()
    audio: queue.Queue = queue.Queue()
    control: queue.Queue = queue.Queue()
    work = Work(events)
    working = threading.Event()
    taken = [time.monotonic()]
    discarding = threading.Event()
    session: seg.Segmenter | None = None

    def stopped() -> None:
        work.set(audio.qsize() > 1 or working.is_set() or bool(session and session.open))

    recorder = Recorder(args.wav, audio, events, stopped, discarding.set)
    archive = archive_module.Archive(events)
    speech_slot = ModelSlot("asr", events, control, audio)
    cleanup_slot = ModelSlot("cleanup", events, control, audio)
    stable = StablePrefix(TYPE_HOLD_S)
    dictation = Dictation()
    bench = cleanup_model.Bench(
        lambda phrase, results: events.send({"kind": "benchmark", "phrase": phrase, "results": results}))
    polishing = True
    benchmarking = False
    context = ""
    failure = {"mode": "raw", "retries": 0, "folder": None}
    compare: list[str] = []

    def watch_for_stalls() -> None:
        reported = None
        while True:
            time.sleep(5)
            held = taken[0]
            if working.is_set() and time.monotonic() - held > STALL_S and reported != held:
                reported = held
                print(f"stalled: one item in hand for {time.monotonic() - held:.0f} s", file=sys.stderr, flush=True)
                faulthandler.dump_traceback(file=sys.stderr, all_threads=True)
                events.send({"kind": "stalled"})

    threading.Thread(target=watch_for_stalls, daemon=True).start()

    def resume() -> None:
        if speech_slot.suspended:
            speech_slot.resume()

    def read_commands() -> None:
        nonlocal polishing, benchmarking, context

        def comparing() -> None:
            bench.configure(cleanup_slot.want if benchmarking else None, compare)

        for line in sys.stdin:
            command, _, argument = line.strip().partition(" ")
            if command == "compare":
                compare[:] = [model for model in argument.split(",") if model]
                comparing()
                continue
            if command == "start":
                resume()
                audio.put(Job("start", (context,)))
                context = ""
                recorder.start()
            elif command == "stop":
                recorder.stop()
            elif command == "cancel":
                recorder.cancel()
            elif command == "hold":
                stable.hold_s = min(max(float(argument), 0.2), 3.0)
            elif command == "cleanup":
                cleanup_slot.request(None if argument == "off" else argument)
                comparing()
            elif command == "polish":
                polishing = argument != "off"
            elif command == "rules":
                cleanup_model.set_rules([name for name in argument.split(",") if name])
            elif command == "failure":
                mode, _, rest = argument.partition(" ")
                retries, _, folder = rest.partition(" ")
                failure.update(mode=mode if mode in ("raw", "notify", "retry") else "raw",
                               retries=int(retries) if retries.isdigit() else 0,
                               folder=Path(folder).expanduser() if folder else None)
            elif command == "corrections":
                numbers = argument.split()
                cleanup_model.set_corrections(int(numbers[0]) if numbers and numbers[0].isdigit() else None,
                                              int(numbers[1]) if len(numbers) > 1 and numbers[1].isdigit() else 2)
            elif command == "benchmark":
                benchmarking = argument == "on"
                comparing()
            elif command == "asr" and argument in asr.MODELS:
                resume()
                speech_slot.request(argument)
            elif command == "unload":
                recorder.stop()
                speech_slot.suspend()
            elif command in ("instructions", "context", "rewrite"):
                payload = argument
                identifier = ""
                if command == "rewrite":
                    identifier, _, payload = argument.partition(" ")
                try:
                    text = json.loads(payload)
                    if not isinstance(text, str):
                        raise ValueError("not a string")
                except Exception as exc:
                    cleanup_slot.say("error", cleanup_slot.key, message=f"{command}: {exc}")
                else:
                    if command == "instructions":
                        cleanup_model.set_instructions(text)
                    elif command == "context":
                        context = text
                    else:
                        audio.put(Job("rewrite", (identifier, text)))
            elif command == "archive":
                mode, _, rest = argument.partition(" ")
                seconds, _, directory = rest.partition(" ")
                archive.configure(Path(directory).expanduser() if mode == "on" else None,
                                  float(seconds or 0))

    def commands_then_quit() -> None:
        try:
            read_commands()
        finally:
            recorder.stop()
            audio.put(QUIT)

    threading.Thread(target=commands_then_quit, daemon=True).start()
    events.send({"kind": "state", "recording": False})

    started = time.perf_counter()
    mx.set_cache_limit(256 << 20)
    vad = seg.Vad(seg.ensure_vad(CACHE_DIR))
    speech_slot.request(args.asr)
    deferred = []
    while speech_slot.key != speech_slot.want:
        slot = control.get()
        if slot is speech_slot:
            slot.apply()
        else:
            deferred.append(slot)
    if speech_slot.model is None:
        return
    speech = TimedSpeech(speech_slot.model)
    asr.warm_up(speech)
    print(f"ready in {time.perf_counter() - started:.1f} s", file=sys.stderr, flush=True)
    events.send({"kind": "ready", "cues": cleanup_model.CUES, "starting_cues": cleanup_model.STARTING_CUES})
    for slot in deferred:
        slot.apply()

    def send(event: dict) -> None:
        events.send(event)
        print(f"{event['kind']:7} {speech.decode_ms:4.0f} ms for {speech.audio_s:4.1f} s  {event['text']}",
              file=sys.stderr, flush=True)

    def on_partial(text: str) -> None:
        if discarding.is_set():
            return
        send({"kind": "partial", "text": text})
        if cleanup_slot.model is None and (typed := stable.update(text, speech.audio_s)):
            send({"kind": "type", "text": typed, "final": False})

    def save_failed(audio: np.ndarray) -> list[dict]:
        if failure["folder"] is None:
            return []
        path = failure["folder"] / "Failed" / time.strftime("%Y-%m-%d") / time.strftime("%H-%M-%S.wav")
        path.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(path), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(seg.SAMPLE_RATE)
            out.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
        return [{"file": str(path), "start_s": 0.0, "end_s": round(len(audio) / seg.SAMPLE_RATE, 2)}]

    def on_final(text: str, timing: seg.Timing, audio: np.ndarray) -> None:
        if discarding.is_set():
            return
        heard = archive.locate(timing.started, timing.started + timing.speech_s)
        phrase = dictation.claim()
        before = dictation.before()
        final = {"kind": "final", "text": text}
        cleanup = None
        if cleaner := cleanup_slot.model:
            at = time.perf_counter()
            edited = None
            retries = failure["retries"] if failure["mode"] == "retry" else 0
            if cleanup_model.corrections() and dictation.text() and cleanup_model.may_correct(text):
                rewritten, stats, edit = cleaner.correct(text, before, dictation.text(), retries)
                if edit and (changed := dictation.apply(edit)):
                    edited = {"phrases": [{"id": id, "text": new} for id, new in changed], "text": dictation.text()}
            else:
                rewritten, stats = cleaner.rewrite(text, before, retries)
            ms = (time.perf_counter() - at) * 1000
            cleanup = stats._replace(ms=round(ms))._asdict()
            final = {"kind": "final", "text": rewritten, "raw": text,
                     "cleanup_ms": 0.0 if stats.skipped else round(ms, 1)}
            if stats.failed and failure["mode"] != "raw":
                final["text"] = ""
                final["failed"] = stats.error
                heard = heard or save_failed(audio)
            if edited:
                final["edit"] = edited
            print(f"cleanup {ms:5.0f} ms  {cleaner.note}", file=sys.stderr, flush=True)
        final["id"] = phrase
        final["session"] = dictation.number
        final["timing"] = {"speech_ms": round(timing.speech_s * 1000),
                           "endpoint_ms": round((timing.closed - timing.last_speech) * 1000),
                           "queue_ms": round((timing.decode_at - timing.closed) * 1000),
                           "decode_ms": round((timing.decoded - timing.decode_at) * 1000),
                           "cleanup": cleanup,
                           "total_ms": round((time.time() - timing.last_speech) * 1000)}
        if heard:
            final["audio"] = heard
        send(final)
        send({"kind": "type", "text": final["text"], "final": True})
        stable.reset()
        dictation.add(phrase, final["text"])
        if cleanup is not None and not cleanup["skipped"] and not cleanup["failed"]:
            bench.submit(phrase, text, before)

    def whole(text: str) -> tuple[str, dict | None]:
        cleaner = cleanup_slot.model
        if cleaner is None:
            return text, None
        at = time.perf_counter()
        written, stats = cleaner.whole(text)
        ms = (time.perf_counter() - at) * 1000
        print(f"whole   {ms:5.0f} ms  {len(text)} chars", file=sys.stderr, flush=True)
        return written, stats._replace(ms=round(ms))._asdict()

    def finish_dictation() -> None:
        if not dictation.phrases:
            return
        said = dictation.text()
        text, cost = (whole(said) if polishing else (said, None))
        events.send({"kind": "session", "session": dictation.number, "text": text, "heard": said,
                     "phrases": [phrase for phrase, _ in dictation.phrases],
                     "polished": bool(cost) and not cost["error"], "timing": cost})
        dictation.drop()

    session = seg.Segmenter(speech, vad, on_partial=on_partial, on_final=on_final, on_frame=archive.feed)
    stopped_unheard = False
    try:
        while True:
            working.clear()
            block = audio.get()
            taken[0] = time.monotonic()
            working.set()
            if block is QUIT:
                break
            if block is CONTROL:
                while True:
                    try:
                        slot = control.get_nowait()
                    except queue.Empty:
                        break
                    if slot is speech_slot and slot.changing():
                        session.finish()
                        stable.reset()
                    if slot.apply() and slot is speech_slot:
                        speech.speech = slot.model
                        gc.collect()
                        mx.clear_cache()
                        if slot.model is not None:
                            asr.warm_up(speech)
                            session.drain()
                            if stopped_unheard:
                                stopped_unheard = False
                                finish_dictation()
                                with audio.mutex:
                                    another = any(item is STOP for item in audio.queue)
                                if not another:
                                    work.done()
            elif block is STOP:
                session.finish()
                archive.flush()
                if stable.typed:
                    send({"kind": "type", "text": " ".join(stable.typed), "final": True})
                    stable.reset()
                if session.held:
                    stopped_unheard = True
                    work.set(True)
                else:
                    finish_dictation()
                    work.done()
            elif block is RESTART:
                archive.close()
                events.send({"kind": "restart"})
                os._exit(0)
            elif block is CANCEL:
                session.discard()
                archive.discard()
                stable.reset()
                dictation.drop()
                work.done()
                discarding.clear()
            elif isinstance(block, Job):
                if block.kind == "start":
                    dictation.start(block.data[0])
                else:
                    identifier, text = block.data
                    written, cost = whole(text)
                    events.send({"kind": "rewritten", "id": identifier, "text": written, "timing": cost})
            else:
                session.feed(block.samples, block.at)
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    archive.close()
    os._exit(0)


if __name__ == "__main__":
    main()

