# Talk Talk Talk

<img src="macos/icon.png" width="96" alt="Talk Talk Talk icon">

Local, free text-to-speech for your Mac — a native menu bar app with a
floating status pill, global hotkeys, and automatic read-aloud of
**Claude Code**, **Codex CLI**, and **Cursor** responses. Everything runs
on-device using the open-weights
[Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) model: no API, no
account, no network calls after install.

## What you get

- **Speak anything, anywhere** — select text in any app and press `⌃⌥S`
- **A menu bar item** next to the clock, always there: the waveform mark,
  recoloured by state, and a menu with the transport controls, voice and
  speed pickers, and the auto-read / read-along toggles
- **A floating pill** with live state (loading / preparing / speaking /
  paused / replied), an animated waveform while speaking, and clickable
  AUTO / rewind / pause / stop buttons. Drag it anywhere; it remembers its
  top-right corner, so the position holds as the pill resizes with its
  label — and "Bring To Front" in the menu recovers it if it ends up
  off-screen or on a display you have since unplugged.
- **Agent responses read aloud** — when Claude Code, Codex, or Cursor
  finishes a response, the pill pops up with a play button, or speaks
  immediately in auto mode (`⌃⌥A`)
- **Real transport controls** — instant pause/resume (sample-exact) and
  10-second rollback to re-hear a section (`⌃⌥←`)
- **Read-along mode** — click `▾` and the pill drops a drawer showing each
  word as it is spoken, RSVP style with the ORP anchor letter highlighted
  and pinned so your eye never travels; see
  [docs/RSVP-SPEC.md](docs/RSVP-SPEC.md)
