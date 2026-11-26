#!/bin/bash
# Build the distributable macOS app: Bellow Flo.app with its own Python
# engine and voice models inside, on a DMG. Apple Silicon.
#
#   macos/package.sh [VERSION]
#
# Signing, from the environment:
#   BELLOWFLO_SIGN_IDENTITY  a "Developer ID Application: …" identity. Without
#                            one the app is signed ad hoc: it runs, but a
#                            downloaded copy needs "Open Anyway" in System
#                            Settings → Privacy & Security on first launch.
#   BELLOWFLO_NOTARY_PROFILE a notarytool keychain profile (xcrun notarytool
#                            store-credentials). With an identity, the DMG is
#                            notarized and stapled, and opens with no warning.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
VERSION="${1:-$(git -C "$REPO" describe --tags --always 2>/dev/null || echo dev)}"
DIST="$REPO/dist"
WORK="$DIST/macos"
APP="$WORK/Bellow Flo.app"
DMG="$DIST/BellowFlo-$VERSION-macos-arm64.dmg"
IDENTITY="${BELLOWFLO_SIGN_IDENTITY:-}"
DATA_MODELS="$HOME/Library/Application Support/Bellow Flo/models"

[ "$(uname -m)" = "arm64" ] || { echo "error: build on Apple Silicon" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
"$HERE/BellowFlo/build-app.sh" "$WORK"

echo "==> Bundling the engine"
MODELS_ARG=()
[ -f "$DATA_MODELS/kokoro-v1.0.onnx" ] && MODELS_ARG=(--models-from "$DATA_MODELS")
python3 "$REPO/packaging/build_engine.py" --platform macos \
  --out "$APP/Contents/Resources/engine" "${MODELS_ARG[@]+"${MODELS_ARG[@]}"}"

# Version in the bundle, so About and Finder agree with the file name.
SHORT="${VERSION#v}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT" "$APP/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SHORT" "$APP/Contents/Info.plist" || true

echo "==> Signing"
# Inside out: every Mach-O in the engine first, then the app around them.
# --deep would sign them too, but cannot apply the hardened runtime and
# entitlements notarization needs to each one.
if [ -n "$IDENTITY" ]; then
  SIGN=(--force --sign "$IDENTITY" --options runtime --timestamp
        --entitlements "$HERE/entitlements.plist")
else
  SIGN=(--force --sign -)
fi
find "$APP/Contents/Resources/engine" -type f \( -name "*.so" -o -name "*.dylib" \
     -o -perm -u+x \) -print0 |
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then codesign "${SIGN[@]}" "$f" >/dev/null 2>&1 \
     || { echo "error: could not sign $f" >&2; exit 1; }; fi
done
codesign "${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature OK"

echo "==> Making the DMG"
STAGE="$WORK/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Bellow Flo" -srcfolder "$STAGE" -fs HFS+ -format ULMO "$DMG"
rm -rf "$STAGE"
[ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ -n "$IDENTITY" ] && [ -n "${BELLOWFLO_NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing (a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$BELLOWFLO_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "==> Built: $DMG ($(du -h "$DMG" | cut -f1))"
