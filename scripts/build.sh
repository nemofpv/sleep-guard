#!/bin/sh
# Builds build/SleepGuard.app.
#   VERSION=1.2.0   version written into Info.plist (default 0.0.0)
#   UNIVERSAL=1     build for arm64 and x86_64 instead of this machine's architecture
set -eu
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.0.0}
MIN_OS=13.0
APP=build/SleepGuard.app
BIN="$APP/Contents/MacOS/SleepGuard"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() { swiftc -O -target "$1-apple-macos$MIN_OS" Sources/SleepGuard/*.swift -o "$2"; }
if [ "${UNIVERSAL:-0}" = 1 ]; then
  compile arm64 build/SleepGuard-arm64
  compile x86_64 build/SleepGuard-x86_64
  lipo -create build/SleepGuard-arm64 build/SleepGuard-x86_64 -output "$BIN"
  rm build/SleepGuard-arm64 build/SleepGuard-x86_64
else
  compile "$(uname -m)" "$BIN"
fi

# The backstop scripts travel inside the bundle, so a downloaded app can install them:
#   sudo SleepGuard.app/Contents/Resources/install.sh
cp scripts/enforce.sh scripts/install.sh scripts/uninstall.sh "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.sleepguard</string>
  <key>CFBundleName</key><string>SleepGuard</string>
  <key>CFBundleExecutable</key><string>SleepGuard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP ($VERSION)"
