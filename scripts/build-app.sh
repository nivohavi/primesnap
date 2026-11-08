#!/usr/bin/env bash
# Build PrimeSnap.app. Usage: scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PrimeSnap"

APP=build/PrimeSnap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PrimeSnap"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: rendered once into Resources/AppIcon.icns (delete it to regenerate).
if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Screen Recording grant across rebuilds; ad-hoc loses it every build.
# Order: $SIGN_IDENTITY, then scripts/.signing-identity (one line, git-ignored), then any Apple
# development identity in the keychain, else ad-hoc. scripts/make-signing-cert.sh creates a free local one.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f scripts/.signing-identity ]]; then
  IDENTITY="$(head -n1 scripts/.signing-identity)"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
du -sh "$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x PrimeSnap 2>/dev/null || true
  rm -rf /Applications/PrimeSnap.app
  cp -R "$APP" /Applications/
  touch /Applications/PrimeSnap.app   # nudge Finder/Dock to refresh the icon
  open /Applications/PrimeSnap.app
  echo "Installed to /Applications/PrimeSnap.app"
fi
