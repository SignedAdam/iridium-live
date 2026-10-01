# PhononLive

Fast, private dictation for the Mac. Speak, and your words show up as live captions, collect in your notes, or get typed straight into whatever app you are in. Everything runs on your Mac: [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) transcribes on the GPU.

![PhononLive: live captions and notes over a gradient wallpaper](docs/hero.png)

## What it does

- **One floating glass control.** Record, a live input meter and the elapsed time, then switches for typing, notes, history and settings. Hovering a button names it at once. The control floats on every Space, never takes focus, and you can drag it from anywhere that isn't a button.
- **Live captions** at the top or bottom of the screen. Font, size, opacity and how long they stay are all adjustable.
- **Notes** open upward out of the bar and grow as you talk, then scroll. You can edit them like any text: ⌘C, ⌘V, ⌘Z and the rest work, and dictated phrases never land in your undo history.
- **Typing into any app.** Words are typed once they have held steady for a moment (adjustable), and corrected in place if the model changes its mind.
- **Hotkeys**, as many as you like. Each one either types what you say or adds it to your notes, and works as press to toggle, hold to talk, or both (hold to talk, double-tap to stay on). A lone modifier such as right ⌘ counts only when pressed by itself, so ⌘C still copies.
- **History** of every phrase, grouped by day and searchable. Click a phrase to copy it; hover or right-click to delete it.
- **Optional AI cleanup.** A language model removes fillers, applies spoken corrections ("no wait…"), and formats numbers, dates, money and email addresses. It runs on [Groq](https://groq.com) (`GROQ_API_KEY`) or [OpenRouter](https://openrouter.ai) (`OPENROUTER_API_KEY`), which costs your Mac no memory, or on the Mac itself with a small local model. Phrases that are already clean skip the model, and if a request fails or takes over 2.5 s, the phrase goes out as heard.
- **Optional audio archive.** Recordings are saved as WAV files, split at pauses of a length you choose, into folders by date.
- **Memory you can see.** The control turns red when the Mac runs low, and one click unloads the models. They reload by themselves the next time you record.
- **Notes are never lost.** Every change is saved within 0.3 s and again on quit. Each dictated phrase also goes into an append-only journal, and earlier versions are backed up whenever a lot of text disappears at once.

![Settings and history](docs/panes.png)

## Speed and accuracy

Measured on an M1 Max (32 GB):

| | |
|---|---|
| Phonon-2 against Parakeet TDT v3 (Core ML via FluidAudio), 1,500 Open ASR Leaderboard clips | 86× vs 58× realtime, 55 ms vs 104 ms median per clip, 9.28% vs 9.27% average word error rate, with fermion's fp16 runtime. Phonon-2 is English only. |
| Packed runtime (what PhononLive runs, to save memory), 300 of those clips | same word error rate as fp16 (8.18%), 79× realtime instead of 116× |
| Live captions | the phrase is re-transcribed every 0.12 s of speech: about 20 ms per pass for a short phrase, 45 ms at 2 s, 80 ms at 6 s |
| End of a phrase | 0.7 s of silence closes it. Silero voice detection decides what counts as speech, so key clicks are never transcribed. |
| AI cleanup per phrase, 40 dictated phrases | Groq with Qwen3.8 27B: 143 ms median, 251 ms p90. Qwen3 4B on this Mac: 306 ms median. Phrases that are already clean skip the model. |
| Memory | about 1.0 GB with Phonon-2 (0.8 GB right after it loads), 0.5 GB after *Unload models*. Local Qwen3 4B cleanup adds about 2.5 GB; cleanup through an API adds nothing. |

On this Mac, the cleanup borrows Wispr Flow's playbook:

- **Small model, fixed instructions kept loaded.** The instructions and examples are processed once and kept in memory, so each request only processes your phrase.
- **Guessing ahead from your own words.** The rewrite mostly copies what you said, so the next few words are proposed from your phrase and checked in a single step. Decoding is greedy, so the result is the same text normal generation would give.
- **Skipping clean phrases.** A phrase with nothing to fix never reaches the model.

## Run it

Requirements: an Apple silicon Mac, the Xcode command line tools (`swiftc`, `make`) and [uv](https://docs.astral.sh/uv/). Developed on macOS 26.

```sh
make run               # builds the app when a source changed, then starts it
make run WAV=clip.wav  # Record plays a file instead of the microphone
make                   # build only
```

Models download by themselves the first time they are needed, with progress shown in Settings. The terminal you start it from needs microphone access, plus Accessibility access for typing and hotkeys. macOS asks the first time.

## How it is built

- **The app** (`Sources/`, SwiftUI) draws the control, captions, notes, history and settings, types into other apps, and watches the hotkeys.
- **The engine** (`live.py`, Python on MLX) runs as the app's child process. The two talk in JSON lines over stdin/stdout; the protocol is described at the top of `live.py`.

| File | Role |
|---|---|
| `segmenter.py` | Silero voice detection and phrase segmentation |
| `asr.py` | Phonon-2 (packed) and Parakeet behind one MLX runtime, using Fermion's fast TDT decoder |
| `cleanup.py` | the AI cleanup: Groq, OpenRouter, or a local model |
| `archive.py` | the audio archive |
| `downloads.py` | model downloads with progress |

Your data lives in `~/Library/Application Support/PhononLive`:

- `notes.txt`
- `journal.txt` (every dictated phrase)
- `backups/`
- `history.jsonl`
- `Recordings/` (only when Save audio is on)

## Credits

- [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) by Fermion Research (CC-BY-4.0), derived from NVIDIA's [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC-BY-4.0).
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT).
- [Qwen3 4B Instruct](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507) (Apache-2.0) and [Llama 3.2 3B Instruct](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct) (Llama 3.2 Community License), via [mlx-lm](https://github.com/ml-explore/mlx-lm).
- [TikTok Sans](https://github.com/tiktok/TikTokSans) (SIL Open Font License, included in `fonts/`).
