"""Takes: every recording lands on disk while it is spoken.

A take is one recording, from the moment the microphone opens until it stops. The writer
owns a thread and is fed straight from the capture callback, so nothing the engine does on
its main loop (loading a speech model, decoding, cleanup) can keep audio off the disk. A
journal beside the audio holds every take that is not finished yet, so a recording that a
crashed engine or a quit app left behind is found at the next launch.
"""
from __future__ import annotations

import json
import os
import queue
import struct
import threading
import time
import uuid
from collections import deque
from pathlib import Path

import numpy as np

from segmenter import SAMPLE_RATE

JOURNAL = "takes.jsonl"
OPEN, CAPTURED, DONE, FAILED, EMPTY, DISCARDED = "recording", "captured", "done", "failed", "empty", "discarded"
RESOLVED = (DONE, FAILED, EMPTY, DISCARDED)


class WaveFile:
    """A WAV whose header is kept up to date, so a killed engine still leaves a file that plays."""

    def __init__(self, path: Path):
        self.file = path.open("wb")
        self.frames = 0
        self.written = 0
        self.file.write(self._header())

    def _header(self) -> bytes:
        data = self.frames * 2
        return (b"RIFF" + struct.pack("<I", 36 + data) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, SAMPLE_RATE,
                SAMPLE_RATE * 2, 2, 16) + b"data" + struct.pack("<I", data))

    def write(self, samples: np.ndarray) -> None:
        self.file.write(np.clip(np.round(samples * 32767.0), -32768, 32767).astype("<i2").tobytes())
        self.frames += len(samples)
        if self.frames - self.written >= SAMPLE_RATE:
            self._sync()

    def _sync(self) -> None:
        at = self.file.tell()
        self.file.seek(0)
        self.file.write(self._header())
        self.file.flush()
        self.file.seek(at)
        self.written = self.frames

    def close(self) -> None:
        self._sync()
        self.file.close()


class Take:
    """One recording and the file it is written to."""

    def __init__(self, identifier: str, at: float):
        self.id = identifier
        self.at = at
        self.path: Path | None = None
        self.writer: WaveFile | None = None
        self.samples = 0
        self.hold = False

    @property
    def seconds(self) -> float:
        return round(self.samples / SAMPLE_RATE, 3)


