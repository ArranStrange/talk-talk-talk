#!/bin/bash
# Talk Talk Talk installer — macOS only.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
KOKORO="$REPO/kokoro"
MODEL_BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
APPDIR="$HOME/Applications/Talk Talk Talk.app"
BUNDLE_ID="com.talktalktalk.app"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Talk Talk Talk is macOS-only."
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

# --- 5. Model weights (Apache 2.0, ~340 MB total) ------------------------------
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  if [ ! -f "$KOKORO/$f" ]; then
    say "Downloading $f"
    curl -L --progress-bar -o "$KOKORO/$f" "$MODEL_BASE/$f"
  else
    say "$f already present"
  fi
done

# --- 6. ktts on PATH ------------------------------------------------------------
chmod +x "$KOKORO/ktts" "$KOKORO/daemon.py" "$KOKORO/speak_response.py" \
         "$KOKORO/codex_notify.py" "$KOKORO/cursor_notify.py" \
         "$KOKORO/tldr.py" "$KOKORO/ttt-set-key"
BIN="$(brew --prefix)/bin"
say "Linking $BIN/ktts"
ln -sf "$KOKORO/ktts" "$BIN/ktts"
ln -sf "$KOKORO/ttt-set-key" "$BIN/ttt-set-key"

# --- 7. The app ----------------------------------------------------------------
say "Building Talk Talk Talk.app"
"$REPO/macos/TalkTalkTalk/build-app.sh" >/dev/null \
  || die "the app failed to build — run macos/TalkTalkTalk/build-app.sh to see why"
BUILT="$REPO/macos/TalkTalkTalk/build/Talk Talk Talk.app"
[ -d "$BUILT" ] || die "no app bundle at $BUILT"

# Replacing a running copy leaves the old process holding the hotkeys.
pkill -f "Talk Talk Talk.app/Contents/MacOS/TalkTalkTalk" 2>/dev/null || true
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
grep -q "smoke test" "$KOKORO/pending.txt" 2>/dev/null \
  || die "the response hook ran but staged nothing"
rm -rf "$HOOKTMP"
printf 'idle' > "$KOKORO/state"
say "Hook OK"

say "Smoke test (first run loads the model, ~3s)"
"$BIN/ktts" say "Talk talk talk is installed." || die "smoke test failed — see $KOKORO/daemon.log"

open "$APPDIR"

cat <<EOF

────────────────────────────────────────────────────────────────────────
Talk Talk Talk is installed and running — look for the ◍ next to the clock.

Remaining manual steps:

1. Grant Accessibility permission to **Talk Talk Talk** in
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
Log:     ~/Library/Logs/TalkTalkTalk.log
────────────────────────────────────────────────────────────────────────
EOF
