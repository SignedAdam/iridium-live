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
"""Phonon-2 (or Parakeet) on MLX, driven over stdin/stdout by the Iridium Live app.
Commands on stdin, one per line. "start" opens the MacBook microphone (or plays --wav FILE at real time); "stop"
closes it and finishes the phrase in flight; "cancel" closes it and throws that phrase away instead, so nothing
of it is transcribed, typed or archived; "hold SECONDS" sets how long a word must read the same before it is
typed; "cleanup off|openrouter:MODEL|groq:MODEL" turns the rewrite model off or on at a provider
(OPENROUTER_API_KEY or GROQ_API_KEY out of the environment; nothing is downloaded or loaded, a key that does not
name a provider answers with a cleanup error, and a request that fails or runs long leaves the phrase raw);
"asr phonon-2|parakeet" switches the speech model; "unload" drops the speech model from memory (the next start
brings it back; the cleanup model holds none, so it keeps working); "archive on SECONDS DIRECTORY" keeps a copy of
the recorded audio as WAV files cut at silences that long, "archive off" stops; "instructions JSON" sets the
speaker's own instructions for the cleanup model, as a JSON string so they can hold newlines (an empty JSON string
clears them). They go under the fixed rules of the cleanup prompt, and while they are set no phrase is clean
enough to skip the model. Nothing comes back for them except an error event if the JSON is not a string.
"context JSON" gives the text the next recording is about to continue (the note above the cursor, say), as a JSON
string: the cleanup model reads the end of it in front of every phrase of that recording and never writes it back.
It is cleared by the next "start" unless it is sent again, so it is sent just before one. "polish on|off" (on by
default) runs one more pass over the whole of a recording once it stops, which is what fixes the corrections,
sentence boundaries and inconsistencies that span two phrases. "rewrite ID JSON" cleans one whole text the same
way, out of band, and answers with its id. "benchmark on|off" runs every other model of the chosen provider over
each phrase in the background, after the phrase has been typed, for comparing them on real dictation; it never
delays a phrase.
All act at once, even while a model is still loading: audio waits and is transcribed as soon as the model is
ready, and any model that is not on disk is fetched first. Events on stdout, one JSON object per line:
  {"kind": "state", "recording": bool}             at startup and after every change
  {"kind": "asr" | "cleanup", "state": "off"|"downloading"|"loading"|"ready"|"unloaded"|"error", "model": ...,
   "progress": 0..1, "message": ...}               whenever a model's state changes ("off" is cleanup only)
  {"kind": "ready"}                                the speech model is loaded, once, at startup
  {"kind": "level", "value": 0..1}                 input level of each 50 ms block while recording
  {"kind": "work", "pending": bool}                true when a "stop" left work behind (audio queued, a phrase
                                                   open or decoding, a cleanup running); false once every stop or
                                                   cancel has been seen through, even one that left nothing behind
  {"kind": "stalled"}                              the transcriber has held one item for STALL_S: stuck, with
                                                   every thread's stack written to stderr
  {"kind": "restart"}                              the microphone stuck closing (a CoreAudio deadlock): the
                                                   recording it ended is out, and the engine exits to be started
                                                   again, which gets a working one
  {"kind": "partial" | "final", "text": ...}       caption: the whole in-flight phrase, replacing the previous one
                                                   (final also carries "raw" and "cleanup_ms" when cleanup is on)
  {"kind": "type", "text": ..., "final": bool}     the phrase as it should stand typed so far (the app decides
                                                   whether typing is on)
  {"kind": "session", "session": N, "text": ...,   one per recording that produced a final, after its last final
   "heard": ..., "phrases": [...], "polished":     and before work falls to false: "heard" is those finals joined
   bool, "timing": ...}                            by single spaces, "text" the whole of it polished (equal to
                                                   "heard" when polishing is off or the pass did not land), and
                                                   "timing" what that pass cost, in the shape a final's "cleanup"
                                                   has. A cancelled recording says nothing.
  {"kind": "rewritten", "id": ..., "text": ...,    the answer to one "rewrite", with what the pass cost
   "timing": ...}
  {"kind": "benchmark", "phrase": ID,              what the provider's other models made of one phrase, each with
   "results": [...]}                               "provider", "model", "text", "ms", "prompt_tokens",
                                                   "completion_tokens", "cost_usd" and "error"
  {"kind": "archive", "file": ..., "seconds": ...} a recording was closed on disk
Every final carries "id", unique, and "session", the number of the recording it belongs to, which counts up from
one at every start. It also carries "timing", all milliseconds, for where the speaker's wait went: "speech_ms" is
how much audio the phrase holds, "endpoint_ms" the silence from its last speech frame until it closed (or until
"stop" cut it), "queue_ms" how long it then waited behind earlier work, "decode_ms" its final transcription,
"total_ms" the whole wait from that last speech frame to this event, and "cleanup" null with cleanup off or an
object with the provider, the model, whether the phrase was clean enough to skip the model, "ms" as the speaker
waits for it, the connection and network time, what the provider reports of its own queue, prompt and generation
time, the token counts, the cost in dollars and any error that left the phrase raw.
"""
import argparse
import faulthandler
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
STALL_S = 90.0     # one item in the transcriber's hands this long is a hang: a model load or a cleanup pass ends well before
STOP_WAIT_S = 3.0  # closing the microphone takes milliseconds; CoreAudio can also deadlock in it and never return
BLOCK = int(0.05 * seg.SAMPLE_RATE)
CACHE_DIR = Path.home() / ".cache" / "iridium-live"
if not CACHE_DIR.exists() and (CACHE_DIR.parent / "phonon-live").exists():  # the app's former name: keep its models
    (CACHE_DIR.parent / "phonon-live").rename(CACHE_DIR)
