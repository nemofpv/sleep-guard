#!/bin/sh
# Root backstop for SleepGuard, run every 5 minutes by the LaunchDaemon that install.sh sets up.
# Re-enables sleep when `pmset disablesleep` is on and no unexpired expiry is on record, so the
# expiry still holds when the app is not running.
#
# The expiry file is written by the app, as an ordinary user, in a folder any user can write
# to. Its content is only ever compared as a number here: never executed, never written back,
# and the file is never deleted from here either. The app clears a stale one itself.
#
# Started with the argument `remove-with-app`, as the installer package sets it up, the backstop
# also removes itself once the app has been deleted: see app_gone and the lines after it.

PMSET=/usr/bin/pmset
EXPIRY_FILE=/Users/Shared/SleepGuard/expires-at
GRACE_SECONDS=20
MODE=${1:-}

# Prints 1 or 0, or nothing when the pmset output has no SleepDisabled line.
sleep_state() {
  $PMSET -g | /usr/bin/awk '$1 == "SleepDisabled" {print $2}'
}

# Prints the expiry in epoch seconds. Prints nothing unless the file holds 1-12 digits with
# optional surrounding whitespace, the same rule as parseExpiry in Policy.swift.
read_expiry() {
  [ -f "$EXPIRY_FILE" ] || return 0
  exp=$(/usr/bin/head -c 64 "$EXPIRY_FILE" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$exp" in
    ''|*[!0-9]*|?????????????*) ;;
    *) echo "$exp" ;;
  esac
}

# $1 says why, for the log.
reset_sleep() {
  $PMSET -a disablesleep 0
  /usr/bin/logger -t sleepguard "disablesleep reset to 0 ($1)"
}

# True once the app that the installer package put into /Applications has been deleted.
# Dragging it to the Trash runs no code of the app's, so the backstop is what notices.
#   - Never true without `remove-with-app`: a backstop installed from a checkout stays.
#   - "Deleted" means the Applications folder is there and the app is not in it, on two runs in
#     a row, five minutes apart. That covers the moment an update replaces the app. The first
#     sighting leaves a marker in the backstop's own root-owned folder; any run that finds the
#     app in place takes the marker away again.
app_gone() {
  [ "$MODE" = remove-with-app ] || return 1
  if [ ! -d /Applications ] || [ -e /Applications/SleepGuard.app ] || [ -L /Applications/SleepGuard.app ]; then
    /bin/rm -f "/Library/Application Support/SleepGuard/app-missing"
    return 1
  fi
  if [ ! -e "/Library/Application Support/SleepGuard/app-missing" ]; then
    : > "/Library/Application Support/SleepGuard/app-missing"
    return 1
  fi
  return 0
}

gone=no
app_gone && gone=yes
state=$(sleep_state)

# The app is gone and sleep is allowed: nothing is left for the backstop to do, so it removes
# itself. The removal is uninstall.sh, which deletes a fixed list of files. Nothing is passed
# to it, and nothing read here decides what it deletes. It runs only in this state, so it never
# coincides with a change to the power settings.
if [ "$gone" = yes ] && [ "$state" = "0" ]; then
  /usr/bin/logger -t sleepguard "/Applications/SleepGuard.app is gone: removing the backstop and the sudoers rule"
  exec /bin/sh "/Library/Application Support/SleepGuard/uninstall.sh"
fi

[ "$state" = "1" ] || exit 0

# A keep-awake does not outlive the app that set it: nothing could show it or end it any more,
# and "indefinitely" would keep both the Mac awake and the backstop installed for good. The
# next run finds sleep allowed and removes the backstop.
if [ "$gone" = yes ]; then
  reset_sleep "the app has been deleted"
  exit 0
fi

exp=$(read_expiry)
if [ -z "$exp" ]; then
  # Sleep was disabled outside the app, or the file is damaged. A running app gives it an
  # expiry within 15 seconds, so look again before overriding.
  /bin/sleep "$GRACE_SECONDS"
  [ "$(sleep_state)" = "1" ] || exit 0
  exp=$(read_expiry)
fi

now=$(/bin/date +%s)
if [ "${exp:-0}" -le "$now" ]; then
  reset_sleep "expiry ${exp:-none}, now $now"
fi
