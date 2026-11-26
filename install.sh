#!/bin/bash
# Bellow Flo installer — macOS only.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
KOKORO="$REPO/kokoro"
APPDIR="$HOME/Applications/Bellow Flo.app"
BUNDLE_ID="com.bellowflo.app"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Bellow Flo is macOS-only."
command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"

# --- 1. Homebrew dependencies -----------------------------------------------
say "Checking espeak-ng (phonemizer)"
brew list espeak-ng >/dev/null 2>&1 || brew install espeak-ng

# --- 2. Swift toolchain -------------------------------------------------------
# The UI is a native app, so a compiler is needed. Command Line Tools is
# enough; a full Xcode install is not.
if ! command -v swift >/dev/null 2>&1; then
  die "Swift is required to build the app. Install the Command Line Tools:
       xcode-select --install"
fi
say "Using $(swift --version 2>&1 | head -1)"

# --- 3. Python 3.10+ ----------------------------------------------------------
PY=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null; then
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
      PY="$(command -v "$candidate")"
      break
    fi
  fi
done
if [ -z "$PY" ]; then
  say "Installing Python via Homebrew"
  brew install python@3.13
  PY="$(brew --prefix)/bin/python3.13"
fi
say "Using $PY"

# --- 4. Virtualenv -------------------------------------------------------------
if [ ! -x "$KOKORO/venv/bin/python" ]; then
  say "Creating venv and installing kokoro-onnx + sounddevice"
  "$PY" -m venv "$KOKORO/venv"
  "$KOKORO/venv/bin/pip" install --quiet --upgrade pip
  "$KOKORO/venv/bin/pip" install --quiet kokoro-onnx soundfile sounddevice
else
  say "venv already present"
fi
# Dictation: Parakeet (speech to text) and Qwen (cleanup). MLX on Apple
# Silicon; ONNX + llama.cpp on Intel, the same runtime Windows uses.
# Ask the venv's own interpreter: `uname -m` says x86_64 in a Rosetta shell
# even on Apple Silicon, which would install the slow stack for no reason.
if [ "$("$KOKORO/venv/bin/python" -c 'import platform; print(platform.machine())')" = "arm64" ]; then
  say "Checking dictation packages (parakeet-mlx, mlx-lm)"
  "$KOKORO/venv/bin/pip" install --quiet parakeet-mlx mlx-lm
else
  say "Checking dictation packages (onnx-asr, llama-cpp-python)"
  "$KOKORO/venv/bin/pip" install --quiet onnx-asr llama-cpp-python
fi

# --- 5. User data and model weights --------------------------------------------
# Code stays here; config, dictionary, staged text and model weights live in
# ~/Library/Application Support/Bellow Flo. Carry them over from wherever the
# engine ran before (an older checkout, or this one before the split).
DATA="$("$KOKORO/venv/bin/python" "$KOKORO/bf_paths.py")"
say "Data folder: $DATA"
for OLD_ID in "$BUNDLE_ID" com.talktalktalk.app; do
  OLD_KOKORO="$(defaults read "$OLD_ID" kokoroDir 2>/dev/null || true)"
  if [ -n "$OLD_KOKORO" ] && [ -d "$OLD_KOKORO" ]; then
    "$KOKORO/venv/bin/python" "$KOKORO/bf_paths.py" migrate "$OLD_KOKORO"
  fi
done
"$KOKORO/venv/bin/python" "$KOKORO/bf_paths.py" migrate "$KOKORO"
# Kokoro (Apache 2.0, ~340 MB) and Silero VAD (MIT, 2 MB), if not carried over.
"$KOKORO/venv/bin/python" "$KOKORO/bf_paths.py" models

# The two dictation models are ~1.2 GB and ~2.5 GB and come from Hugging
# Face on first use anyway; fetching them here just means the first
# dictation is not a four-minute wait. Set BELLOWFLO_SKIP_MODELS=1 to defer.
if [ -z "${BELLOWFLO_SKIP_MODELS:-${TTT_SKIP_MODELS:-}}" ]; then
  say "Fetching dictation models (~3.7 GB, cached in ~/.cache/huggingface)"
  "$KOKORO/venv/bin/python" -c '
import sys; sys.path.insert(0, sys.argv[1])
import bf_paths, dictate_backends as b
cfg = bf_paths.load_config()
eng = b.choose(cfg)
eng.load_stt(cfg); eng.load_llm(cfg)
print("  ready:", eng.name)
' "$KOKORO"
fi

# --- 6. ktts on PATH ------------------------------------------------------------
chmod +x "$KOKORO/ktts" "$KOKORO/daemon.py" "$KOKORO/speak_response.py" \
         "$KOKORO/codex_notify.py" "$KOKORO/cursor_notify.py" \
         "$KOKORO/tldr.py" "$KOKORO/bellowflo-set-key"
