#!/usr/bin/env bash
# Package build/PrimeSnap.app into build/PrimeSnap.dmg (drag-to-Applications installer).
# Usage: scripts/make-dmg.sh   (run scripts/build-app.sh first)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/PrimeSnap.app
DMG=build/PrimeSnap.dmg
[[ -d "$APP" ]] || { echo "Missing $APP: run scripts/build-app.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname PrimeSnap -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
