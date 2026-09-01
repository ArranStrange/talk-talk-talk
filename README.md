# Talk Talk Talk 🗣

Local, free text-to-speech for your Mac — with a floating status pill,
global hotkeys, and automatic read-aloud of **Claude Code** and **Codex CLI**
responses. Everything runs on-device using the open-weights
[Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) model: no API, no
account, no network calls after install.

## What you get

- **Speak anything, anywhere** — select text in any app and press `⌃⌥S`
- **A floating pill** with live state (loading / preparing / speaking /
  paused / replied), an animated waveform while speaking, and clickable
  AUTO / rewind / pause / stop buttons. Drag it anywhere; it remembers.
- **Agent responses read aloud** — when Claude Code or Codex finishes a
  response, the pill pops up with a play button, or speaks immediately in
  auto mode (`⌃⌥A`)
- **Real transport controls** — instant pause/resume (sample-exact) and
  10-second rollback to re-hear a section (`⌃⌥←`)
- **Dictation-aware** — hold-Fn dictation tools (e.g. Wispr Flow) auto-pause
  speech while you talk and resume when you release
- **54 voices** across 9 languages, all local
- **A CLI** for scripts and pipes: `ktts say`, `ktts clip`, `cat notes.md | ktts say -`

## Requirements

macOS on Apple Silicon or Intel, [Homebrew](https://brew.sh), ~1 GB disk
(model + venv), ~600 MB RAM while the speech daemon is resident
(`ktts quit` frees it; it restarts on next use).

## Install

```bash
git clone https://github.com/YOURNAME/talk-talk-talk.git
cd talk-talk-talk
./install.sh
```

The installer: installs `espeak-ng` and Hammerspoon via Homebrew, creates a
Python venv, downloads the Kokoro model weights (~340 MB, Apache 2.0) from
the official [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx)
release, links `ktts` onto your PATH, installs the Hammerspoon module, and
runs a smoke test. It then prints the two manual steps: granting
Hammerspoon Accessibility permission, and adding the hook snippets for
Claude Code / Codex if you want agent responses staged.

## Hotkeys

| Key | Idle / reply staged | While speaking |
|---|---|---|
| `⌃⌥S` | speak selected text | speak selection (replaces) |
| `⌃⌥P` | play staged reply | pause / resume |
| `⌃⌥←` | — | rewind 10 s |
| `⌃⌥X` | dismiss staged reply | stop |
| `⌃⌥A` | toggle auto-read | toggle auto-read |

## CLI

```
ktts say "text"      speak text (replaces anything playing)
ktts say -           speak stdin
ktts clip            speak the clipboard
ktts pause / resume / toggle
ktts back [secs]     roll back (default 10s)
ktts stop / status / quit
```

Voice, speed, and language via environment variables:

```bash
KOKORO_VOICE=bm_george KOKORO_SPEED=1.0 KOKORO_LANG=en-gb ktts say "Hello."
```

Voice IDs are prefixed by accent/gender: `af_`/`am_` American,
`bf_`/`bm_` British, plus Spanish, French, Italian, Portuguese, Hindi,
Japanese, and Mandarin sets — `af_heart` (default), `af_bella`, `bf_emma`,
and `bm_george` are good starting points. See the
[Kokoro voices list](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md).

## How it works

```
Claude Code Stop hook ──┐
Codex notify hook ──────┤  stage text →  pending.txt + state file
                        │
ktts (CLI / hotkeys) ───┤  unix socket
                        ▼
              kokoro daemon (venv)          Hammerspoon
              · model resident in RAM       · watches the state file
              · synthesizes per-sentence    · draws the pill + waveform
              · streams via CoreAudio       · hotkeys, drag, Fn watcher
              · pause = stop feeding        · buttons → ktts commands
              · rollback = move cursor
```

The daemon keeps the model warm (dispatch is ~40 ms; speech starts in
~1–1.5 s). Playback is a single in-memory sample buffer with a cursor, so
pause is instant and rollback is seeking — no re-synthesis.

## Uninstall

```bash
ktts quit
rm "$(brew --prefix)/bin/ktts" ~/.hammerspoon/talk_talk_talk.lua
# remove the require("talk_talk_talk") line from ~/.hammerspoon/init.lua
# remove the hook snippets from ~/.claude/settings.json / ~/.codex/config.toml
# then delete this repo folder
```

## Credits & license

- [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) by hexgrad —
  Apache 2.0 open-weights TTS model
- [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) by thewh1teagle —
  ONNX runtime port and model releases
- [Hammerspoon](https://www.hammerspoon.org) — macOS automation
- Code in this repo: MIT license (see LICENSE)
