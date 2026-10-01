# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "fermion-research==0.2.4",
#     "mlx==0.32.3",
#     "mlx-audio==0.5.7",
#     "mlx-lm==0.31.3",
#     "onnxruntime==1.30.0",
#     "scipy",
#     "sounddevice",
#     "soundfile",
#     "zstandard",
# ]
# ///
"""Phonon-2 (or Parakeet) on MLX, driven over stdin/stdout by the PhononLive app.

Commands on stdin, one per line. "start" opens the MacBook microphone (or plays --wav FILE at real time); "stop"
closes it and finishes the phrase in flight; "hold SECONDS" sets how long a word must read the same before it is
typed; "cleanup off|qwen3-4b|llama-3.2-3b|openrouter:MODEL|groq:MODEL" turns the rewrite model off, on locally, or
on at a provider (OPENROUTER_API_KEY or GROQ_API_KEY out of the environment; nothing is downloaded or loaded, and a
request that fails or runs long leaves the phrase raw); "asr phonon-2|parakeet" switches the speech model; "unload"
drops every model from memory (the next start brings back what was loaded; a remote cleanup model holds none, so it
keeps working); "archive on SECONDS DIRECTORY" keeps a copy of the recorded audio as WAV files cut at silences that
long, "archive off" stops.
All act at once, even while a model is still loading: audio waits and is transcribed as soon as the model is
ready, and any model that is not on disk is fetched first. Events on stdout, one JSON object per line:
  {"kind": "state", "recording": bool}             at startup and after every change
  {"kind": "asr" | "cleanup", "state": "off"|"downloading"|"loading"|"ready"|"unloaded"|"error", "model": ...,
   "progress": 0..1, "message": ...}               whenever a model's state changes ("off" is cleanup only)
  {"kind": "ready"}                                the speech model is loaded, once, at startup
  {"kind": "level", "value": 0..1}                 input level of each 50 ms block while recording
  {"kind": "partial" | "final", "text": ...}       caption: the whole in-flight phrase, replacing the previous one
                                                   (final also carries "raw" and "cleanup_ms" when cleanup is on)
  {"kind": "type", "text": ..., "final": bool}     the phrase as it should stand typed so far (the app decides
                                                   whether typing is on)
  {"kind": "archive", "file": ..., "seconds": ...} a recording was closed on disk
Decode timings go to stderr.
"""
import argparse
import gc
import json
import math
import os
import queue
import sys
import threading
import time
from pathlib import Path
from typing import NamedTuple

# mlx-audio imports every model family it ships, one of which pulls in transformers, which then imports torch: about
# 3 s of startup for a library Phonon-2 never touches. Transcripts are identical without it.
os.environ.setdefault("USE_TORCH", "0")

import mlx.core as mx
import numpy as np
import sounddevice as sd
from fermion._speech.engine import read_audio

import archive as archive_module
import asr
import cleanup as cleanup_model
import segmenter as seg

TYPE_HOLD_S = 0.7  # a word is typed once the phrase up to it has read the same for this much audio
BLOCK = int(0.05 * seg.SAMPLE_RATE)
CACHE_DIR = Path.home() / ".cache" / "phonon-live"
STOP, QUIT, CONTROL = "stop", "quit", "control"  # markers in the audio queue


class Block(NamedTuple):
    """One captured block, carrying the wall time of its first sample: the archive names files by it."""
    at: float
    samples: np.ndarray


class TimedSpeech:
    """Forwards `transcribe_array` and records how long the last decode took. `speech` is swapped on an ASR change."""

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
        """Is there a model to decode with? `unload` leaves the segmenter running without one."""
        return self.speech is not None


def shared_words(a: list[str], b: list[str]) -> int:
    """How many leading words two hypotheses agree on."""
    return next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))


