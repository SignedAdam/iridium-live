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
"""The Iridium Live engine: it listens, transcribes, cleans up and reports.

Commands arrive as lines on stdin:
    start | stop | cancel        one recording (a take) from the microphone
    takes keep|drop FOLDER       where takes are written and whether their audio is kept
    retake ID "FILE"             transcribe a saved take again under that history id
    asr NAME | unload            load or release the speech model
    cleanup off|PROVIDER:MODEL, polish on|off, rules, corrections, benchmark, compare, failure
    hold SECONDS, instructions "TEXT", context "TEXT", rewrite ID "TEXT"

Events leave as one JSON object per line on stdout:
    state, level, partial, final, type, session, rewritten, benchmark, work, notice, ready, stalled, restart
    asr | cleanup                model state: loading, downloading, ready, error, unloaded, off
    take                         one recording: recording, captured, done, empty, failed, discarded
Every final and session event carries the take it came from; `late` marks text that arrives after
its recording stopped, which the app must not type into whatever is in front now.
"""
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
from pathlib import Path
from typing import NamedTuple

os.environ.setdefault("USE_TORCH", "0")

import mlx.core as mx
import numpy as np
import sounddevice as sd
from fermion._speech.engine import read_audio

import asr
import cleanup as cleanup_model
import segmenter as seg
import takes as takes_module

