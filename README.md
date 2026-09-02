# Talk Talk Talk 🗣

Local, free text-to-speech for your Mac — with a floating status pill,
global hotkeys, and automatic read-aloud of **Claude Code**, **Codex CLI**,
and **Cursor** responses. Everything runs on-device using the open-weights
[Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) model: no API, no
account, no network calls after install.

## What you get

- **Speak anything, anywhere** — select text in any app and press `⌃⌥S`
- **A menu bar item** next to the clock, always there: a status glyph that
  changes colour with state, and a menu with the transport controls, voice
  and speed pickers, and the auto-read / read-along toggles
- **A floating pill** with live state (loading / preparing / speaking /
  paused / replied), an animated waveform while speaking, and clickable
  AUTO / rewind / pause / stop buttons. Drag it anywhere; it remembers.
- **Agent responses read aloud** — when Claude Code, Codex, or Cursor
  finishes a response, the pill pops up with a play button, or speaks
  immediately in auto mode (`⌃⌥A`)
- **Real transport controls** — instant pause/resume (sample-exact) and
  10-second rollback to re-hear a section (`⌃⌥←`)
- **Read-along mode** — click `▾` and the pill drops a drawer showing each
  word as it is spoken, RSVP style with the ORP anchor letter highlighted
  and pinned so your eye never travels; see
  [docs/RSVP-SPEC.md](docs/RSVP-SPEC.md)
- **Silent RSVP reader** (`⌃⌥R`) — select text and read it word-by-word with
  no audio at all: hold `R` to advance, release to hold, `↑`/`↓` for speed
- **Dictation-aware** — hold-Fn dictation tools (e.g. Wispr Flow) auto-pause
  speech while you talk and resume when you release
- **54 voices** across 9 languages, all local — pick one from the menu bar
  and it sticks
- **A CLI** for scripts and pipes: `ktts say`, `ktts clip`, `cat notes.md | ktts say -`

## Requirements

macOS on Apple Silicon or Intel, [Homebrew](https://brew.sh), ~1 GB disk
(model + venv), ~600 MB RAM while the speech daemon is resident
(`ktts quit` frees it; it restarts on next use).

## Install

```bash
git clone https://github.com/ArranStrange/talk-talk-talk.git
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
| `⌃⌥R` | silent RSVP reader on the selection (hold `R` to read, `↑↓` speed, `←→` step, `esc` close) ||

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
Cursor afterAgentResponse ┤
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
~2–2.5 s with several seconds of audio already banked). Playback is a
single in-memory sample buffer with a cursor, so pause is instant and
rollback is seeking — no re-synthesis.

Audio is written to PortAudio with **blocking writes from an ordinary
thread, deliberately not a PortAudio callback**. A Python callback has to
take the GIL on the audio clock's schedule, and the onnxruntime synthesis
threads starve it — measured as 200 ms gaps on an 85 ms deadline, occurring
only while synthesis was still running, which is exactly when the audio
sounded rough. `write()` blocks in C with the GIL released instead, so
PortAudio's own buffer covers any stall on the Python side.

Chunks are also capped small enough (~140 chars) that rendering the next
one always finishes before the cushion in hand runs out; a larger cap meant
one big chunk took longer to synthesize than the audio already buffered,
which starved playback a few seconds in and then never again — the classic
"rough at the start, then it settles" complaint. Synthesis runs on the
performance cores (capped at 8 threads, override with `KOKORO_THREADS`) at
roughly 3× realtime.

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
