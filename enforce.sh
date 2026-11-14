#!/bin/sh
# Optional backstop, meant to run as root every 5 minutes from a LaunchDaemon.
# Re-enables sleep when disablesleep is on and there is no unexpired SleepGuard expiry.
state=$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ {print $2}')
[ "$state" = "1" ] || exit 0
now=$(/bin/date +%s)
exp=$(/bin/cat /Users/Shared/SleepGuard/expires-at 2>/dev/null)
case "$exp" in ''|*[!0-9]*) exp=0 ;; esac
if [ "$exp" -le "$now" ]; then
  /usr/bin/pmset -a disablesleep 0
  /bin/rm -f /Users/Shared/SleepGuard/expires-at
  /usr/bin/logger -t sleepguard "disablesleep reset to 0 (expiry $exp, now $now)"
fi
