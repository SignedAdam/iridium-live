from __future__ import annotations

import hashlib
import time
import urllib.request
from collections import deque
from pathlib import Path
from typing import NamedTuple

import numpy as np

SAMPLE_RATE = 16000
FRAME = 512
CONTEXT = 64
VAD_URL = "https://github.com/snakers4/silero-vad/raw/v5.1.2/src/silero_vad/data/silero_vad.onnx"
VAD_SHA256 = "2623a2953f6ff3d2c1e61740c6cdb7168133479b267dfef114a4a3cc5bdd788f"

START_P = 0.50
END_P = 0.30
ONSET_S = 0.10
PREROLL_S = 0.30
FIRST_PARTIAL_S = 0.2
PARTIAL_EVERY_S = 0.12
SILENCE_CLOSE_S = 0.7
FINAL_TAIL_S = 0.15
MAX_PHRASE_S = 30.0
MIN_SPEECH_S = 0.30
HELD_MAX_S = 120.0


def ensure_vad(cache_dir: Path) -> Path:
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
    speech_s: float
    started: float
    last_speech: float
    closed: float
    decode_at: float
    decoded: float


class Segmenter:

    def __init__(self, speech, vad: Vad, *, on_partial=None, on_final=None, on_frame=None):
        self.speech, self.vad = speech, vad
        self.on_partial = on_partial or (lambda text: None)
        self.on_final = on_final or (lambda text, timing, audio: None)
        self.on_frame = on_frame or (lambda frame, speech, at: None)
        self.pending = np.zeros(0, dtype=np.float32)
        self.preroll: deque[np.ndarray] = deque(maxlen=max(1, round(PREROLL_S * SAMPLE_RATE / FRAME)))
        self.held: list[tuple[np.ndarray, float, float, float]] = []
        self.clock = 0.0
        self._reset_phrase()

    def _reset_phrase(self) -> None:
        self.frames: list[np.ndarray] = []
        self.open = False
        self.onset_run = 0
        self.speech_frames = 0
        self.last_speech = 0
        self.last_speech_at = 0.0
        self.started_at = 0.0
        self.in_speech = False
        self.next_partial = 0

    def feed(self, block: np.ndarray, at: float) -> None:
        block = np.asarray(block, dtype=np.float32).reshape(-1)
        self.clock = at - self.pending.size / SAMPLE_RATE
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
            self.frames = list(self.preroll)
            self.preroll.clear()
            self.open = True
            self.speech_frames = self.onset_run
            self.last_speech = len(self.frames)
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
        self.vad.reset()
        if speech_frames * FRAME < MIN_SPEECH_S * SAMPLE_RATE:
            return
        keep = min(len(frames), last_speech + round(FINAL_TAIL_S * SAMPLE_RATE / FRAME))
        audio = np.concatenate(frames[:keep])
        if not self.speech.ready:
            self.held.append((audio, started_at, last_speech_at, closed))
            while sum(len(held) for held, _, _, _ in self.held) > HELD_MAX_S * SAMPLE_RATE:
                self.held.pop(0)
            return
        self._decode(audio, started_at, last_speech_at, closed)

    def _decode(self, audio: np.ndarray, started: float, last_speech: float, closed: float) -> None:
        decode_at = time.time()
        text, _, _ = self.speech.transcribe_array(audio)
        if text:
            self.on_final(text, Timing(len(audio) / SAMPLE_RATE, started, last_speech, closed, decode_at,
                                       time.time()), audio)

    def drain(self) -> None:
        held, self.held = self.held, []
        for audio, started, last_speech, closed in held:
            self._decode(audio, started, last_speech, closed)

    def finish(self) -> None:
        self.pending = np.zeros(0, dtype=np.float32)
        self.preroll.clear()
        if self.open:
            self._finalize(self.clock)
        else:
            self.vad.reset()

    def discard(self) -> None:
        self.pending = np.zeros(0, dtype=np.float32)
        self.preroll.clear()
        self.held.clear()
        self._reset_phrase()
        self.vad.reset()