BIN="$(brew --prefix)/bin"
say "Linking $BIN/ktts"
ln -sf "$KOKORO/ktts" "$BIN/ktts"
ln -sf "$KOKORO/bellowflo-set-key" "$BIN/bellowflo-set-key"

# --- 7. The app ----------------------------------------------------------------
say "Building Bellow Flo.app"
"$REPO/macos/BellowFlo/build-app.sh" >/dev/null \
  || die "the app failed to build — run macos/BellowFlo/build-app.sh to see why"
BUILT="$REPO/macos/BellowFlo/build/Bellow Flo.app"
[ -d "$BUILT" ] || die "no app bundle at $BUILT"

# Replacing a running copy leaves the old process holding the hotkeys.
pkill -f "Bellow Flo.app/Contents/MacOS/BellowFlo" 2>/dev/null || true
# Retire the copy installed under the app's previous name, Talk Talk Talk,
# carrying its preferences across. macOS ties the Accessibility grant to the
# bundle id, so that permission has to be granted again once.
OLD_APP="$HOME/Applications/Talk Talk Talk.app"
OLD_ID="com.talktalktalk.app"
pkill -f "Talk Talk Talk.app/Contents/MacOS/TalkTalkTalk" 2>/dev/null || true
if defaults read "$OLD_ID" >/dev/null 2>&1 && ! defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
  say "Carrying settings over from Talk Talk Talk"
  defaults export "$OLD_ID" - | defaults import "$BUNDLE_ID" -
fi
if [ -d "$OLD_APP" ]; then
  say "Removing the old Talk Talk Talk.app"
  rm -rf "$OLD_APP"
fi
[ -L "$BIN/ttt-set-key" ] && rm -f "$BIN/ttt-set-key"
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$APPDIR"
cp -R "$BUILT" "$APPDIR"
# The app needs to know where the engine lives; the repo can be anywhere.
defaults write "$BUNDLE_ID" kokoroDir "$KOKORO"
say "Installed $APPDIR"

# --- 8. Smoke tests --------------------------------------------------------------
# Run the hook, do not merely byte-compile it: a missing function is a
# NameError at call time, which compiling never catches, and a hook that
# crashes stages nothing and looks exactly like "auto-read stopped working".
say "Checking the response hook actually runs"
HOOKTMP="$(mktemp -d)"
cat > "$HOOKTMP/t.jsonl" <<'JSONL'
{"type":"user","message":{"content":"hi"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"## Heading\n\nA sentence for the smoke test."}]}}
JSONL
printf '{"session_id":"smoke","transcript_path":"%s/t.jsonl","hook_event_name":"Stop"}' "$HOOKTMP" \
  | "$KOKORO/speak_response.py" || die "the response hook failed to run"
grep -q "smoke test" "$DATA/pending.txt" 2>/dev/null \
  || die "the response hook ran but staged nothing"
rm -rf "$HOOKTMP"
printf 'idle' > "$DATA/state"
say "Hook OK"

say "Smoke test (first run loads the model, ~3s)"
"$BIN/ktts" say "Bellow Flo is installed." || die "smoke test failed — see $DATA/daemon.log"

open "$APPDIR"

cat <<EOF

────────────────────────────────────────────────────────────────────────
Bellow Flo is installed and running — look for the ◍ next to the clock.

Remaining manual steps:

1. Grant Accessibility permission to **Bellow Flo** in
   System Settings → Privacy & Security → Accessibility.
   Speaking the selection works by copying it, and posting a ⌘C to
   another app is what that permission governs. The hotkeys themselves
   work without it.

2. Menu bar → "Start at login" if you want it there after a restart.

3. Drag $APPDIR to the Dock to have it one click away.

4. To stage Claude Code responses, add to ~/.claude/settings.json:

   "hooks": {
     "Stop": [{ "hooks": [{
       "type": "command",
       "command": "$KOKORO/speak_response.py",
       "async": true, "timeout": 30
     }]}]
   }

5. To stage Codex CLI responses, add to ~/.codex/config.toml:

   notify = ["$KOKORO/codex_notify.py"]

6. To stage Cursor responses, add to ~/.cursor/hooks.json:

   { "version": 1, "hooks": { "afterAgentResponse": [
       { "command": "$KOKORO/cursor_notify.py" } ] } }

Hotkeys: ⌃⌥S speak selection · ⌃⌥P play/pause · ⌃⌥← rewind ·
         ⌃⌥X stop · ⌃⌥A auto-read · ⌃⌥R reader · ⌃⌥T TL;DR
Dictate: hold Right ⌥ and talk; release to paste. Change the key, or
         turn cleanup off, under Dictation in the menu. macOS will ask
         for microphone access the first time.
Log:     ~/Library/Logs/BellowFlo.log
────────────────────────────────────────────────────────────────────────
EOF