class Takes:
    """Writes recordings to disk as they are captured and journals how each one ended."""

    def __init__(self, events):
        self.events = events
        self.work: queue.Queue = queue.Queue()
        self.folder: Path | None = None
        self.keep = False
        self.current: Take | None = None
        self.recent: deque[Take] = deque(maxlen=32)
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def configure(self, folder: Path, keep: bool) -> None:
        self.work.put(("config", folder, keep))

    def begin(self, at: float) -> str:
        """Claim a take and open its file on the writer thread."""
        identifier = uuid.uuid4().hex[:12]
        self.work.put(("begin", identifier, at))
        return identifier

    def feed(self, samples: np.ndarray) -> None:
        self.work.put(("frame", samples))

    def end(self) -> None:
        self.work.put(("end",))

    def discard(self) -> None:
        self.work.put(("discard",))

    def hold(self, identifier: str) -> None:
        """Keep this take's audio even when audio is not being saved."""
        self.work.put(("hold", identifier))

    def resolve(self, identifier: str, state: str, reason: str = "") -> None:
        self.work.put(("resolve", identifier, state, reason))

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
            kind = item[0]
            if kind == "frame":
                self._write(item[1])
            elif kind == "begin":
                self._begin(item[1], item[2])
            elif kind == "end":
                self._end()
            elif kind == "config":
                self.folder, self.keep = item[1], item[2]
            elif kind == "discard":
                self._discard()
            elif kind == "hold":
                self._hold(item[1])
            elif kind == "resolve":
                self._resolve(item[1], item[2], item[3])
            elif kind == "locate":
                item[3].put(self._locate(item[1], item[2]))
            else:
                self._end()
                return

    def _begin(self, identifier: str, at: float) -> None:
        self._end()
        take = Take(identifier, at)
        self.current = take
        if self.folder is None:
            self._say(take, FAILED, message="No folder for recordings")
            self.current = None
            return
        moment = time.localtime(at)
        day = self.folder / time.strftime("%Y-%m-%d", moment)
        day.mkdir(parents=True, exist_ok=True)
        stem = time.strftime("%H-%M-%S", moment)
        take.path = day / f"{stem}.wav"
        for n in range(2, 1000):
            if not take.path.exists():
                break
            take.path = day / f"{stem}-{n}.wav"
        take.writer = WaveFile(take.path)
        self._say(take, OPEN)

    def _write(self, samples: np.ndarray) -> None:
        take = self.current
        if take is None or take.writer is None:
            return
        take.writer.write(samples)
        take.samples += len(samples)

    def _end(self) -> None:
        take = self.current
        self.current = None
        if take is None or take.writer is None:
            return
        take.writer.close()
        take.writer = None
        self.recent.append(take)
        self._say(take, CAPTURED, seconds=take.seconds)

    def _discard(self) -> None:
        take = self.current
        self._end()
        if take is None:
            return
        self._erase(take)
        self._say(take, DISCARDED)

    def _hold(self, identifier: str) -> None:
        for take in self._known(identifier):
            take.hold = True

    def _resolve(self, identifier: str, state: str, reason: str) -> None:
        takes = self._known(identifier)
        kept = True
        for take in takes:
            if take is self.current:
                self._end()
            if take.samples == 0 or (state in (DONE, EMPTY) and not self.keep and not take.hold):
                self._erase(take)
                kept = False
        self._say(takes[0] if takes else Take(identifier, time.time()), state, message=reason, kept=kept)

    def _erase(self, take: Take) -> None:
        if take.path is not None:
            take.path.unlink(missing_ok=True)
            take.path = None

    def _known(self, identifier: str) -> list[Take]:
        takes = [take for take in self.recent if take.id == identifier]
        if self.current is not None and self.current.id == identifier:
            takes.append(self.current)
        return takes

    def _locate(self, start_at: float, end_at: float) -> list[dict]:
        if not self.keep:
            return []
        refs = []
        for take in list(self.recent) + ([self.current] if self.current else []):
            if take.path is None:
                continue
            start, end = max(start_at, take.at), min(end_at, take.at + take.seconds)
            if end - start > 0.05:
                refs.append({"file": str(take.path), "start_s": round(start - take.at, 3),
                             "end_s": round(end - take.at, 3)})
        return refs

    def _say(self, take: Take, state: str, **extra) -> None:
        event = {"kind": "take", "take": take.id, "state": state, "at": round(take.at, 3)}
        if take.path is not None:
            event["file"] = str(take.path)
        event.update({key: value for key, value in extra.items() if value not in ("", None)})
        self._journal(event)
        self.events.send(event)

    def _journal(self, event: dict) -> None:
        if self.folder is None:
            return
        path = self.folder / JOURNAL
        line = json.dumps({key: value for key, value in event.items() if key != "kind"})
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a") as out:
                out.write(line + "\n")
                out.flush()
                os.fsync(out.fileno())
        except OSError:
            return
        if event["state"] in RESOLVED:
            self._compact(path)

    def _compact(self, path: Path) -> None:
        """Drop finished takes once the journal grows; what is left is what a crash would leave behind."""
        try:
            lines = path.read_text().splitlines()
        except OSError:
            return
        if len(lines) < 400:
            return
        items = []
        for line in lines:
            try:
                items.append(json.loads(line))
            except ValueError:
                continue
        latest = {item.get("take", ""): item.get("state", "") for item in items}
        kept = [item for item in items if latest.get(item.get("take", "")) not in RESOLVED]
        path.write_text("".join(json.dumps(item) + "\n" for item in kept))
