# Iridium Live

Talk, and the words land where you are already looking.

![Iridium Live: live captions across the top of the screen while the control writes a note](docs/hero.png)

Iridium Live is dictation for the Mac that keeps up with speech. A small glass control floats over every Space.
Press record and your words come back as captions across the screen, collect in a note, or type themselves into
whatever app is in front of you. Speech recognition runs on your Mac, on the GPU, with
[Phonon-2](https://huggingface.co/FermionResearch/Phonon-2). Your voice never leaves the machine.

## Talk anywhere

**One control, always within reach.** Record, an input meter, the elapsed time, then switches for typing, notes,
history and settings. A line above the bar says where the words are going: "Writing to notes", "Typing into Safari",
and "Finishing" while the last of a long take is still being transcribed. The control floats on every Space, never
takes focus, and you drag it from anywhere that is not a button. It stays where you leave it across restarts, and
near the top of the screen it opens downward instead of up. Right-click for its menu.

**Live captions** at the top or the bottom of the screen, with the font, size, opacity and how long they stay all
yours to set. Long phrases show their newest words.

**Typing into any app.** Words go in once they have held steady for a moment, and are corrected in place if the model
changes its mind about what it heard. How long to wait is a slider, from 0.2 s to 3 s.

**Hotkeys, as many as you like**, and several on the same key. Each one types what you say or adds it to your notes,
and works by hold, by double-tap, or as a toggle. A hold on a key that also taps starts recording at once and drops
it again if the key comes straight back up. A lone modifier such as right Command counts only when pressed by
itself, so Command-C still copies.

## Notes that keep up

Notes open out of the bar and grow as you talk. They are ordinary editable text: Command-C, Command-V, Command-Z and
the rest all work, and dictated phrases never land in your undo history, so Command-Z steps back through what *you*
typed. Right-click for the notes' own menu: save the note, save the selection as a note of its own, start a new one,
clean the whole note up with the model, or open **My notes**, where every note you have kept is a file you can
rename, star, export or open in Finder.

Nothing is lost. The open note is written to disk within 0.3 s of a change and again on quit, every dictated phrase
also goes into an append-only journal, and earlier versions are backed up whenever a lot of text disappears at once.
Each note remembers which phrases went into it, and which stretches of saved audio they came from.

## A button in your chat apps

![A messenger with the Iridium button beside Send and the dictation panel above the message box](docs/chat.png)

With WhatsApp or Telegram in front, a small Iridium button appears beside that app's own Send button, in that app's
colours. Hold it to talk, or click once and click again to stop. While you talk, a panel sits just above the message
box with the time, the level and the words so far, and it never covers the box, so you can keep typing there.

Each app decides what dictation does: **Stream** types the words into the box as you speak, **Collect** gathers them
and puts in one polished message at the end. Either can press Send for you. Where the button and the box are comes
from `chat-apps.json`, measured from a corner of the app's window, so moving or resizing the window changes nothing.
**Detect** reads those numbers out of the app once, by itself.

## Cleanup that is fast, and honest about what it costs

Switch on AI cleanup and a language model removes fillers, applies spoken corrections ("no wait, Thursday"), and
writes numbers, money, dates, emails and URLs the way they are written rather than said. It never answers, explains
or adds. It runs at [Groq](https://groq.com) or [OpenRouter](https://openrouter.ai), so it costs your Mac no memory
at all.

- Every phrase is cleaned with what you already said in this recording, and the note you are dictating into, in
  front of it, so a correction can reach back a sentence.
- When you stop, the whole recording goes through the model once more. The result replaces exactly what was added to
  the note, and corrects what was typed elsewhere as long as you have not touched it since.
- A phrase with nothing to fix never reaches the model.
- Your own instructions go under the fixed rules, wherever cleanup runs.
- Anything slow, failed or implausible hands the raw phrase back. You get your words either way.

## See everything

![History with one phrase's timeline open, and settings at the AI cleanup section with a model's card](docs/panes.png)

**History** keeps every phrase, grouped by day, searchable, with each day's cleanup cost in the header. Click one for
its full timeline: the pause before it was sent on, transcription, then cleanup split into network, the provider's
own queue, reading the prompt and writing, with tokens and cost, then the pass over the whole recording, and what it
was heard as before cleanup.

**Benchmarks.** Switch on *Benchmark other models* and every other model at your provider answers each phrase too,
in the background, after yours has been typed. The timeline then shows what each of them made of it, with the words
they wrote differently marked, and every model's card carries both the measured benchmark and how it has done for
you: median, slowest tenth, tokens per phrase and what you have spent.

**A token log.** Every model call is appended to `usage.jsonl` with its tokens, cost, latency and the phrase it
belongs to, ready for a ledger to read.

**Memory you can see.** The control turns red when the Mac runs low, and one click unloads the models. They can also
unload by themselves after anything from 5 minutes to 6 hours unused, and reload the next time you record.

## The numbers

Measured on an M1 Max (32 GB).

| | |
|---|---|
| Phonon-2 against Parakeet TDT v3 (Core ML via FluidAudio), 1,500 Open ASR Leaderboard clips | 86x vs 58x realtime, 9.28% vs 9.27% average word error rate, with Fermion's fp16 runtime. Phonon-2 is English only. |
| The packed runtime Iridium Live actually runs, to save memory, on 300 of those clips | 8.18% word error rate, 79x realtime |
| Live captions | the phrase is transcribed again every 0.12 s of speech: about 20 ms a pass for a short phrase, 45 ms at 2 s, 80 ms at 6 s |
| End of a phrase | 0.7 s of silence closes it. Silero voice detection decides what counts as speech, so key clicks are never transcribed. |
| AI cleanup, 40 dictated phrases | Groq with Qwen3.8 27B: 143 ms median, 251 ms at the slowest tenth, right in substance on 37 of them |
| Memory | about 1.0 GB with Phonon-2 loaded, 0.5 GB after *Unload models*. Cleanup over the network adds none. |

## Install

Requirements: an Apple silicon Mac, macOS 26, the Xcode command line tools, and
[uv](https://docs.astral.sh/uv/).

```sh
make install           # build Iridium Live.app and put it in /Applications
make                   # just build, into .build/
make run               # build if needed, then run it from this terminal
make run WAV=clip.wav  # Record plays a file instead of the microphone
make check             # print the paths the app resolves (engine, uv, font)
```

Everything the app runs on rides inside the bundle: the engine scripts, the font, the icon. It finds `uv` in the
usual install paths, so it works launched from Finder with no shell behind it. The speech model downloads itself the
first time it is needed, with progress in Settings.

On its first launch the app opens a setup window: the microphone, Accessibility (which typing and hotkeys need), your
Groq and OpenRouter keys, and whether it opens at login. Keys are kept in the login keychain. The keys can wait (Set up
later): dictation works without them, and everything else is skippable too. The same rows live in Settings under
**Setup**.

A waveform in the menu bar (red while recording) opens the app's menu: start or stop recording, show or hide the
floating control, notes, history, settings, unload the models, and quit.

One optional extra. Without a code-signing certificate the app is signed ad-hoc, and an ad-hoc signature changes with
every build, so macOS treats each build as a new app and asks for the microphone and Accessibility grants again.

```sh
make cert
```

creates a self-signed code-signing certificate, "Iridium Live Dev", in your login keychain, once. Every build then
carries the same identity and the grants stick. It asks for your login password, because macOS will not trust a
certificate without one. To undo it, delete the certificate in Keychain Access, or run:

```sh
security delete-certificate -c "Iridium Live Dev" -t ~/Library/Keychains/login.keychain-db
```

## Privacy

Your audio and your speech recognition never leave the Mac. Phonon-2 runs on the GPU in a child process of the app;
nothing is uploaded, and the recording is only written to disk if you switch *Save audio* on.

If you switch AI cleanup on, text goes out: the phrase, the phrases before it in the same recording, and the end of
the note you are dictating into, to Groq or OpenRouter, so the model can fix a correction that reaches back a
sentence. With cleanup off, nothing leaves at all. Your API keys live in the login keychain under the app's bundle
id and are handed to the engine in its environment.

## How it is built

The app (`Sources/`, SwiftUI) draws the control, captions, notes, history and settings, types into other apps, and
watches the hotkeys. The engine (`live.py`, Python on MLX) runs as the app's child process. The two talk in JSON
lines over stdin and stdout; the protocol is written out at the top of `live.py`.

| File | Role |
|---|---|
| `segmenter.py` | Silero voice detection and phrase segmentation |
| `asr.py` | Phonon-2 (packed) and Parakeet behind one MLX runtime, with Fermion's fast TDT decoder |
| `cleanup.py` | AI cleanup at Groq or OpenRouter |
| `archive.py` | the audio archive: WAV files split at pauses, in folders by date |
| `downloads.py` | model downloads, with progress |

Your data lives in `~/Library/Application Support/Iridium Live`:

| | |
|---|---|
| `notes.txt` | the unsaved note |
| `Notes/` | every saved note as a file named after it, with `index.json` beside them |
| `journal.txt` | every dictated phrase, appended |
| `backups/` | earlier versions of a note |
| `history.jsonl` | every phrase, with its timing |
| `usage.jsonl` | one line per model call: tokens, cost, latency |
| `Recordings/` | only when *Save audio* is on |
| `chat-apps.json` | the chat apps: rectangles, colours and switches, safe to edit by hand |

## Credits

- [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) by Fermion Research (CC-BY-4.0), derived from NVIDIA's
  [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0).
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT).
- [mlx-audio](https://github.com/Blaizzy/mlx-audio) (MIT).
- [TikTok Sans](https://github.com/tiktok/TikTokSans) (SIL Open Font License, included in `fonts/`).
