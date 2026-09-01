#!/bin/bash
# Talk Talk Talk installer — macOS only.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
KOKORO="$REPO/kokoro"
MODEL_BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Talk Talk Talk is macOS-only."
command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"

# --- 1. Homebrew dependencies -----------------------------------------------
say "Checking espeak-ng (phonemizer)"
brew list espeak-ng >/dev/null 2>&1 || brew install espeak-ng

say "Checking Hammerspoon (hotkeys + pill UI)"
if [ ! -d "/Applications/Hammerspoon.app" ]; then
  brew install --cask hammerspoon
fi

# --- 2. Python 3.10+ ----------------------------------------------------------
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

# --- 3. Virtualenv -------------------------------------------------------------
if [ ! -x "$KOKORO/venv/bin/python" ]; then
  say "Creating venv and installing kokoro-onnx + sounddevice"
  "$PY" -m venv "$KOKORO/venv"
  "$KOKORO/venv/bin/pip" install --quiet --upgrade pip
  "$KOKORO/venv/bin/pip" install --quiet kokoro-onnx soundfile sounddevice
else
  say "venv already present"
fi

# --- 4. Model weights (Apache 2.0, ~340 MB total) ------------------------------
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  if [ ! -f "$KOKORO/$f" ]; then
    say "Downloading $f"
    curl -L --progress-bar -o "$KOKORO/$f" "$MODEL_BASE/$f"
  else
    say "$f already present"
  fi
done

# --- 5. ktts on PATH ------------------------------------------------------------
chmod +x "$KOKORO/ktts" "$KOKORO/daemon.py" "$KOKORO/speak_response.py" "$KOKORO/codex_notify.py"
BIN="$(brew --prefix)/bin"
say "Linking $BIN/ktts"
ln -sf "$KOKORO/ktts" "$BIN/ktts"

# --- 6. Hammerspoon module -------------------------------------------------------
say "Installing Hammerspoon module"
mkdir -p "$HOME/.hammerspoon"
sed "s|@@KOKORO_DIR@@|$KOKORO|" "$REPO/hammerspoon/talk_talk_talk.lua" \
  > "$HOME/.hammerspoon/talk_talk_talk.lua"
INIT="$HOME/.hammerspoon/init.lua"
if ! grep -q 'require("talk_talk_talk")' "$INIT" 2>/dev/null; then
  printf '\nrequire("talk_talk_talk")\n' >> "$INIT"
  say "Added require(\"talk_talk_talk\") to $INIT"
fi

# --- 7. Smoke test ---------------------------------------------------------------
say "Smoke test (first run loads the model, ~3s)"
"$BIN/ktts" say "Talk talk talk is installed." || die "smoke test failed — see $KOKORO/daemon.log"

cat <<'EOF'

────────────────────────────────────────────────────────────────────────
Talk Talk Talk is installed. Remaining manual steps:

1. Open Hammerspoon.app and grant it Accessibility permission
   (System Settings → Privacy & Security → Accessibility), then choose
   "Launch Hammerspoon at login" in its preferences. If it was already
   running, reload its config from the menu-bar hammer icon.

2. To stage Claude Code responses in the pill, add to ~/.claude/settings.json:

   "hooks": {
     "Stop": [{ "hooks": [{
       "type": "command",
       "command": "<REPO>/kokoro/speak_response.py",
       "async": true, "timeout": 30
     }]}]
   }

3. To stage Codex CLI responses, add to ~/.codex/config.toml:

   notify = ["<REPO>/kokoro/codex_notify.py"]

   (If notify was already set, copy its old value into
   <REPO>/kokoro/notify_forward.json as a JSON array to keep it working.)

4. To stage Cursor responses, add to ~/.cursor/hooks.json:

   {
     "version": 1,
     "hooks": {
       "afterAgentResponse": [
         { "command": "<REPO>/kokoro/cursor_notify.py" }
       ]
     }
   }

Hotkeys: ⌃⌥S speak selection · ⌃⌥P play/pause · ⌃⌥← rewind ·
         ⌃⌥X stop · ⌃⌥A auto-read toggle
────────────────────────────────────────────────────────────────────────
EOF