- **TLDR mode** — toggle it on and agent replies are summarised before they
  are read, via the Claude CLI (no key needed), the Claude or ChatGPT API
  (your key, kept in the Keychain), or a local no-AI extractive summariser.
  It is a switch (`⌃⌥T`, or the pill's TL;DR button), not a separate command:
  turn it on and longer text gets summarised first, whether you send it to
  speech or to the reader. Anything under ~70 words (a short paragraph) is
  read as-is — no call, no wait — and that threshold is settable in the menu.
  Summaries are cached for five minutes, so reading something in the reader
  and then deciding to hear it costs one provider call, not two, and the
  words you hear are the words you just read.
- **Silent reader** (`⌃⌥R`) — sends the selection to a full-screen reader
  instead of speaking it, dimming the whole screen down to a single
  centred word with its anchor letter pinned. Hold `R` to advance, release to
  hold. Speed and position live in the menu bar so nothing competes with the
  word. The reader takes focus and handles its own keys, so it can never
  swallow a keystroke system-wide.
- **Dictation-aware** — hold-Fn dictation tools (e.g. Wispr Flow) auto-pause
  speech while you talk and resume when you release
- **54 voices** across 9 languages, all local — pick one from the menu bar
  and it sticks
- **A CLI** for scripts and pipes: `ktts say`, `ktts clip`, `cat notes.md | ktts say -`

## Closing and reopening it

**Quit Talk Talk Talk** (bottom of the menu) releases the hotkeys, stops
every timer and watcher, and shuts the speech daemon down so it gives back
its ~600 MB. Reopen it from the Dock, `~/Applications`, or Spotlight.
**Start at login** in the same menu keeps it there across restarts.

The app is a menu bar app, so it holds no Dock tile of its own while
running — drag **~/Applications/Talk Talk Talk.app** to the Dock and the
icon stays there whether it is running or not.

The mark in the menu bar and on the pill is `macos/logo.png`, trimmed to
its ink at load time and flood-filled with the state colour, so the artwork
is the single source of truth rather than something redrawn in code.

`build-app.sh` signs with a real codesigning identity if you have one and
falls back to ad-hoc. Prefer an identity: ad-hoc reduces the designated
requirement to a bare `cdhash`, so every rebuild looks like a different app
to macOS and orphans the Accessibility grant.

If it ever misbehaves, `~/Library/Logs/TalkTalkTalk.log` records startup
(how many hotkeys were claimed, whether Accessibility was granted, which
engine directory it found) and any command the daemon refused.

## Requirements

macOS 13 or later on Apple Silicon or Intel, [Homebrew](https://brew.sh),
the Swift toolchain from the Command Line Tools (`xcode-select --install` —
a full Xcode is not needed), ~1 GB disk (model + venv), ~600 MB RAM while
the speech daemon is resident (`ktts quit` frees it; it restarts on next
use).

## Install

```bash
git clone https://github.com/ArranStrange/talk-talk-talk.git
cd talk-talk-talk
./install.sh
```

The installer: installs `espeak-ng` via Homebrew, creates a Python venv,
downloads the Kokoro model weights (~340 MB, Apache 2.0) from the official
[kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) release, links
`ktts` onto your PATH, builds and installs the app into `~/Applications`,
and runs a smoke test that executes the response hook rather than merely
compiling it. It then prints the manual steps: granting the app
Accessibility permission, and adding the hook snippets for Claude Code,
Codex or Cursor if you want agent responses staged.

Accessibility is needed for one thing only — speaking the *selection* works
by posting ⌘C to the frontmost app and reading the pasteboard, which is
exactly what that permission governs. The hotkeys themselves are registered
with the window server and work without it.

## Hotkeys

| Key | Idle / reply staged | While speaking |
|---|---|---|
| `⌃⌥S` | speak selected text | speak selection (replaces) |
| `⌃⌥P` | play staged reply | pause / resume |
| `⌃⌥←` | — | rewind 10 s |
| `⌃⌥X` | dismiss staged reply | stop |
| `⌃⌥A` | toggle auto-read | toggle auto-read |
| `⌃⌥R` | read the selection in the full-screen reader ||
| `⌃⌥T` | TLDR on/off — applies to both ||

The shortcut chooses where the text goes; TLDR only decides whether it is
summarised on the way. With TLDR on, the pill shows **Summarising…** for as
long as the provider takes, and `⌃⌥X` (or the pill's stop button) calls it
off — so a slow provider is visible and interruptible rather than a silent
wait.

In the reader: hold `R` to advance, `↑↓` speed, `←→` step a word, `esc` close.

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

## Reading structured text

Markdown is converted for the ear rather than stripped:

| Input | Read as |
|---|---|
| `## Heading` | its own sentence, followed by a longer pause |
| Tables | one sentence per row — "Process: main server, Raises: 5" |
| Short code (≤4 lines) | spoken, with identifiers made pronounceable |
| Longer code | "Code block, 12 lines of python" |
| `` `raiseThrottled()` `` | "raise Throttled" |
| Bare URLs | "link to github.com" |
| List items | a sentence each, so they do not blur together |

Paragraph, heading, table and code boundaries get a 420 ms pause; sentences
within a paragraph get 120 ms. That pacing is what makes a long document
navigable by ear.

## TLDR providers

| Provider | Cost | Speed | Setup |
|---|---|---|---|
| `claude-cli` (default) | none, draws on your Claude plan allowance | ~11–20 s | none |
| `anthropic` | ~$0.004 per 2,000 words on Haiku | ~2 s | `ttt-set-key anthropic` |
| `openai` | comparable, model-dependent | ~2 s | `ttt-set-key openai` |
| `extractive` | free, offline | instant | none |

`ttt-set-key` types your key straight into `security`, which prompts for it
without echoing, so the key never appears in a command line, shell history,
config file or log. It is read back from the Keychain at call time, and
`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` work as a fallback.

## How it works

```
Claude Code Stop hook ──┐
Codex notify hook ──────┤  stage text →  pending.txt + state file
Cursor afterAgentResponse ┤
                        │
ktts (CLI) ─────────────┤  unix socket
                        ▼
              kokoro daemon (venv)       Talk Talk Talk.app (Swift)
              · model resident in RAM    · FSEvents on the state file
              · synthesizes per-sentence · draws the pill + waveform
              · streams via CoreAudio    · Carbon hotkeys, Fn watcher
              · pause = stop feeding     · writes to the socket directly
              · rollback = move cursor   · NSStatusItem menu, RSVP reader
```

The app talks to the daemon over its unix socket rather than shelling out
to `ktts`, so a button press costs a socket write instead of a Python
interpreter start.

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
rm -rf ~/Applications/"Talk Talk Talk.app"
rm "$(brew --prefix)/bin/ktts" "$(brew --prefix)/bin/ttt-set-key"
defaults delete com.talktalktalk.app
# remove the hook snippets from ~/.claude/settings.json, ~/.codex/config.toml
# and ~/.cursor/hooks.json, then delete this repo folder
```

## Credits & license

- [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) by hexgrad —
  Apache 2.0 open-weights TTS model
- [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) by thewh1teagle —
  ONNX runtime port and model releases
- Code in this repo: MIT license (see LICENSE)
