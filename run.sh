#!/bin/sh
# PhononLive: a floating glass control (record; notes that keep everything you say, saved to
# ~/Library/Application Support/PhononLive; typing into the focused app; settings) and live captions.
# Notes and typing stay off until you switch them on. Models download by themselves when first needed. Ctrl-C quits.
# ./run.sh              the MacBook microphone (the terminal needs microphone access; typing needs Accessibility)
# ./run.sh --wav FILE   Record plays the file at real time through the same path
set -eu
cd "$(dirname "$0")"
if [ ! -x .build/PhononLive ] || [ -n "$(find Sources -newer .build/PhononLive)" ]; then
    mkdir -p .build
    swiftc -O -swift-version 6 Sources/*.swift -o .build/PhononLive
fi
exec .build/PhononLive fonts/TikTokSans.ttf uv run --quiet --script live.py "$@"