class StablePrefix:
    """The part of the in-flight phrase that every partial of the last `hold_s` seconds of audio agreed on."""

    def __init__(self, hold_s: float):
        self.hold_s = hold_s
        self.reset()

    def reset(self) -> None:
        self.history: list[tuple[float, list[str]]] = []  # (phrase audio seconds, words) per partial
        self.typed: list[str] = []

    def update(self, text: str, at_s: float) -> str | None:
        """Record a partial; return the phrase as it should stand typed when that changed, else None."""
        words = text.split()
        self.history.append((at_s, words))
        settled = [i for i, (t, _) in enumerate(self.history) if t <= at_s - self.hold_s]
        if not settled:
            return None
        self.history = self.history[settled[-1]:]  # the partial showing hold_s ago, and every one since
        agreed = max(len(words) - 1, 0)  # the newest word may still be half spoken
        for _, older in self.history:
            agreed = min(agreed, shared_words(older, words))
        target = words[:agreed]
        # A settled prefix that rewrites a typed word is a correction worth applying, but only while it does not
        # take words back: a merely shorter prefix (the model hesitating) waits.
        if len(target) >= len(self.typed) and target != self.typed:
            self.typed = target
            return " ".join(target)
        return None


class Events:
    """JSON lines on stdout, one writer at a time (commands, audio capture and the transcriber all send)."""

    def __init__(self):
        self.lock = threading.Lock()

    def send(self, event: dict) -> None:
        with self.lock:
            print(json.dumps(event), flush=True)


class ModelSlot:
    """One switchable model, in two halves: the command thread decides and downloads, the transcriber thread loads.

    MLX is not safe to drive from two threads, so nothing here touches it except `apply`. A slot only reaches the
    `control` queue once its files are on disk, and the CONTROL marker in the audio queue is what wakes the
    transcriber up to look. Downloads run on their own thread, so a 600 MB fetch never stops audio from queueing.
    """

    def __init__(self, kind: str, events: Events, control: queue.Queue, audio: queue.Queue):
        self.kind, self.events, self.control, self.audio = kind, events, control, audio
        self.want: str | None = None    # what the user asked for
        self.key: str | None = None     # what is loaded
        self.suspended = False          # `unload`: dropped from memory, but still wanted
        self.model = None

    def say(self, state: str, key: str | None, **extra) -> None:
        self.events.send({"kind": self.kind, "state": state, "model": self.model_id(key), **extra})

    def model_id(self, key: str | None) -> str | None:
        if self.remote(key):
            return key  # a remote cleanup model is named by the key itself: "<provider>:<model id>"
        return (asr.MODELS if self.kind == "asr" else cleanup_model.MODELS).get(key) if key else None

    def remote(self, key: str | None) -> bool:
        """Is `key` a model that lives on someone else's machine? Nothing to download, load, or unload."""
        return self.kind == "cleanup" and cleanup_model.provider(key) is not None

    def _hand_over(self) -> None:
        self.control.put(self)
        self.audio.put(CONTROL)

    def request(self, key: str | None) -> None:
        """A command asked for `key` (None = off). Download off the calling thread, then hand the load over."""
        self.want = key
        if key is None:
            self.say("off", None)
            self._hand_over()
            return
        if self.remote(key):  # nothing to fetch and nothing to load: all it needs is a key in the environment
            if message := cleanup_model.missing_key(key):
                self.say("error", key, message=message)
                self.want = self.key
            self._hand_over()
            return

        def fetch() -> None:
            try:
                report = _throttled(lambda fraction: self.say("downloading", key, progress=fraction))
                (asr.ensure if self.kind == "asr" else cleanup_model.ensure)(key, report)
            except Exception as exc:  # a failed download must not take the engine down
                self.say("error", key, message=str(exc))
                self.want = self.key
                self._hand_over()
                return
            self._hand_over()
        threading.Thread(target=fetch, daemon=True).start()

    def suspend(self) -> None:
        """`unload`: drop the model but remember it, so the next start can bring it straight back."""
        self.suspended = True
        self._hand_over()

    def resume(self) -> None:
        self.suspended = False
        self._hand_over()

    @property
    def target(self) -> str | None:
        """What should be loaded. `unload` drops everything that holds memory, which a remote model does not:
        it keeps answering across an unload, and there is nothing to bring back afterwards."""
        return self.want if self.remote(self.want) else (None if self.suspended else self.want)

    def changing(self) -> bool:
        """Would `apply` touch the model? The transcriber asks before it lets a phrase run into a reload."""
        return self.target != self.key

    def notify(self, state: str, message: str = "") -> None:
        """A remote cleaner reporting on its own requests, from the transcriber thread."""
        self.say(state, self.key, **({"message": message} if message else {}))

    def apply(self) -> bool:
        """Transcriber thread: make the loaded model match `want`, or none of it while suspended."""
        key = self.target
        if key == self.key:
            return False
        if isinstance(self.model, cleanup_model.Remote):
            self.model.close()  # the kept connection belongs to the model that opened it
        self.model, self.key = None, None
        gc.collect()  # models hold reference cycles (compiled decode loops, tokenizer closures): free them now
        mx.clear_cache()  # and hand their buffers back before the incoming model allocates
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
            self.model = (asr.load(key, CACHE_DIR) if self.kind == "asr" else cleanup_model.Cleaner(
                cleanup_model.MODELS[key]))
        except Exception as exc:
            self.say("error", key, message=str(exc))
            self.want = None
            return True
        self.key = key
        self.say("ready", key)
        return True


