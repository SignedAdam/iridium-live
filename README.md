# Iridium Live

Dictation for macOS. Speech recognition runs on your Mac, on the GPU, with
[Phonon-2](https://huggingface.co/FermionResearch/Phonon-2).

![Captions at the top of the screen, the control writing a note](docs/hero.png)

## Features

- **Captions** at the top or bottom of the screen.
- **Typing** into any app. Words are corrected in place when recognition changes its mind.
- **Notes.** Dictate into a note, edit it like any text, keep it in My notes.
- **Hotkeys.** Hold, double-tap or toggle. Several per key.
- **WhatsApp and Telegram.** A record button in the chat window. Stream types while you talk. Collect inserts one
  message at the end, and can send it.
- **AI cleanup** (optional). Groq or OpenRouter removes fillers, formats numbers, dates and links. Custom
  instructions.
- **Corrections.** Say "I mean Wednesday" and the earlier sentence changes, wherever it was typed. Same recording,
  last 2 sentences by default.
- **Quotes** (optional). "Quote … end quote" becomes quotation marks.
- **History.** Every phrase, searchable, with timing and cost.
- **Menu bar icon.** Record, show or hide the control, quit.

![WhatsApp with the Iridium button and the dictation panel](docs/chat.png)

![History with a phrase's timeline, and the cleanup settings](docs/panes.png)

## Numbers

M1 Max, 32 GB.

| | |
|---|---|
| Speed | 79x realtime |
| Word error rate | 8.18% (Open ASR Leaderboard, 300 clips) |
| Phonon-2 vs Parakeet TDT v3 | 9.28% vs 9.27% word error rate, 86x vs 58x realtime |
| End of a phrase | 0.7 s of silence |
| Cleanup, Groq with Qwen3.8 27B | 143 ms median |
| Memory | 1.0 GB loaded, 0.5 GB unloaded |

English only.

## Install

Apple silicon, macOS 26, Xcode command line tools, [uv](https://docs.astral.sh/uv/).

```sh
make install   # build, copy to /Applications
make run       # run from the terminal
make check     # print resolved paths
make cert      # local signing certificate: permissions survive rebuilds
```

First launch asks for Microphone and Accessibility. API keys are optional and go in the login keychain. The speech
model (about 1 GB) downloads on first use.

## Privacy

- Audio stays on your Mac. Recordings are saved only with *Save audio* on.
- With AI cleanup on, text goes to Groq or OpenRouter: the phrase, earlier phrases of the recording, the end of the
  current note.

## Files

`~/Library/Application Support/Iridium Live`

| | |
|---|---|
| `notes.txt` | unsaved note |
| `Notes/` | saved notes |
| `journal.txt` | every dictated phrase |
| `backups/` | earlier versions of notes |
| `history.jsonl` | phrases with timing |
| `usage.jsonl` | model calls: tokens, cost, latency |
| `Recordings/` | audio, with *Save audio* on |
| `chat-apps.json` | chat app settings |

Engine log: `~/Library/Logs/Iridium Live/engine.log`

## Code

| | |
|---|---|
| `Sources/` | the app, SwiftUI |
| `live.py` | the engine, Python on MLX. Runs as a child process, JSON lines over stdin and stdout. Protocol at the top. |
| `segmenter.py` | voice detection, phrases |
| `asr.py` | Phonon-2 and Parakeet |
| `cleanup.py` | Groq and OpenRouter |
| `archive.py` | audio archive |
| `downloads.py` | model downloads |

## Credits

- [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) by Fermion Research (CC-BY-4.0), from NVIDIA's
  [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0)
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT)
- [mlx-audio](https://github.com/Blaizzy/mlx-audio) (MIT)
- [TikTok Sans](https://github.com/tiktok/TikTokSans) (SIL Open Font License, in `fonts/`)
