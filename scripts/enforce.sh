#!/bin/sh
# Root backstop for SleepGuard, run every 5 minutes by the LaunchDaemon that install.sh sets up.
# Re-enables sleep when `pmset disablesleep` is on and no unexpired expiry is on record, so the
# expiry still holds when the app is not running.
#
# The expiry file is written by the app, as an ordinary user. Its content is only ever compared
# as a number here: never executed, never written back.

PMSET=/usr/bin/pmset
EXPIRY_FILE=/Users/Shared/SleepGuard/expires-at
GRACE_SECONDS=20

sleep_disabled() {
  [ "$($PMSET -g | /usr/bin/awk '$1 == "SleepDisabled" {print $2}')" = "1" ]
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

sleep_disabled || exit 0
exp=$(read_expiry)
if [ -z "$exp" ]; then
  # Sleep was disabled outside the app, or the file is damaged. A running app gives it an
  # expiry within 15 seconds, so look again before overriding.
  /bin/sleep "$GRACE_SECONDS"
  sleep_disabled || exit 0
  exp=$(read_expiry)
fi

now=$(/bin/date +%s)
if [ "${exp:-0}" -le "$now" ]; then
  $PMSET -a disablesleep 0
  /bin/rm -f "$EXPIRY_FILE"
  /usr/bin/logger -t sleepguard "disablesleep reset to 0 (expiry ${exp:-none}, now $now)"
fi