STOP, QUIT, CONTROL, CANCEL, RESTART = "stop", "quit", "control", "cancel", "restart"  # markers in the audio queue


class Block(NamedTuple):
    """One captured block, carrying the wall time of its first sample: the archive names files by it."""
    at: float
    samples: np.ndarray


class Job(NamedTuple):
    """Work sent through the audio queue so that it runs on the transcriber thread, in the order the speaker asked
    for it: the start of a recording, which numbers it and takes the context the app sent, and a whole-text
    rewrite, which needs the loaded cleanup model."""
    kind: str
    data: tuple


class Dictation:
    """One recording as the cleanup model sees it: which recording it is, the text it continues (sent by the app
    just before it started) and the phrases it has produced so far, cleaned. Every phrase is cleaned with all of
    that in front of it as context, and the whole of it is polished once more when the recording stops."""

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
        """The id of the phrase about to be decoded, unique for the life of the engine."""
        self.index += 1
        return f"{self.number}-{self.index}"

    def before(self) -> str:
        """What the next phrase continues: the app's context, then this recording's phrases so far."""
        return " ".join(piece for piece in [self.context, *(text for _, text in self.phrases)] if piece)

    def add(self, phrase: str, text: str) -> None:
        self.phrases.append((phrase, text))

    def drop(self) -> None:
        """A cancelled recording: nothing of it is polished or reported."""
        self.phrases = []


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
            try:
                print(json.dumps(event), flush=True)
            except BrokenPipeError:
                os._exit(0)  # the app is gone, and with it everyone this engine works for


class Work:
    """Whether the speaker is still waiting after recording stopped. The app shows that the engine is finishing
    something it cannot hear any more, so changes are worth an event, and so is the end of every stop."""

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
        """A stop (or cancel) has been seen through. Said even when nothing was pending: a recording that heard
        nothing has no final and no session, and whoever waits on the stop must still hear that it is over."""
        with self.lock:
            self.pending = False
            self.events.send({"kind": "work", "pending": False})


