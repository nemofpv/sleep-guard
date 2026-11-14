#!/bin/sh
# Removes what install.sh set up: the sudoers rule and the backstop LaunchDaemon. Run with sudo.
# The power setting itself is left as it is; the app goes back to asking for an admin password.
set -eu

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

SUDOERS=/etc/sudoers.d/sleepguard
SUPPORT_DIR="/Library/Application Support/SleepGuard"
LABEL=local.sleepguard.enforce
PLIST=/Library/LaunchDaemons/$LABEL.plist

/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/rm -f "$PLIST" "$SUDOERS" "$SUPPORT_DIR/enforce.sh"
/bin/rmdir "$SUPPORT_DIR" 2>/dev/null || true

echo "SleepGuard: sudoers rule and backstop removed."
