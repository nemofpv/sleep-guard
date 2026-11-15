#!/bin/sh
# Packs build/SleepGuard.app into build/SleepGuard-<version>.pkg, with a SHA-256 checksum.
# Opening the package installs the app into /Applications and then runs scripts/pkg/postinstall,
# which sets up the sudoers rule and the backstop with the three scripts packed next to it.
# Run scripts/build.sh first; the version is read from the built app.
set -eu
cd "$(dirname "$0")/.."

APP=build/SleepGuard.app
[ -d "$APP" ] || { echo "No $APP: run scripts/build.sh first" >&2; exit 1; }
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
NAME="SleepGuard-$VERSION.pkg"
STAGE=build/pkg

rm -rf "$STAGE" "build/$NAME" "build/$NAME.sha256"
mkdir -p "$STAGE/root" "$STAGE/scripts"
ditto "$APP" "$STAGE/root/SleepGuard.app"
# What root runs during the install travels in the package itself, not in the app.
cp scripts/pkg/postinstall scripts/install.sh scripts/enforce.sh scripts/uninstall.sh "$STAGE/scripts/"
chmod +x "$STAGE/scripts/postinstall"

# Not relocatable: by default the Installer updates a copy of the app wherever it finds one,
# such as build/SleepGuard.app in a checkout, instead of installing into /Applications. The
# backstop and postinstall both count on /Applications/SleepGuard.app.
# Not version checked: an older or equal version installs over a newer one without complaint.
cat > "$STAGE/component.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>RootRelativeBundlePath</key><string>SleepGuard.app</string>
  <key>BundleIsRelocatable</key><false/>
  <key>BundleIsVersionChecked</key><false/>
  <key>BundleHasStrictIdentifier</key><true/>
  <key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST

pkgbuild --quiet --root "$STAGE/root" --component-plist "$STAGE/component.plist" \
  --scripts "$STAGE/scripts" --identifier local.sleepguard.pkg --version "$VERSION" \
  --install-location /Applications "build/$NAME"
rm -rf "$STAGE"
(cd build && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "Packed $(pwd)/build/$NAME"
