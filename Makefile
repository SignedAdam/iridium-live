# Iridium Live.
#   make                     build the app (only when a source changed)
#   make run                 build if needed, then start it on the MacBook microphone
#   make run WAV=clip.wav    Record plays the file at real time instead, through the same path
#   make clean               remove the build
# Start it from a terminal that has microphone access; typing and hotkeys also need Accessibility access for that
# terminal. macOS asks the first time. Ctrl-C quits (notes and history are saved first).

APP := .build/IridiumLive
SOURCES := $(wildcard Sources/*.swift)

$(APP): $(SOURCES)
	@mkdir -p $(@D)
	swiftc -O -swift-version 6 $(SOURCES) -o $@

.PHONY: run clean

run: $(APP)
	$(APP) fonts/TikTokSans.ttf uv run --quiet --script live.py $(if $(WAV),--wav "$(WAV)")

clean:
	rm -rf .build
