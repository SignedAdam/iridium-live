"""Phrase segmentation for PhononLive, driven by Silero VAD v5.

An energy gate cannot tell a key click from a syllable, so typing while recording used to open a phrase and
Phonon-2 would hallucinate words out of the clicks. Silero scores every 32 ms frame as speech or not, which
transients fail, and the phrase machine below adds the rest: a phrase opens only after sustained speech, carries a
pre-roll so its onset survives, and closes on a pause with the trailing silence trimmed off the final decode.
"""
from __future__ import annotations

import hashlib
import time
import urllib.request
from collections import deque
from pathlib import Path
from typing import NamedTuple

import numpy as np

SAMPLE_RATE = 16000
FRAME = 512          # Silero v5 reads exactly this many samples at 16 kHz...
CONTEXT = 64         # ...preceded by the tail of the previous frame, as the official wrapper does.
VAD_URL = "https://github.com/snakers4/silero-vad/raw/v5.1.2/src/silero_vad/data/silero_vad.onnx"
VAD_SHA256 = "2623a2953f6ff3d2c1e61740c6cdb7168133479b267dfef114a4a3cc5bdd788f"

START_P = 0.50       # frame probability that counts as speech (Silero's own default; key clicks peak at 0.03)...
END_P = 0.30         # ...and the lower bar it has to fall under to count as silence (hysteresis)
ONSET_S = 0.10       # sustained speech before a phrase opens, so single transients cannot
PREROLL_S = 0.30     # audio kept from before that, so the phrase does not start mid-word
FIRST_PARTIAL_S = 0.2   # phrase audio after the onset before the first partial decode...
PARTIAL_EVERY_S = 0.12  # ...and audio added between partials after that
SILENCE_CLOSE_S = 0.7   # trailing non-speech that ends the phrase
FINAL_TAIL_S = 0.15     # of which this much is kept, so the last consonant is not clipped
MAX_PHRASE_S = 30.0     # a phrase is cut here no matter what
MIN_SPEECH_S = 0.30     # a phrase holding less speech than this is noise: dropped, no final
HELD_MAX_S = 120.0      # phrases waiting for a speech model to come back; the oldest go first past this


def ensure_vad(cache_dir: Path) -> Path:
    """The ONNX weights, fetched once and pinned by hash (2.3 MB; nothing else downloads them for us)."""
    path = cache_dir / "silero_vad_v5.1.2.onnx"
    if not path.exists():
        cache_dir.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(VAD_URL, timeout=60) as response:
            blob = response.read()
        got = hashlib.sha256(blob).hexdigest()
        if got != VAD_SHA256:
            raise RuntimeError(f"silero_vad.onnx sha256 {got}, expected {VAD_SHA256}")
        partial = path.with_suffix(".partial")
        partial.write_bytes(blob)
        partial.rename(path)
    return path


class Vad:
    """Silero v5 over onnxruntime: one speech probability per 512-sample frame, recurrent state carried across."""

    def __init__(self, path: Path):
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.inter_op_num_threads = 1
        options.intra_op_num_threads = 1
        self.session = ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])
        self.rate = np.array(SAMPLE_RATE, dtype=np.int64)
        self.reset()

    def reset(self) -> None:
        self.state = np.zeros((2, 1, 128), dtype=np.float32)
        self.context = np.zeros(CONTEXT, dtype=np.float32)

    def __call__(self, frame: np.ndarray) -> float:
        window = np.concatenate([self.context, frame])[None, :]
        probability, self.state = self.session.run(None, {"input": window, "state": self.state, "sr": self.rate})
        self.context = frame[-CONTEXT:]
        return float(probability[0, 0])


class Timing(NamedTuple):
    """The wall times of one phrase, so the app can show where the speaker's wait went."""
    speech_s: float      # audio length of the phrase as it was decoded
    started: float       # wall time of its first sample, pre-roll included: where it sits in the archived audio
    last_speech: float   # end of the last speech frame in it
    closed: float        # when the phrase was closed, by the silence after it or by `finish`
    decode_at: float     # when its final decode started...
    decoded: float       # ...and when the words came back


