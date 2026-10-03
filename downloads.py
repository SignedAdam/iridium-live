from __future__ import annotations

import threading
import time
from pathlib import Path

HUB = Path.home() / ".cache" / "huggingface" / "hub"


def hub_dir(repo: str) -> Path:
    return HUB / ("models--" + repo.replace("/", "--"))


def hub_bytes(repo: str) -> int:
    try:
        from huggingface_hub import HfApi

        return sum(f.size or 0 for f in HfApi().model_info(repo, files_metadata=True).siblings)
    except Exception:
        return 0


def _size(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) if path.exists() else 0


class Progress:

    def __init__(self, paths, total: int, report):
        self.paths, self.total, self.report = [Path(p) for p in paths], total, report
        self.stop = threading.Event()

    def __enter__(self):
        self.base = sum(_size(p) for p in self.paths)
        self.thread = threading.Thread(target=self._watch, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=1.0)
        return False

    def _watch(self) -> None:
        last = -1.0
        while not self.stop.wait(0.25):
            done = sum(_size(p) for p in self.paths) - self.base
            fraction = round(min(done / self.total, 0.99), 2) if self.total > 0 else 0.0
            if fraction > last:
                last = fraction
                self.report(fraction)

