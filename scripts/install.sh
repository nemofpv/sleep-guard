#!/bin/sh
# Sets up the two root-owned pieces SleepGuard uses. Run with sudo.
#
#   1. A sudoers rule letting one user run exactly `pmset -a disablesleep 0` and
#      `pmset -a disablesleep 1` without a password. Without it the app asks for an admin
#      password on every change, including the automatic turn-off at expiry.
#   2. A LaunchDaemon that runs enforce.sh as root every 5 minutes, so an expiry is still
#      enforced when the app is not running.
#
# Usage: sudo scripts/install.sh [user]     (default: the user who ran sudo)
# Undo:  sudo scripts/uninstall.sh
set -eu

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

TARGET_USER=${1:-${SUDO_USER:-}}
case "$TARGET_USER" in
  ''|root) echo "Could not tell which user to allow. Pass a user name: sudo $0 <user>" >&2; exit 1 ;;
  *[!A-Za-z0-9._-]*) echo "Unexpected characters in user name: $TARGET_USER" >&2; exit 1 ;;
esac
id "$TARGET_USER" >/dev/null 2>&1 || { echo "No such user: $TARGET_USER" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
SUDOERS=/etc/sudoers.d/sleepguard
SUPPORT_DIR="/Library/Application Support/SleepGuard"
LABEL=local.sleepguard.enforce          # uninstall.sh removes the daemon by this label
PLIST=/Library/LaunchDaemons/$LABEL.plist

# 1. The sudoers rule. Checked before it goes live: a broken file in sudoers.d breaks sudo itself.
tmp=$(/usr/bin/mktemp)
trap '/bin/rm -f "$tmp"' EXIT
printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' "$TARGET_USER" > "$tmp"
/usr/sbin/visudo -cf "$tmp" >/dev/null
/usr/bin/install -o root -g wheel -m 0440 "$tmp" "$SUDOERS"

# 2. The backstop. Root runs a root-owned copy, never the one in a user-writable folder.
/usr/bin/install -d -o root -g wheel -m 0755 "$SUPPORT_DIR"
/usr/bin/install -o root -g wheel -m 0755 "$HERE/enforce.sh" "$SUPPORT_DIR/enforce.sh"
/bin/cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string>
    <string>$SUPPORT_DIR/enforce.sh</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 0644 "$PLIST"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/launchctl bootstrap system "$PLIST" || { /bin/sleep 2; /bin/launchctl bootstrap system "$PLIST"; }

echo "SleepGuard: $TARGET_USER can now toggle disablesleep without a password ($SUDOERS)."
echo "SleepGuard: backstop runs every 5 minutes ($PLIST)."