TYPE_HOLD_S = 0.7
STALL_S = 90.0
LOAD_TIMEOUT_S = 75.0
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
    """What one recording said, with the context it was spoken into."""

    def __init__(self, number: int, context: str = "") -> None:
        self.number = number
        self.context = context
        self.index = 0
        self.phrases: list[tuple[str, str]] = []

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
    """One model the engine may hold. Speech models load on their own thread: the main loop never waits."""

    def __init__(self, kind: str, events: Events, control: queue.Queue, audio: queue.Queue):
        self.kind, self.events, self.control, self.audio = kind, events, control, audio
        self.want: str | None = None
        self.key: str | None = None
        self.suspended = False
        self.model = None
        self.loading: str | None = None
        self.results: queue.Queue = queue.Queue()
        self.returned: set[str] = set()
        self.failure: str | None = None
        self.wedged = False

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
        if self.wedged:
            self.audio.put(RESTART)
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
        """Install what a loader produced, or start loading what is wanted. Never waits for a model."""
        changed = self._collect()
        key = self.target
        if key == self.key or key == self.loading:
            return changed
        if isinstance(self.model, cleanup_model.Remote):
            self.model.close()
        if self.model is not None:
            self.model = None
            gc.collect()
            mx.clear_cache()
            changed = True
        self.key = None
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
        self.loading, self.failure = key, None
        threading.Thread(target=self._load, args=(key,), daemon=True).start()
        threading.Timer(LOAD_TIMEOUT_S, self._too_slow, args=(key,)).start()
        return changed

    def _collect(self) -> bool:
        changed = False
        while True:
            try:
                state, key, payload = self.results.get_nowait()
            except queue.Empty:
                return changed
            if key == self.loading:
                self.loading = None
            if state == "ready" and key == self.target:
                self.model, self.key = payload, key
                self.say("ready", key)
                changed = True
            elif state == "ready":
                del payload
                gc.collect()
                mx.clear_cache()
            elif key == self.want:
                self.failure = payload
                self.say("error", key, message=payload)
                self.want = self.key
                changed = True

    def _load(self, key: str) -> None:
        try:
            model = asr.load(key, CACHE_DIR)
            asr.warm_up(TimedSpeech(model))
        except Exception as exc:
            self.returned.add(key)
            self.results.put(("failed", key, str(exc)))
        else:
            self.returned.add(key)
            self.results.put(("ready", key, model))
        self._hand_over()

    def _too_slow(self, key: str) -> None:
        """A load that outlives the watchdog becomes a visible failure; its thread may never come back."""
        if self.loading != key or key in self.returned:
            return
        self.wedged = True
        self.results.put(("failed", key, "the speech model did not load"))
        self._hand_over()


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
    """Opens the microphone and feeds every block to the take on disk and to the engine."""

    def __init__(self, wav: str | None, audio: queue.Queue, events: Events, takes: takes_module.Takes,
                 on_stop=None, on_cancel=None):
        self.wav, self.audio, self.events, self.takes = wav, audio, events, takes
        self.on_stop = on_stop or (lambda: None)
        self.on_cancel = on_cancel or (lambda: None)
        self.lock = threading.Lock()
        self.close_source = None
        self.stuck = False
        self.number = 0
        self.take: str | None = None
        self.heard = False
        self.microphone = ""
        self.devices = None

    @property
    def recording(self) -> bool:
        return self.close_source is not None

    def prepare(self) -> None:
        """Re-open CoreAudio before it is needed: doing it when the hotkey arrives costs the first words."""
        with self.lock:
            if self.close_source or self.wav:
                return
            try:
                sd._terminate()
                sd._initialize()
                self.devices = sd.query_devices()
            except Exception as exc:
                self.devices = None
                print(f"could not prepare the microphone: {exc}", file=sys.stderr, flush=True)

    def start(self, context: str) -> None:
        with self.lock:
            if self.close_source:
                return
            take = self.takes.begin(time.time())
            self.take = take
            self.audio.put(Job("start", (context, take)))
            try:
                if self.stuck:
                    raise RuntimeError("the microphone is stuck; the engine is restarting")
                self.close_source = self._open_file() if self.wav else self._open_microphone()
            except Exception as exc:
                self.take = None
                self.takes.resolve(take, takes_module.FAILED,
                                   str(exc) if isinstance(exc, NoMicrophone) else "The microphone did not start")
                self.audio.put(CANCEL)
                print(f"could not start recording: {exc}", file=sys.stderr, flush=True)
                self.events.send({"kind": "notice",
                                  "text": str(exc) if isinstance(exc, NoMicrophone) else "Microphone failed to start"})
                self.events.send({"kind": "state", "recording": False})
                self.events.send({"kind": "work", "pending": False})
                return
            self.number += 1
            self.heard = False
            threading.Timer(SILENT_AFTER_S, self._check_heard, args=(self.number,)).start()
        print(f"recording from {self.microphone}" if self.microphone else "recording", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": True})

    def stop(self) -> None:
        with self.lock:
            if not self.close_source:
                return
            self._close()
            self.takes.end()
            self.audio.put(STOP)
            if self.stuck:
                self.audio.put(RESTART)
        print("stopped", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": False})
        self.on_stop()
        threading.Thread(target=self.prepare, daemon=True).start()

    def cancel(self) -> None:
        with self.lock:
            if not self.close_source:
                return
            self.on_cancel()
            self._close()
            self.take = None
            self.takes.discard()
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
        threading.Thread(target=self.prepare, daemon=True).start()

    def _close(self) -> None:
        closing = threading.Thread(target=self.close_source, daemon=True)
        closing.start()
        closing.join(STOP_WAIT_S)
        self.close_source = None
        if closing.is_alive():
            self.stuck = True
            print("the microphone did not close: the engine restarts after this recording", file=sys.stderr, flush=True)

    def _check_heard(self, number: int) -> None:
        with self.lock:
            if not self.close_source or number != self.number or self.heard:
                return
        print(f"no sound from {self.microphone}", file=sys.stderr, flush=True)
        self.events.send({"kind": "notice", "text": f"No sound from {self.microphone}"})

    def _capture(self, block: np.ndarray) -> None:
        if not self.heard and np.any(block):
            self.heard = True
        self.takes.feed(block)
        self.audio.put(Block(time.time() - block.size / seg.SAMPLE_RATE, block))
        rms = float(np.sqrt(np.mean(block * block))) + 1e-9
        self.events.send({"kind": "level", "value": round(min(max((20 * math.log10(rms) + 60) / 50, 0.0), 1.0), 3)})

    def _open_microphone(self):
        devices = self.devices
        if devices is None:
            sd._terminate()
            sd._initialize()
            devices = sd.query_devices()
        self.devices = None
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
    parser.add_argument("--takes", help="write recordings to this folder before the app says where they belong")
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

    takes = takes_module.Takes(events)
    if args.takes:
        takes.configure(Path(args.takes).expanduser(), True)
    recorder = Recorder(args.wav, audio, events, takes, stopped, discarding.set)
    speech_slot = ModelSlot("asr", events, control, audio)
    cleanup_slot = ModelSlot("cleanup", events, control, audio)
    speech = TimedSpeech(None)
    stable = StablePrefix(TYPE_HOLD_S)
    dictations: dict[str, Dictation] = {}
    open_takes: list[str] = []
    numbers = [0]
    bench = cleanup_model.Bench(
        lambda phrase, results: events.send({"kind": "benchmark", "phrase": phrase, "results": results}))
    polishing = True
    benchmarking = False
    context = ""
    failure = {"mode": "raw", "retries": 0}
    compare: list[str] = []
    detector = [None]
    no_detector = [False]
    announced = [False]
    replay = {"file": "", "at": 0.0}
    catching_up = [False]
    queued_retakes: list[tuple[str, str]] = []

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
                recorder.start(context)
                context = ""
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
                mode, _, retries = argument.partition(" ")
                failure.update(mode=mode if mode in ("raw", "notify", "retry") else "raw",
                               retries=int(retries) if retries.isdigit() else 0)
            elif command == "corrections":
                numbers_said = argument.split()
                cleanup_model.set_corrections(int(numbers_said[0]) if numbers_said and numbers_said[0].isdigit() else None,
                                              int(numbers_said[1]) if len(numbers_said) > 1 and numbers_said[1].isdigit() else 2)
            elif command == "benchmark":
                benchmarking = argument == "on"
                comparing()
            elif command == "asr" and argument in asr.MODELS:
                resume()
                speech_slot.request(argument)
            elif command == "unload":
                recorder.stop()
                speech_slot.suspend()
            elif command in ("instructions", "context", "rewrite", "retake"):
                payload = argument
                identifier = ""
                if command in ("rewrite", "retake"):
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
                    elif command == "rewrite":
                        audio.put(Job("rewrite", (identifier, text)))
                    else:
                        resume()
                        audio.put(Job("retake", (identifier, text)))
            elif command == "takes":
                mode, _, directory = argument.partition(" ")
                takes.configure(Path(directory).expanduser(), mode == "keep")

    def commands_then_quit() -> None:
        try:
            read_commands()
        finally:
            recorder.stop()
            audio.put(QUIT)

    threading.Thread(target=commands_then_quit, daemon=True).start()
    events.send({"kind": "state", "recording": False})
    threading.Thread(target=recorder.prepare, daemon=True).start()

    started = time.perf_counter()
    mx.set_cache_limit(256 << 20)

    def find_voices() -> None:
        """The voice detector is a download on a first run: the main loop must not wait for it."""
        try:
            detector[0] = seg.Vad(seg.ensure_vad(CACHE_DIR))
        except Exception as exc:
            no_detector[0] = True
            print(f"the voice detector did not load: {exc}", file=sys.stderr, flush=True)
        audio.put(CONTROL)

    threading.Thread(target=find_voices, daemon=True).start()
    speech_slot.request(args.asr)

    def send(event: dict) -> None:
        events.send(event)
        print(f"{event['kind']:7} {speech.decode_ms:4.0f} ms for {speech.audio_s:4.1f} s  {event['text']}",
              file=sys.stderr, flush=True)

    def numbered() -> int:
        numbers[0] += 1
        return numbers[0]

    def on_partial(text: str) -> None:
        if discarding.is_set():
            return
        send({"kind": "partial", "text": text})
        if cleanup_slot.model is None and not catching_up[0] and (typed := stable.update(text, speech.audio_s)):
            send({"kind": "type", "text": typed, "final": False})

    def on_final(text: str, timing: seg.Timing, samples: np.ndarray, take: str) -> None:
        if discarding.is_set():
            return
        dictation = dictations.get(take)
        if dictation is None:
            dictation = dictations[take] = Dictation(numbered())
        late = catching_up[0]
        if replay["file"]:
            heard = [{"file": replay["file"], "start_s": round(timing.started - replay["at"], 3),
                      "end_s": round(timing.started - replay["at"] + timing.speech_s, 3)}]
        else:
            heard = takes.locate(timing.started, timing.started + timing.speech_s)
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
                    cleaner.trace["edit"]["phrases"] = edited["phrases"]
            else:
                rewritten, stats = cleaner.rewrite(text, before, retries)
            ms = (time.perf_counter() - at) * 1000
            cleanup = stats._replace(ms=round(ms))._asdict()
            final = {"kind": "final", "text": rewritten, "raw": text,
                     "cleanup_ms": 0.0 if stats.skipped else round(ms, 1),
                     "correction": dict(cleaner.trace, ms=round(ms))}
            if stats.failed and failure["mode"] != "raw":
                final["text"] = ""
                final["failed"] = stats.error
                takes.hold(take)
            if edited:
                final["edit"] = edited
            print(f"cleanup {ms:5.0f} ms  {cleaner.note}", file=sys.stderr, flush=True)
        final["id"] = phrase
        final["session"] = dictation.number
        final["take"] = take
        if late:
            final["late"] = True
        final["timing"] = {"speech_ms": round(timing.speech_s * 1000),
                           "endpoint_ms": round((timing.closed - timing.last_speech) * 1000),
                           "queue_ms": round((timing.decode_at - timing.closed) * 1000),
                           "decode_ms": round((timing.decoded - timing.decode_at) * 1000),
                           "cleanup": cleanup,
                           "total_ms": round((time.time() - timing.last_speech) * 1000)}
        if heard:
            final["audio"] = heard
        send(final)
        if not late:
            send({"kind": "type", "text": final["text"], "final": True})
        stable.reset()
        dictation.add(phrase, final["text"])
        if cleanup is not None and not cleanup["skipped"] and not cleanup["failed"]:
            bench.submit(phrase, text, before)

    def whole(text: str) -> tuple[str, dict | None, dict | None]:
        cleaner = cleanup_slot.model
        if cleaner is None:
            return text, None, None
        at = time.perf_counter()
        written, stats = cleaner.whole(text)
        ms = (time.perf_counter() - at) * 1000
        print(f"whole   {ms:5.0f} ms  {len(text)} chars", file=sys.stderr, flush=True)
        return written, stats._replace(ms=round(ms))._asdict(), dict(cleaner.trace, ms=round(ms))

    def finish_dictation(take: str, late: bool) -> bool:
        """Polish what a take said and report it. False when the take said nothing."""
        dictation = dictations.pop(take, None)
        if dictation is None or not dictation.phrases:
            return False
        said = dictation.text()
        text, cost, trace = (whole(said) if polishing else (said, None, None))
        events.send({"kind": "session", "session": dictation.number, "take": take, "text": text, "heard": said,
                     "phrases": [phrase for phrase, _ in dictation.phrases], "late": late,
                     "polished": bool(cost) and not cost["error"], "timing": cost, "correction": trace})
        return True

    def close_take(take: str, state: str, reason: str = "") -> None:
        dictations.pop(take, None)
        if take in open_takes:
            open_takes.remove(take)
        takes.resolve(take, state, reason)

    def deliver(take: str) -> None:
        """Everything this take said is decoded: polish it, report it and release its audio."""
        said = finish_dictation(take, take != recorder.take or not recorder.recording)
        close_take(take, takes_module.DONE if said else takes_module.EMPTY)

    def fail_takes(reason: str) -> None:
        for take in list(open_takes):
            if take == recorder.take and recorder.recording:
                continue
            session.forget(take)
            close_take(take, takes_module.FAILED, reason)
        stopped()

    def deliver_waiting() -> None:
        """Takes whose audio waited for a model are transcribed in the order they were spoken."""
        if session is None or not speech.ready or session.vad is None:
            return
        try:
            catching_up[0] = not recorder.recording and session.pending.size > 0
            session.catch_up()
            if not recorder.recording:
                session.finish()
            for take in session.waiting():
                catching_up[0] = take != recorder.take or not recorder.recording
                session.drain(take)
        finally:
            catching_up[0] = False
        for take in list(open_takes):
            if take == recorder.take and recorder.recording:
                continue
            deliver(take)
        stopped()

    def retake(take: str, path: str) -> None:
        """Transcribe a saved take again, under the history entry that asked for it."""
        try:
            samples = read_audio(path)
        except Exception as exc:
            events.send({"kind": "retake", "take": take, "failed": str(exc)})
            return
        base = time.time() - len(samples) / seg.SAMPLE_RATE
        replay.update(file=path, at=base)
        dictations[take] = Dictation(numbered())
        again = seg.Segmenter(speech, seg.Vad(seg.ensure_vad(CACHE_DIR)), on_final=on_final)
        again.take = take
        try:
            catching_up[0] = True
            for i in range(0, len(samples), BLOCK):
                chunk = samples[i:i + BLOCK]
                again.feed(chunk, base + (i + len(chunk)) / seg.SAMPLE_RATE)
            again.finish()
            said = finish_dictation(take, True)
        finally:
            catching_up[0] = False
            replay.update(file="", at=0.0)
        events.send({"kind": "retake", "take": take, "said": said})

    session = seg.Segmenter(speech, None, on_partial=on_partial, on_final=on_final)
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
                if session.vad is None and detector[0] is not None:
                    session.vad = detector[0]
                if not announced[0] and speech.ready and session.vad is not None:
                    announced[0] = True
                    print(f"ready in {time.perf_counter() - started:.1f} s", file=sys.stderr, flush=True)
                    events.send({"kind": "ready", "cues": cleanup_model.CUES,
                                 "starting_cues": cleanup_model.STARTING_CUES})
                if no_detector[0]:
                    fail_takes("The voice detector did not load")
                if speech_slot.failure:
                    speech_slot.failure = None
                    fail_takes("The speech model did not load")
                deliver_waiting()
                while queued_retakes and speech.ready:
                    retake(*queued_retakes.pop(0))
                    stopped()
            elif block is STOP:
                session.finish()
                if stable.typed:
                    send({"kind": "type", "text": " ".join(stable.typed), "final": True})
                    stable.reset()
                take = recorder.take
                if take is None or take not in open_takes:
                    work.done()
                elif no_detector[0]:
                    fail_takes("The voice detector did not load")
                elif speech.ready and session.vad is not None:
                    deliver_waiting()
                    work.done()
                elif speech_slot.loading or (session.vad is None and not no_detector[0]):
                    work.set(True)
                else:
                    fail_takes("The speech model did not load")
            elif block is RESTART:
                fail_takes("The engine restarted")
                takes.close()
                events.send({"kind": "restart"})
                os._exit(0)
            elif block is CANCEL:
                session.discard()
                stable.reset()
                if open_takes:
                    cancelled = open_takes[-1]
                    dictations.pop(cancelled, None)
                    open_takes.remove(cancelled)
                work.done()
                discarding.clear()
            elif isinstance(block, Job):
                if block.kind == "start":
                    spoken_into, take = block.data
                    dictations[take] = Dictation(numbered(), spoken_into)
                    open_takes.append(take)
                    session.take = take
                elif block.kind == "retake":
                    if speech.ready:
                        retake(*block.data)
                    else:
                        queued_retakes.append(block.data)
                        work.set(True)
                else:
                    identifier, text = block.data
                    written, cost, trace = whole(text)
                    events.send({"kind": "rewritten", "id": identifier, "text": written, "timing": cost,
                                 "correction": trace})
            else:
                session.feed(block.samples, block.at)
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    fail_takes("Iridium Live quit")
    takes.close()
    os._exit(0)


if __name__ == "__main__":
    main()
