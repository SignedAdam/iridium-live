"""Replay a recorded take through the real engine on Vegeta Live and print, per phrase, end of speech → corrected text.

    python replay.py take.wav [--base https://citadel.albastov.com] [--model vegeta-fast] [--asr vegeta-live]

Runs live.py as the app does (uv, the same commands with Settings' defaults), plays the WAV at real time in place of
the microphone, and reads the engine's events. Needs CITADEL_API_KEY in the environment (any value for the stub:
python tests/stream_stub.py). Nothing of the app's is touched: the take goes to a temporary folder and is dropped.
`--asr vegeta` replays the same take over the HTTP path, for comparison.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def row(cells: list[str], widths: list[int]) -> str:
    return "  ".join(cell.rjust(width) if i < len(widths) - 1 else cell
                     for i, (cell, width) in enumerate(zip(cells, widths)))


def ms(value) -> str:
    return "" if value is None else f"{round(value)}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("wav")
    parser.add_argument("--base", default="https://citadel.albastov.com", help="Citadel's origin")
    parser.add_argument("--asr", default="vegeta-live", choices=["vegeta-live", "vegeta"])
    parser.add_argument("--model", default="vegeta-fast", help="cleanup model id; empty: no cleanup")
    parser.add_argument("--speech-model", default="parakeet")
    parser.add_argument("--fallback", default="fail", choices=["fail", "local"],
                        help="what a take Vegeta fails does (the app's default is local)")
    parser.add_argument("--no-polish", action="store_true")
    parser.add_argument("--log", help="the engine's own log (stderr); a temporary file by default")
    args = parser.parse_args()
    if not os.environ.get("CITADEL_API_KEY"):
        print("CITADEL_API_KEY is not set", file=sys.stderr)
        return 2
    uv = shutil.which("uv")
    if uv is None:
        print("uv is not installed", file=sys.stderr)
        return 2
    folder = Path(tempfile.mkdtemp(prefix="iridium-replay-"))
    log_path = Path(args.log) if args.log else folder / "engine.log"
    provider = "vegeta-live" if args.asr == "vegeta-live" else "vegeta"
    commands = [
        f"takes drop {folder}",
        "hold 0.7",
        *([f"cleanup {provider}:{args.model}"] if args.model else []),
        "polish off" if args.no_polish else "polish on",
        "corrections 5 2",
        "rules ",
        "failure raw 3",
        "timeout 4",
        "vegeta " + json.dumps({"base": args.base, "model": args.speech_model, "timeout_s": 8,
                                "fallback": args.fallback}),
    ]
    with open(log_path, "w") as log:
        engine = subprocess.Popen([uv, "run", "--quiet", "--script", str(HERE / "live.py"), "--asr", args.asr,
                                   "--wav", str(Path(args.wav).resolve()), "--takes", str(folder)],
                                  cwd=HERE, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
                                  bufsize=1)

        def send(command: str) -> None:
            engine.stdin.write(command + "\n")
            engine.stdin.flush()

        for command in commands:
            send(command)
        widths = [5, 6, 7, 8, 6, 7, 6, 6, 0]
        print(row(["id", "speech", "total", "endpoint", "stt", "infer", "clean", "ttft", "text"], widths))
        totals, stts, cleans, polish = [], [], [], None
        started = False
        watchdog = threading.Timer(600, engine.kill)
        watchdog.daemon = True
        watchdog.start()
        for line in engine.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get("kind")
            if kind == "ready" and not started:
                started = True
                send("start")
            elif kind == "notice":
                print(f"      notice: {event['text']}")
            elif kind in ("asr", "cleanup") and event.get("state") == "error":
                print(f"      {kind}: {event.get('message')}")
            elif kind == "final":
                timing = event.get("timing") or {}
                cleanup = timing.get("cleanup") or {}
                server = timing.get("stream") or {}
                via = timing.get("via") or "this Mac"
                totals.append(timing.get("total_ms", 0))
                stts.append(timing.get("decode_ms", 0))
                if cleanup and not cleanup.get("skipped"):
                    cleans.append(cleanup.get("ms", 0))
                print(row([event.get("id", ""), ms(timing.get("speech_ms")), ms(timing.get("total_ms")),
                           ms(timing.get("endpoint_ms")), ms(timing.get("decode_ms")),
                           ms(server.get("inference")),
                           "skip" if cleanup.get("skipped") else ms(cleanup.get("ms")) if cleanup else "",
                           ms(cleanup.get("ttft_ms")),
                           (f"[{via}] " if via != args.asr else "") + (f"[{cleanup['error']}] "
                                                                       if cleanup.get("error") else "")
                           + event.get("text", "")], widths))
            elif kind == "session":
                polish = (event.get("timing") or {}).get("ms")
            elif kind == "take" and event.get("state") in ("done", "empty", "failed"):
                if event.get("state") == "failed":
                    print(f"      the take failed: {event.get('message')}")
                break
        engine.stdin.close()
        try:
            engine.wait(10)
        except subprocess.TimeoutExpired:
            engine.kill()
    if totals:
        print(f"\n{len(totals)} phrases. End of speech → corrected text: median {statistics.median(totals):.0f} ms, "
              f"slowest {max(totals):.0f} ms (each includes the {0.7 * 1000:.0f} ms of silence that closes a phrase)."
              f"\nSpeech to text round trip: median {statistics.median(stts):.0f} ms."
              + (f"\nCleanup: median {statistics.median(cleans):.0f} ms." if cleans else "")
              + (f"\nPolish of the whole take: {polish} ms." if polish is not None else ""))
    else:
        print("no phrases came back")
    print(f"engine log: {log_path}")
    if not args.log:
        for item in folder.iterdir():
            if item != log_path:
                shutil.rmtree(item, ignore_errors=True) if item.is_dir() else item.unlink(missing_ok=True)
    return 0 if totals else 1


if __name__ == "__main__":
    sys.exit(main())