def _throttled(report, every: float = 0.25):
    """At most four progress events a second, whatever the watcher offers."""
    last = [0.0]

    def send(fraction: float) -> None:
        now = time.monotonic()
        if fraction >= 1.0 or now - last[0] >= every:
            last[0] = now
            report(fraction)
    return send


class Recorder:
    """Owns the audio source. Commands act immediately on their own thread, so the microphone opens (and closes)
    even while the model is still loading; captured audio waits in `audio` for the transcriber."""

    def __init__(self, wav: str | None, audio: queue.Queue, events: Events):
        self.wav, self.audio, self.events = wav, audio, events
        self.lock = threading.Lock()
        self.close_source = None  # set while recording

    def start(self) -> None:
        with self.lock:
            if self.close_source:
                return
            try:
                self.close_source = self._open_file() if self.wav else self._open_microphone()
            except Exception as exc:  # no microphone or no permission: say why and stay stopped
                print(f"could not start recording: {exc}", file=sys.stderr, flush=True)
                self.events.send({"kind": "state", "recording": False})
                return
        print("recording", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": True})

    def stop(self) -> None:
        with self.lock:
            if not self.close_source:
                return
            self.close_source()
            self.close_source = None
            self.audio.put(STOP)  # the transcriber finishes the phrase when it gets here
        print("stopped", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": False})

    def _capture(self, block: np.ndarray) -> None:
        self.audio.put(Block(time.time() - block.size / seg.SAMPLE_RATE, block))
        rms = float(np.sqrt(np.mean(block * block))) + 1e-9
        self.events.send({"kind": "level", "value": round(min(max((20 * math.log10(rms) + 60) / 50, 0.0), 1.0), 3)})

    def _open_microphone(self):
        """The Mac's own microphone, whatever the system default input is (e.g. headphones)."""
        device = next((i for i, d in enumerate(sd.query_devices()) if d["max_input_channels"] > 0
                       and d["name"].startswith("MacBook") and "Microphone" in d["name"]), None)
        if device is None:
            raise RuntimeError("no built-in MacBook microphone found")
        stream = sd.InputStream(device=device, samplerate=seg.SAMPLE_RATE, channels=1, dtype="float32",
                                blocksize=BLOCK, callback=lambda indata, *_: self._capture(indata[:, 0].copy()))
        stream.start()

        def close() -> None:
            stream.stop()
            stream.close()
        return close

    def _open_file(self):
        """The file at real time, block by block like a microphone; recording stops by itself at its end."""
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

    events = Events()
    audio: queue.Queue = queue.Queue()
    control: queue.Queue = queue.Queue()  # slots whose files are on disk, waiting to be loaded here
    recorder = Recorder(args.wav, audio, events)
    archive = archive_module.Archive(events)
    speech_slot = ModelSlot("asr", events, control, audio)
    cleanup_slot = ModelSlot("cleanup", events, control, audio)
    stable = StablePrefix(TYPE_HOLD_S)

    def resume() -> None:
        """Anything that needs a model brings back what `unload` dropped, the speech model first."""
        if speech_slot.suspended or cleanup_slot.suspended:
            speech_slot.resume()
            cleanup_slot.resume()

    def read_commands() -> None:
        for line in sys.stdin:
            command, _, argument = line.strip().partition(" ")
            if command == "start":
                resume()
                recorder.start()
            elif command == "stop":
                recorder.stop()
            elif command == "hold":
                stable.hold_s = min(max(float(argument), 0.2), 3.0)
            elif command == "cleanup":
                resume()
                cleanup_slot.request(None if argument == "off" else argument)
            elif command == "asr" and argument in asr.MODELS:
                resume()
                speech_slot.request(argument)
            elif command == "unload":
                recorder.stop()  # the phrase in flight is finished, and the queue carries that before the unload
                speech_slot.suspend()
                cleanup_slot.suspend()
            elif command == "archive":
                mode, _, rest = argument.partition(" ")
                seconds, _, directory = rest.partition(" ")
                archive.configure(Path(directory).expanduser() if mode == "on" else None,
                                  float(seconds or 0))
        recorder.stop()
        audio.put(QUIT)

    threading.Thread(target=read_commands, daemon=True).start()
    events.send({"kind": "state", "recording": False})

    started = time.perf_counter()
    # MLX keeps freed GPU buffers for reuse, without limit by default. Every partial re-decodes a slightly longer
    # phrase, so almost no buffer is ever reused and a session grew to 24 GB. Measured over 1,479 growing-phrase
    # decodes, 256 MB of reuse beats both 1 GB (median 114 vs 139 ms, 1824 vs 2567 MB) and none (152 ms).
    mx.set_cache_limit(256 << 20)
    vad = seg.Vad(seg.ensure_vad(CACHE_DIR))
    speech_slot.request(args.asr)
    deferred = []  # a cleanup model asked for at startup waits: nothing delays the first `ready`
    while speech_slot.key != speech_slot.want:  # the initial load: downloading, loading, ready
        slot = control.get()
        if slot is speech_slot:
            slot.apply()
        else:
            deferred.append(slot)
    if speech_slot.model is None:
        return  # the speech model could not be fetched or loaded; the error event said why
    speech = TimedSpeech(speech_slot.model)
    asr.warm_up(speech)
    print(f"ready in {time.perf_counter() - started:.1f} s", file=sys.stderr, flush=True)
    events.send({"kind": "ready"})
    for slot in deferred:
        slot.apply()

    def send(event: dict) -> None:
        events.send(event)
        print(f"{event['kind']:7} {speech.decode_ms:4.0f} ms for {speech.audio_s:4.1f} s  {event['text']}",
              file=sys.stderr, flush=True)

    def on_partial(text: str) -> None:
        send({"kind": "partial", "text": text})
        if cleanup_slot.model is None and (typed := stable.update(text, speech.audio_s)):
            send({"kind": "type", "text": typed, "final": False})

    def on_final(text: str) -> None:
        """One phrase is done. With cleanup on, the rewrite runs here, in the transcriber loop: audio keeps
        queueing behind it and the phrase is typed once, cleaned."""
        final = {"kind": "final", "text": text}
        if cleaner := cleanup_slot.model:
            at = time.perf_counter()
            rewritten, ran = cleaner.rewrite(text)
            ms = round((time.perf_counter() - at) * 1000, 1) if ran else 0.0
            final = {"kind": "final", "text": rewritten, "raw": text, "cleanup_ms": ms}
            print(f"cleanup {ms:5.0f} ms  {cleaner.note}", file=sys.stderr, flush=True)
        send(final)
        send({"kind": "type", "text": final["text"], "final": True})
        stable.reset()

    session = seg.Segmenter(speech, vad, on_partial=on_partial, on_final=on_final, on_frame=archive.feed)
    try:
        while (block := audio.get()) is not QUIT:
            if block is CONTROL:
                while True:
                    try:
                        slot = control.get_nowait()
                    except queue.Empty:
                        break
                    if slot is speech_slot and slot.changing():
                        session.finish()   # the phrase in flight belongs to the model that heard it
                        stable.reset()
                    if slot.apply() and slot is speech_slot:
                        speech.speech = slot.model   # None while unloaded: the segmenter keeps the phrases whole
                        gc.collect()  # the outgoing speech model was still held here until this swap
                        mx.clear_cache()
                        if slot.model is not None:
                            asr.warm_up(speech)
                            session.drain()  # whatever was said while no model was loaded
            elif block is STOP:
                session.finish()
                archive.flush()
                if stable.typed:  # the phrase ended without a final decode: what is typed stands
                    send({"kind": "type", "text": " ".join(stable.typed), "final": True})
                    stable.reset()
            else:
                session.feed(block.samples, block.at)
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    archive.close()


if __name__ == "__main__":
    main()