class Segmenter:
    """Cuts the incoming audio into phrases and decodes them.

    `on_partial(text)` fires with the whole in-flight phrase, replacing the last; `on_final(text, timing)` fires
    once per phrase that held real speech, with a `Timing` of where its latency went. Partials self-clock off the
    buffer as it stands after a decode returns, so slow decodes space partials out instead of queueing.
    `on_frame(frame, speech, at)` sees every 512-sample frame with its speech decision and the wall time of its
    first sample, which is what the archive cuts its files on.

    Segmenting does not need a speech model: with none loaded the phrases are kept whole and decoded by `drain()`
    as soon as one is back.
    """

    def __init__(self, speech, vad: Vad, *, on_partial=None, on_final=None, on_frame=None):
        self.speech, self.vad = speech, vad
        self.on_partial = on_partial or (lambda text: None)
        self.on_final = on_final or (lambda text, timing: None)
        self.on_frame = on_frame or (lambda frame, speech, at: None)
        self.pending = np.zeros(0, dtype=np.float32)          # samples not yet a whole frame
        self.preroll: deque[np.ndarray] = deque(maxlen=max(1, round(PREROLL_S * SAMPLE_RATE / FRAME)))
        self.held: list[tuple[np.ndarray, float, float, float]] = []  # phrases that finished with no model loaded
        self.clock = 0.0                                      # wall time of the next frame's first sample
        self._reset_phrase()

    def _reset_phrase(self) -> None:
        self.frames: list[np.ndarray] = []   # the in-flight phrase, pre-roll first
        self.open = False                    # has the onset been sustained long enough
        self.onset_run = 0                   # consecutive speech frames while still closed
        self.speech_frames = 0               # speech frames in the phrase (the min-speech test)
        self.last_speech = 0                 # frames in the phrase when speech was last heard
        self.last_speech_at = 0.0            # ...and the wall time that frame ended at
        self.started_at = 0.0                # wall time of the phrase's first sample, once it opens
        self.in_speech = False               # hysteresis: speech until a frame drops under END_P
        self.next_partial = 0                # phrase frames at which to decode next

    def feed(self, block: np.ndarray, at: float) -> None:
        """Accept one block of 16 kHz mono float32 samples, captured at wall time `at`."""
        block = np.asarray(block, dtype=np.float32).reshape(-1)
        self.clock = at - self.pending.size / SAMPLE_RATE  # the samples still waiting came before this block
        self.pending = np.concatenate([self.pending, block])
        while self.pending.size >= FRAME:
            frame, self.pending = self.pending[:FRAME], self.pending[FRAME:]
            self._frame(frame)
            self.clock += FRAME / SAMPLE_RATE

    def _frame(self, frame: np.ndarray) -> None:
        probability = self.vad(frame)
        self.in_speech = probability >= (END_P if self.in_speech else START_P)
        if self.in_speech:
            self.last_speech_at = self.clock + FRAME / SAMPLE_RATE
        self.on_frame(frame, self.in_speech, self.clock)

        if not self.open:
            self.preroll.append(frame)
            self.onset_run = self.onset_run + 1 if self.in_speech else 0
            if self.onset_run * FRAME < ONSET_S * SAMPLE_RATE:
                return
            self.frames = list(self.preroll)       # the onset itself, plus the run-up to it
            self.preroll.clear()
            self.open = True
            self.speech_frames = self.onset_run
            self.last_speech = len(self.frames)
            # This frame starts at `clock`, and the run-up to it is what came immediately before.
            self.started_at = self.clock - (len(self.frames) - 1) * FRAME / SAMPLE_RATE
            self.next_partial = len(self.frames) + round(FIRST_PARTIAL_S * SAMPLE_RATE / FRAME)
            return

        self.frames.append(frame)
        if self.in_speech:
            self.speech_frames += 1
            self.last_speech = len(self.frames)

        quiet = (len(self.frames) - self.last_speech) * FRAME >= SILENCE_CLOSE_S * SAMPLE_RATE
        if quiet or len(self.frames) * FRAME >= MAX_PHRASE_S * SAMPLE_RATE:
            self._finalize(self.clock + FRAME / SAMPLE_RATE)
        elif (self.speech.ready and len(self.frames) >= self.next_partial
              and self.speech_frames * FRAME >= MIN_SPEECH_S * SAMPLE_RATE):
            text, _, _ = self.speech.transcribe_array(np.concatenate(self.frames))
            if text:
                self.on_partial(text)
            self.next_partial = len(self.frames) + round(PARTIAL_EVERY_S * SAMPLE_RATE / FRAME)

    def _finalize(self, closed: float) -> None:
        frames, speech_frames, last_speech = self.frames, self.speech_frames, self.last_speech
        last_speech_at, started_at = self.last_speech_at, self.started_at
        self._reset_phrase()
        self.vad.reset()  # the next phrase starts from silence; stale recurrent state would bias its onset
        if speech_frames * FRAME < MIN_SPEECH_S * SAMPLE_RATE:
            return        # a door, a cough, a burst of typing: nothing to decode
        keep = min(len(frames), last_speech + round(FINAL_TAIL_S * SAMPLE_RATE / FRAME))
        audio = np.concatenate(frames[:keep])
        if not self.speech.ready:
            # No model: keep the phrase whole until there is one.
            self.held.append((audio, started_at, last_speech_at, closed))
            while sum(len(held) for held, _, _, _ in self.held) > HELD_MAX_S * SAMPLE_RATE:
                self.held.pop(0)     # ...but a model that never comes back must not fill memory
            return
        self._decode(audio, started_at, last_speech_at, closed)

    def _decode(self, audio: np.ndarray, started: float, last_speech: float, closed: float) -> None:
        decode_at = time.time()
        text, _, _ = self.speech.transcribe_array(audio)
        if text:
            self.on_final(text, Timing(len(audio) / SAMPLE_RATE, started, last_speech, closed, decode_at,
                                       time.time()))

    def drain(self) -> None:
        """A speech model is loaded again: decode the phrases that finished without one, oldest first."""
        held, self.held = self.held, []
        for audio, started, last_speech, closed in held:
            self._decode(audio, started, last_speech, closed)

    def finish(self) -> None:
        """Recording stopped: decode whatever is in flight, which closes at the end of the audio heard so far."""
        self.pending = np.zeros(0, dtype=np.float32)
        self.preroll.clear()
        if self.open:
            self._finalize(self.clock)
        else:
            self.vad.reset()

    def discard(self) -> None:
        """The recording was cancelled: drop the phrase in flight and any phrase still waiting for a model,
        decoding none of them. Nothing of what was said reaches `on_final`."""
        self.pending = np.zeros(0, dtype=np.float32)
        self.preroll.clear()
        self.held.clear()
        self._reset_phrase()
        self.vad.reset()
