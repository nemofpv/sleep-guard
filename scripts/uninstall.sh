#!/bin/sh
# Removes what install.sh set up: the sudoers rule and the backstop LaunchDaemon. Run with sudo.
# The power setting itself is left as it is; the app goes back to asking for an admin password.
#
# The backstop runs its own root-owned copy of this script, unattended, to remove itself after
# the app has been deleted. So this script does one thing and takes no input:
#   - every path is written out in full: no variable, no wildcard, no recursive delete;
#   - each one is a file install.sh created, in a folder only root can write to;
#   - nothing under /Users or /Applications is touched, and no power setting is changed;
#   - the sudoers rule goes first, being the piece that matters if the run is cut short; the
#     property list next, so that a half-finished removal is not started again at every boot;
#   - the daemon is stopped last, because that ends this script when the daemon is running it.
# Tests/enforce-test.sh holds a copy of the commands below and refuses to run if they differ,
# then runs them against a scratch copy of these folders. Change both together.
set -u

[ "$(/usr/bin/id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

/bin/rm -f /etc/sudoers.d/sleepguard
/bin/rm -f /Library/LaunchDaemons/local.sleepguard.enforce.plist
/bin/rm -f "/Library/Application Support/SleepGuard/enforce.sh"
/bin/rm -f "/Library/Application Support/SleepGuard/app-missing"
/bin/rm -f "/Library/Application Support/SleepGuard/uninstall.sh"
/bin/rmdir "/Library/Application Support/SleepGuard" 2>/dev/null

echo "SleepGuard: sudoers rule and backstop removed."
/bin/launchctl bootout system/local.sleepguard.enforce 2>/dev/null
exit 0
