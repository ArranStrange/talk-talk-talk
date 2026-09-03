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
chmod +x "$KOKORO/ktts" "$KOKORO/daemon.py" "$KOKORO/speak_response.py" \
         "$KOKORO/codex_notify.py" "$KOKORO/cursor_notify.py" \
         "$KOKORO/tldr.py" "$KOKORO/ttt-set-key"
BIN="$(brew --prefix)/bin"
say "Linking $BIN/ktts"
ln -sf "$KOKORO/ktts" "$BIN/ktts"
ln -sf "$KOKORO/ttt-set-key" "$BIN/ttt-set-key"

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

# --- 7. Dock launcher ----------------------------------------------------------
say "Creating the Talk Talk Talk launcher in ~/Applications"
APPDIR="$HOME/Applications/Talk Talk Talk.app"
mkdir -p "$APPDIR/Contents/MacOS"
cat > "$APPDIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Talk Talk Talk</string>
  <key>CFBundleDisplayName</key><string>Talk Talk Talk</string>
  <key>CFBundleIdentifier</key><string>com.talktalktalk.launcher</string>
  <key>CFBundleExecutable</key><string>talk-talk-talk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
cat > "$APPDIR/Contents/MacOS/talk-talk-talk" <<'LAUNCH'
#!/bin/bash
# Brings the Hammerspoon-hosted UI back after "Quit Talk Talk Talk".
INIT="$HOME/.hammerspoon/init.lua"
HS_CLI=""
for c in /opt/homebrew/bin/hs /usr/local/bin/hs; do
  [ -x "$c" ] && HS_CLI="$c" && break
done
if ! pgrep -x Hammerspoon >/dev/null 2>&1; then
  open -a Hammerspoon
  exit 0
fi
# Reload re-runs the module's setup without restarting Hammerspoon. Deferred
# on purpose: hs.reload() tears down the IPC channel, so a direct call never
# answers and the client hangs waiting for a reply that cannot come.
if [ -n "$HS_CLI" ]; then
  "$HS_CLI" -c 'hs.timer.doAfter(0.3, hs.reload)' >/dev/null 2>&1 &
  sleep 2
  pgrep -x Hammerspoon >/dev/null 2>&1 && exit 0
fi
killall Hammerspoon 2>/dev/null
sleep 1
open -a Hammerspoon
LAUNCH
chmod +x "$APPDIR/Contents/MacOS/talk-talk-talk"

# Icon: macos/icon.png rendered into the ten sizes macOS asks for. Skipped
# quietly if the tools are missing — a bundle with no icon still launches.
if command -v iconutil >/dev/null 2>&1 && [ -f "$REPO/macos/icon.png" ]; then
  say "Building the app icon"
  ISET="$(mktemp -d)/icon.iconset"
  mkdir -p "$ISET" "$APPDIR/Contents/Resources"
  while read -r px name; do
    [ -n "$px" ] || continue
    sips -z "$px" "$px" "$REPO/macos/icon.png" \
      --out "$ISET/icon_$name.png" >/dev/null 2>&1
  done <<'SIZES'
16 16x16
32 16x16@2x
32 32x32
64 32x32@2x
128 128x128
256 128x128@2x
256 256x256
512 256x256@2x
512 512x512
1024 512x512@2x
SIZES
  if iconutil -c icns "$ISET" \
       -o "$APPDIR/Contents/Resources/TalkTalkTalk.icns" 2>/dev/null; then
    grep -q CFBundleIconFile "$APPDIR/Contents/Info.plist" || \
      /usr/bin/plutil -insert CFBundleIconFile -string TalkTalkTalk \
        "$APPDIR/Contents/Info.plist" 2>/dev/null || true
  fi
  rm -rf "$(dirname "$ISET")"
fi
touch "$APPDIR"

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

Drag ~/Applications/Talk Talk Talk.app to the Dock: it reopens the UI
after you use "Quit Talk Talk Talk" in the menu.

Hotkeys: ⌃⌥S speak selection · ⌃⌥P play/pause · ⌃⌥← rewind ·
         ⌃⌥X stop · ⌃⌥A auto-read toggle
────────────────────────────────────────────────────────────────────────
EOF
