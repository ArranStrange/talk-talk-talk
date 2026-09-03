#!/bin/bash
# Builds Talk Talk Talk.app. Run from anywhere; installs nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$HERE/build}"
APP="$OUT/Talk Talk Talk.app"

echo "==> Compiling"
cd "$HERE"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/TalkTalkTalk"
[ -x "$BIN" ] || { echo "error: no binary at $BIN" >&2; exit 1; }

echo "==> Assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TalkTalkTalk"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Talk Talk Talk</string>
  <key>CFBundleDisplayName</key><string>Talk Talk Talk</string>
  <key>CFBundleIdentifier</key><string>com.talktalktalk.app</string>
  <key>CFBundleExecutable</key><string>TalkTalkTalk</string>
  <key>CFBundleIconFile</key><string>TalkTalkTalk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar app: no Dock tile of its own while running. The bundle is
       still clickable from the Dock or Spotlight to launch it. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Talk Talk Talk reads the text you have selected.</string>
</dict>
</plist>
PLIST

# The waveform mark for the menu bar item and the pill's status indicator.
if [ -f "$REPO/macos/logo.png" ]; then
  cp "$REPO/macos/logo.png" "$APP/Contents/Resources/logo.png"
fi

if command -v iconutil >/dev/null 2>&1 && [ -f "$REPO/macos/icon.png" ]; then
  echo "==> Icon"
  ISET="$(mktemp -d)/icon.iconset"; mkdir -p "$ISET"
  while read -r px name; do
    [ -n "$px" ] || continue
    sips -z "$px" "$px" "$REPO/macos/icon.png" --out "$ISET/icon_$name.png" >/dev/null 2>&1
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
  iconutil -c icns "$ISET" -o "$APP/Contents/Resources/TalkTalkTalk.icns"
  rm -rf "$(dirname "$ISET")"
fi

# Signing. A real identity is strongly preferred: it makes the designated
# requirement "this bundle id, signed by this certificate", which survives
# rebuilds. An ad-hoc signature reduces the requirement to a bare cdhash, so
# every rebuild looks like a different app to macOS and orphans the
# Accessibility grant.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(.*\)"$/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
  echo "==> Signing as $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/    /'
else
  echo "==> Signing (ad-hoc — the Accessibility grant will not survive rebuilds)"
  codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/    /' || true
fi
codesign --verify --deep "$APP" && echo "    signature OK"

echo "==> Built: $APP"