class ModelSlot:
    """One switchable model, in two halves: the command thread decides and downloads, the transcriber thread loads.

    MLX is not safe to drive from two threads, so nothing here touches it except `apply`. A slot only reaches the
    `control` queue once its files are on disk, and the CONTROL marker in the audio queue is what wakes the
    transcriber up to look. Downloads run on their own thread, so a 600 MB fetch never stops audio from queueing.
    Only the speech model is ever on this Mac: cleanup runs at a provider, so its slot holds a connection and no
    memory, and nothing of it is downloaded, loaded or unloaded.
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
        if self.kind == "cleanup":
            return key  # a cleanup model is named by the key itself: "<provider>:<model id>"
        return asr.MODELS.get(key) if key else None

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
        if self.kind == "cleanup":  # nothing to fetch and nothing to load: all it needs is a key in the environment
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
            self.model = asr.load(key, CACHE_DIR)
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

    def __init__(self, wav: str | None, audio: queue.Queue, events: Events, on_stop=None, on_cancel=None):
        self.wav, self.audio, self.events = wav, audio, events
        self.on_stop = on_stop or (lambda: None)
        self.on_cancel = on_cancel or (lambda: None)
        self.lock = threading.Lock()
        self.close_source = None  # set while recording
        self.stuck = False  # a close never returned: this process has lost the microphone for good

    def start(self) -> None:
        with self.lock:
            if self.close_source:
                return
            try:
                if self.stuck:  # this engine is on its way out: whatever it recorded now would go with it
                    raise RuntimeError("the microphone is stuck; the engine is restarting")
                self.close_source = self._open_file() if self.wav else self._open_microphone()
            except Exception as exc:  # no microphone, no permission, or stuck: say why and stay stopped
                print(f"could not start recording: {exc}", file=sys.stderr, flush=True)
                self.events.send({"kind": "state", "recording": False})
                self.events.send({"kind": "work", "pending": False})  # nothing was heard, so nothing is left to wait for
                return
        print("recording", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": True})

    def stop(self) -> None:
        with self.lock:
            if not self.close_source:
                return
            self._close()
            self.audio.put(STOP)  # the transcriber finishes the phrase when it gets here
            if self.stuck:
                self.audio.put(RESTART)  # ...and then makes way for an engine with a working microphone
        print("stopped", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": False})
        self.on_stop()

    def cancel(self) -> None:
        """Stop and throw the recording away: the blocks still waiting are dropped here and the marker tells the
        transcriber to drop the phrase in flight, so nothing of it is decoded, typed or archived. The decode the
        transcriber already has in hand is silenced first: its words belong to the phrase being thrown away."""
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
                    markers.append(item)  # a model change was waiting behind the audio: it still has to happen
            for item in markers:
                self.audio.put(item)
            self.audio.put(CANCEL)
            if self.stuck:
                self.audio.put(RESTART)
        print("cancelled", file=sys.stderr, flush=True)
        self.events.send({"kind": "state", "recording": False})

    def _close(self) -> None:
        """Closes the source on a thread of its own, waiting STOP_WAIT_S at most. CoreAudio can deadlock in a stream
        stop (PortAudio's start/stop listener against AudioOutputUnitStop) and never return. Commands must keep
        flowing regardless, so the stop is left behind, the recording is finished from what it heard, and the engine
        is restarted: a new process gets a working microphone."""
        closing = threading.Thread(target=self.close_source, daemon=True)
        closing.start()
        closing.join(STOP_WAIT_S)
        self.close_source = None
        if closing.is_alive():
            self.stuck = True
            print("the microphone did not close: the engine restarts after this recording", file=sys.stderr, flush=True)

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
    faulthandler.enable()  # a crash in native code (MLX, PortAudio) still leaves its stacks in the log

    events = Events()
    audio: queue.Queue = queue.Queue()
    control: queue.Queue = queue.Queue()  # slots whose files are on disk, waiting to be loaded here
    work = Work(events)
    working = threading.Event()           # the transcriber has an item in hand...
    taken = [time.monotonic()]            # ...since this moment
    discarding = threading.Event()        # a cancel is on its way: this recording says nothing more
    session: seg.Segmenter | None = None  # built below, once there is a speech model to decode with

    def stopped() -> None:
        """Recording stopped: the speaker goes on waiting if any audio, phrase or decode is still left over.
        The STOP marker is already in the queue, so anything past it is audio that has not been heard yet."""
        work.set(audio.qsize() > 1 or working.is_set() or bool(session and session.open))

    recorder = Recorder(args.wav, audio, events, stopped, discarding.set)
    archive = archive_module.Archive(events)
    speech_slot = ModelSlot("asr", events, control, audio)
    cleanup_slot = ModelSlot("cleanup", events, control, audio)
    stable = StablePrefix(TYPE_HOLD_S)
    dictation = Dictation()
    bench = cleanup_model.Bench(
        lambda phrase, results: events.send({"kind": "benchmark", "phrase": phrase, "results": results}))
    polishing = True       # one pass over the whole of a recording when it stops
    benchmarking = False   # the provider's other models run over each phrase, behind the speaker
    context = ""           # what the next recording continues, until a start takes it

    def watch_for_stalls() -> None:
        """The transcriber holding one item for STALL_S is stuck: every thread's stack goes to stderr (the app's
        log), and the app is told, so a speaker who gets nothing back learns why. Once per stall."""
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
        """Anything that needs a model brings back what `unload` dropped. Only the speech model is ever dropped:
        cleanup runs at a provider and holds nothing to bring back."""
        if speech_slot.suspended:
            speech_slot.resume()

    def read_commands() -> None:
        nonlocal polishing, benchmarking, context

        def comparing() -> None:
            """The models to compare against: the chosen provider's others, and none at all while benchmarking is
            off or no cleanup model is set."""
            bench.configure(cleanup_slot.want if benchmarking else None)

        for line in sys.stdin:
            command, _, argument = line.strip().partition(" ")
            if command == "start":
                resume()
                audio.put(Job("start", (context,)))  # ...which numbers the recording, before any of its audio
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
            elif command == "benchmark":
                benchmarking = argument == "on"
                comparing()
            elif command == "asr" and argument in asr.MODELS:
                resume()
                speech_slot.request(argument)
            elif command == "unload":
                recorder.stop()  # the phrase in flight is finished, and the queue carries that before the unload
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
        finally:  # however reading ends, the transcriber is told: an engine nobody can reach must not linger
            recorder.stop()
            audio.put(QUIT)

    threading.Thread(target=commands_then_quit, daemon=True).start()
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
        if discarding.is_set():
            return  # a cancel is on its way through the queue: these words are already thrown away
        send({"kind": "partial", "text": text})
        if cleanup_slot.model is None and (typed := stable.update(text, speech.audio_s)):
            send({"kind": "type", "text": typed, "final": False})

    def on_final(text: str, timing: seg.Timing) -> None:
        """One phrase is done. With cleanup on, the rewrite runs here, in the transcriber loop: audio keeps
        queueing behind it and the phrase is typed once, cleaned, with everything said earlier in this recording
        in front of it as context. The event carries where the wait went, from the last word the phrase held to
        this line leaving, and where the phrase can be heard in the archive."""
        if discarding.is_set():
            return
        # Asked before the rewrite, which can take seconds: this is where the phrase sits in the files as they
        # stand now, and the archive has every frame of it already.
        heard = archive.locate(timing.started, timing.started + timing.speech_s)
        phrase = dictation.claim()
        before = dictation.before()
        final = {"kind": "final", "text": text}
        cleanup = None
        if cleaner := cleanup_slot.model:
            at = time.perf_counter()
            rewritten, stats = cleaner.rewrite(text, before)
            ms = (time.perf_counter() - at) * 1000
            cleanup = stats._replace(ms=round(ms))._asdict()
            final = {"kind": "final", "text": rewritten, "raw": text,
                     "cleanup_ms": 0.0 if stats.skipped else round(ms, 1)}
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
        if cleanup is not None and not cleanup["skipped"]:
            bench.submit(phrase, text, before)  # the same phrase and the same context, behind the speaker

    def whole(text: str) -> tuple[str, dict | None]:
        """One whole text through the cleanup model, and what the pass cost. With no model loaded the text comes
        back as it was, which is what the speaker already has."""
        cleaner = cleanup_slot.model
        if cleaner is None:
            return text, None
        at = time.perf_counter()
        written, stats = cleaner.whole(text)
        ms = (time.perf_counter() - at) * 1000
        print(f"whole   {ms:5.0f} ms  {len(text)} chars", file=sys.stderr, flush=True)
        return written, stats._replace(ms=round(ms))._asdict()

    def finish_dictation() -> None:
        """A recording that said something has stopped: its phrases as one text, polished in one more pass when
        polishing is on and a model is loaded. Sent after the last final and before the work falls away."""
        if not dictation.phrases:
            return
        said = " ".join(text for _, text in dictation.phrases)
        text, cost = (whole(said) if polishing else (said, None))
        events.send({"kind": "session", "session": dictation.number, "text": text, "heard": said,
                     "phrases": [phrase for phrase, _ in dictation.phrases],
                     "polished": bool(cost) and not cost["error"], "timing": cost})
        dictation.drop()

    session = seg.Segmenter(speech, vad, on_partial=on_partial, on_final=on_final, on_frame=archive.feed)
    stopped_unheard = False  # a stop came while its phrases waited for a speech model: the reload finishes it
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
                        session.finish()   # the phrase in flight belongs to the model that heard it
                        stable.reset()
                    if slot.apply() and slot is speech_slot:
                        speech.speech = slot.model   # None while unloaded: the segmenter keeps the phrases whole
                        gc.collect()  # the outgoing speech model was still held here until this swap
                        mx.clear_cache()
                        if slot.model is not None:
                            asr.warm_up(speech)
                            session.drain()  # whatever was said while no model was loaded
                            if stopped_unheard:  # ...ended a recording whose stop came before the model
                                stopped_unheard = False
                                finish_dictation()
                                with audio.mutex:
                                    another = any(item is STOP for item in audio.queue)
                                if not another:  # a later stop still in the queue says done for itself
                                    work.done()
            elif block is STOP:
                session.finish()
                archive.flush()
                if stable.typed:  # the phrase ended without a final decode: what is typed stands
                    send({"kind": "type", "text": " ".join(stable.typed), "final": True})
                    stable.reset()
                if session.held:  # said with no speech model loaded: decoded and reported once one is back
                    stopped_unheard = True
                    work.set(True)
                else:
                    finish_dictation()  # the whole recording, polished, before the speaker is told it is done
                    work.done()
            elif block is RESTART:  # the recording before it is out: a fresh engine gets a working microphone
                archive.close()
                events.send({"kind": "restart"})
                os._exit(0)
            elif block is CANCEL:
                session.discard()  # the phrase in flight is not decoded, typed or kept
                archive.discard()
                stable.reset()
                dictation.drop()   # ...and the recording it belonged to is never polished or reported
                work.done()
                discarding.clear()  # everything of that recording is behind us; the next one speaks again
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
    os._exit(0)  # not the interpreter's own exit: it waits on threads, and a stuck audio stop is one that never ends


if __name__ == "__main__":
    main()
