#!/bin/sh
# Packs build/SleepGuard.app into build/SleepGuard-<version>.dmg, with a SHA-256 checksum.
# The image holds the app next to an Applications shortcut, so installing is dragging one
# onto the other. Run scripts/build.sh first; the version is read from the built app.
set -eu
cd "$(dirname "$0")/.."

APP=build/SleepGuard.app
[ -d "$APP" ] || { echo "No $APP: run scripts/build.sh first" >&2; exit 1; }
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
NAME="SleepGuard-$VERSION.dmg"
STAGE=build/dmg

rm -rf "$STAGE" "build/$NAME" "build/$NAME.sha256"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SleepGuard.app"
ln -s /Applications "$STAGE/Applications"
# Window size and icon positions. The names above must match make-dmg-layout.py.
cp Resources/dmg-layout "$STAGE/.DS_Store"

hdiutil create -quiet -volname SleepGuard -srcfolder "$STAGE" -fs HFS+ -format UDZO "build/$NAME"
rm -rf "$STAGE"
(cd build && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "Packed $(pwd)/build/$NAME"
