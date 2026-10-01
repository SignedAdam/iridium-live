"""Keeps a copy of everything the microphone heard, as WAV files cut at the long silences.

The cut uses the speech decisions the segmenter already has from Silero, so nothing listens to the audio twice: a
file opens on the first speech after a long enough pause (carrying half a second of what came before, so the first
word is whole), and closes once that pause has passed again (keeping half a second of the quiet after it). The
silence between files is never written, so an hour of an open microphone costs only the minutes that had speech.
Writing happens on this module's own thread; the transcriber only hands frames over.
"""
from __future__ import annotations

import queue
import threading
import time
import wave
from collections import deque
from pathlib import Path

import numpy as np

from segmenter import FRAME, SAMPLE_RATE

EDGE_S = 0.5      # audio kept before the first word and after the last one
_CLOSED = 10 ** 9  # "silent for ever": the first speech of a recording always opens a file


class Archive:
    """One writer thread behind a queue. `feed` is cheap enough to call from the transcriber loop."""

    def __init__(self, events):
        self.events = events
        self.work: queue.Queue = queue.Queue()
        self.directory: Path | None = None
        self.split_frames = 0
        self.writer: wave.Wave_write | None = None
        self.path: Path | None = None
        self.written = 0                  # frames in the file being written
        self.edge = max(1, round(EDGE_S * SAMPLE_RATE / FRAME))
        self.preroll: deque = deque(maxlen=self.edge)   # what to put in front of the first word
        self.pending: list[np.ndarray] = []             # the silence since the last word, not written yet
        self.silence = _CLOSED
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    # ------------------------------------------------------------- the engine's side
    def configure(self, directory: Path | None, split_s: float = 0.0) -> None:
        """`archive on SECONDS DIR` or `archive off`, ordered behind the frames already handed over."""
        self.work.put(("config", directory, split_s))

    def feed(self, frame: np.ndarray, speech: bool, at: float) -> None:
        self.work.put(("frame", frame, speech, at))

    def flush(self) -> None:
        """Recording stopped: close the file in progress, so it is complete and playable."""
        self.work.put(("flush",))

    def discard(self) -> None:
        """Recording was cancelled: throw the file in progress away, so nothing of it is kept."""
        self.work.put(("discard",))

    def close(self) -> None:
        self.work.put(("close",))
        self.thread.join(timeout=5.0)

    # ------------------------------------------------------------- the writer thread
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
                lead = [f for f, _ in self.preroll]  # the half second before the word, and the word's first frame
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
        """A file is named for the local time of its first sample, which is the oldest frame of the pre-roll."""
        at = self.preroll[0][1] if self.preroll else time.time()
        moment = time.localtime(at)
        folder = self.directory / time.strftime("%Y-%m-%d", moment)
        folder.mkdir(parents=True, exist_ok=True)
        stem = time.strftime("%H-%M-%S", moment)
        self.path = folder / f"{stem}.wav"
        for n in range(2, 1000):  # two recordings can start in the same second
            if not self.path.exists():
                break
            self.path = folder / f"{stem}-{n}.wav"
        self.writer = wave.open(str(self.path), "wb")
        self.writer.setnchannels(1)
        self.writer.setsampwidth(2)
        self.writer.setframerate(SAMPLE_RATE)
        self.written = 0
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
        self._write(self.pending[:self.edge])  # the quiet right after the last word, and no more
        self.pending.clear()
        self.writer.close()
        self.writer = None
        self.events.send({"kind": "archive", "file": str(self.path),
                          "seconds": round(self.written * FRAME / SAMPLE_RATE, 3)})

    def _discard_file(self) -> None:
        """Close the file in progress and delete it: a cancelled recording leaves nothing on disk and says
        nothing, since the app was never told the file existed."""
        if self.writer is None:
            return
        self.pending.clear()
        self.writer.close()
        self.writer = None
        self.path.unlink(missing_ok=True)
