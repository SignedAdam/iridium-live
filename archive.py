from __future__ import annotations

import queue
import threading
import time
import wave
from collections import deque
from pathlib import Path

import numpy as np

from segmenter import FRAME, SAMPLE_RATE

EDGE_S = 0.5
_CLOSED = 10 ** 9


class Archive:

    def __init__(self, events):
        self.events = events
        self.work: queue.Queue = queue.Queue()
        self.directory: Path | None = None
        self.split_frames = 0
        self.writer: wave.Wave_write | None = None
        self.path: Path | None = None
        self.written = 0
        self.start_at = 0.0
        self.edge = max(1, round(EDGE_S * SAMPLE_RATE / FRAME))
        self.history: deque = deque(maxlen=32)
        self.preroll: deque = deque(maxlen=self.edge)
        self.pending: list[np.ndarray] = []
        self.silence = _CLOSED
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def configure(self, directory: Path | None, split_s: float = 0.0) -> None:
        self.work.put(("config", directory, split_s))

    def feed(self, frame: np.ndarray, speech: bool, at: float) -> None:
        self.work.put(("frame", frame, speech, at))

    def flush(self) -> None:
        self.work.put(("flush",))

    def discard(self) -> None:
        self.work.put(("discard",))

    def locate(self, start_at: float, end_at: float) -> list[dict]:
        answer: queue.Queue = queue.Queue(maxsize=1)
        self.work.put(("locate", start_at, end_at, answer))
        try:
            return answer.get(timeout=2.0)
        except queue.Empty:
            return []

    def close(self) -> None:
        self.work.put(("close",))
        self.thread.join(timeout=5.0)

    def _run(self) -> None:
        while True:
            item = self.work.get()
            if item[0] == "frame":
                self._frame(*item[1:])
            elif item[0] == "config":
                self._close_file()
                self.directory, self.split_frames = item[1], max(1, round(item[2] * SAMPLE_RATE / FRAME))
                self._reset()
            elif item[0] == "flush":
                self._close_file()
                self._reset()
            elif item[0] == "discard":
                self._discard_file()
                self._reset()
            elif item[0] == "locate":
                item[3].put(self._locate(item[1], item[2]))
            else:
                self._close_file()
                return

    def _reset(self) -> None:
        self.preroll.clear()
        self.pending.clear()
        self.silence = _CLOSED

    def _frame(self, frame: np.ndarray, speech: bool, at: float) -> None:
        if self.directory is None:
            return
        if self.writer is None:
            self.preroll.append((frame, at))
            if speech and self.silence >= self.split_frames:
                lead = [f for f, _ in self.preroll]
                self._open_file()
                self._write(lead)
            self.silence = 0 if speech else self.silence + 1
            return

        if speech:
            self._write(self.pending + [frame])
            self.pending.clear()
            self.silence = 0
            return
        self.pending.append(frame)
        self.silence += 1
        if self.silence >= self.split_frames:
            self._close_file()

    def _open_file(self) -> None:
        at = self.preroll[0][1] if self.preroll else time.time()
        moment = time.localtime(at)
        folder = self.directory / time.strftime("%Y-%m-%d", moment)
        folder.mkdir(parents=True, exist_ok=True)
        stem = time.strftime("%H-%M-%S", moment)
        self.path = folder / f"{stem}.wav"
        for n in range(2, 1000):
            if not self.path.exists():
                break
            self.path = folder / f"{stem}-{n}.wav"
        self.writer = wave.open(str(self.path), "wb")
        self.writer.setnchannels(1)
        self.writer.setsampwidth(2)
        self.writer.setframerate(SAMPLE_RATE)
        self.written = 0
        self.start_at = at
        self.preroll.clear()

    def _write(self, frames: list[np.ndarray]) -> None:
        if not frames:
            return
        samples = np.concatenate(frames)
        self.writer.writeframes(np.clip(np.round(samples * 32767.0), -32768, 32767).astype("<i2").tobytes())
        self.written += len(frames)

    def _close_file(self) -> None:
        if self.writer is None:
            return
        self._write(self.pending[:self.edge])
        self.pending.clear()
        self.writer.close()
        self.writer = None
        seconds = round(self.written * FRAME / SAMPLE_RATE, 3)
        self.history.append((str(self.path), self.start_at, seconds))
        self.events.send({"kind": "archive", "file": str(self.path), "seconds": seconds})

    def _locate(self, start_at: float, end_at: float) -> list[dict]:
        files = list(self.history)
        if self.writer is not None:
            kept = self.written + min(len(self.pending), self.edge)
            files.append((str(self.path), self.start_at, kept * FRAME / SAMPLE_RATE))
        refs = []
        for path, began, seconds in files:
            start, end = max(start_at, began), min(end_at, began + seconds)
            if end - start > FRAME / SAMPLE_RATE:
                refs.append({"file": path, "start_s": round(start - began, 3), "end_s": round(end - began, 3)})
        return refs

    def _discard_file(self) -> None:
        if self.writer is None:
            return
        self.pending.clear()
        self.writer.close()
        self.writer = None
        self.path.unlink(missing_ok=True)

