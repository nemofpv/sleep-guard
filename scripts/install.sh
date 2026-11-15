#!/bin/sh
# Sets up the two root-owned pieces SleepGuard uses. The installer package runs it after copying
# the app into /Applications; from a checkout, run it with sudo.
#
#   1. A LaunchDaemon that runs enforce.sh as root every 5 minutes, so an expiry is still
#      enforced when the app is not running.
#   2. A sudoers rule letting one user run exactly `pmset -a disablesleep 0` and
#      `pmset -a disablesleep 1` without a password. Without it the app asks for an admin
#      password on every change, including the automatic turn-off at expiry.
#
# Usage: sudo scripts/install.sh [--remove-with-app] [user]     (default: the user who ran sudo)
#   --remove-with-app   The backstop removes itself, and the sudoers rule, once
#                       /Applications/SleepGuard.app has been deleted. The installer package
#                       passes this. Without it everything stays until uninstall.sh is run.
# Undo:  sudo "/Library/Application Support/SleepGuard/uninstall.sh"
set -eu
LC_ALL=C; export LC_ALL          # so that A-Z below means the ASCII letters and nothing more

[ "$(/usr/bin/id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

MODE_ARGUMENT=
if [ "${1:-}" = --remove-with-app ]; then
  MODE_ARGUMENT='<string>remove-with-app</string>'    # enforce.sh looks for exactly this word
  shift
fi

TARGET_USER=${1:-${SUDO_USER:-}}
case "$TARGET_USER" in
  ''|root) echo "Could not tell which user to allow. Pass a user name: sudo $0 <user>" >&2; exit 1 ;;
  *[!A-Za-z0-9._-]*) echo "Unexpected characters in user name: $TARGET_USER" >&2; exit 1 ;;
esac
# The name goes into the sudoers file as given, so it has to be the account's own spelling:
# `id` also finds an account by its number or in the wrong case, and a rule under such a
# spelling would not match the account, or would mean something else.
[ "$(/usr/bin/id -un "$TARGET_USER" 2>/dev/null)" = "$TARGET_USER" ] || { echo "No such user: $TARGET_USER" >&2; exit 1; }

HERE=$(cd "$(/usr/bin/dirname "$0")" && pwd)
SUDOERS=/etc/sudoers.d/sleepguard
SUPPORT_DIR="/Library/Application Support/SleepGuard"
LABEL=local.sleepguard.enforce          # uninstall.sh stops the daemon by this label
PLIST=/Library/LaunchDaemons/$LABEL.plist

# The sudoers rule is written and checked first, before anything is installed: a broken file in
# sudoers.d breaks sudo itself. It goes live last, below.
tmp=$(/usr/bin/mktemp)
trap '/bin/rm -f "$tmp"' EXIT
printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' "$TARGET_USER" > "$tmp"
/usr/sbin/visudo -cf "$tmp" >/dev/null

# 1. The backstop. Root runs root-owned copies, never the ones in a user-writable folder.
#    uninstall.sh goes along so that the backstop can remove itself, and so that there is still
#    a way to undo all this after the app has been deleted. A note from an earlier install
#    that the app was once seen missing is dropped.
/usr/bin/install -d -o root -g wheel -m 0755 "$SUPPORT_DIR"
/bin/rm -f "$SUPPORT_DIR/app-missing"
/usr/bin/install -o root -g wheel -m 0755 "$HERE/enforce.sh" "$SUPPORT_DIR/enforce.sh"
/usr/bin/install -o root -g wheel -m 0755 "$HERE/uninstall.sh" "$SUPPORT_DIR/uninstall.sh"
/bin/cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string>
    <string>$SUPPORT_DIR/enforce.sh</string>
    $MODE_ARGUMENT
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 0644 "$PLIST"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/launchctl bootstrap system "$PLIST" || { /bin/sleep 2; /bin/launchctl bootstrap system "$PLIST"; }

# 2. The sudoers rule, only now that the backstop is running: a failure above must not leave a
#    passwordless rule behind with nothing to enforce an expiry, or to remove the rule again.
/usr/bin/install -o root -g wheel -m 0440 "$tmp" "$SUDOERS"

echo "SleepGuard: $TARGET_USER can now toggle disablesleep without a password ($SUDOERS)."
echo "SleepGuard: backstop runs every 5 minutes ($PLIST)."
