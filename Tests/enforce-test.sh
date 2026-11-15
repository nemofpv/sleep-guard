#!/bin/sh
# Runs scripts/enforce.sh and scripts/uninstall.sh against a fake pmset and a scratch copy of
# every place they touch. Run with scripts/test.sh.
# The system paths inside the scripts are rewritten to point into a temporary directory, so the
# scripts under test carry no test hooks, and neither the real power settings nor any real file
# is touched.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
failures=0
checks=0

# check <name> <expected> <actual>
check() {
  checks=$((checks + 1))
  if [ "$2" != "$3" ]; then
    failures=$((failures + 1))
    echo "FAIL: $1"
    echo "  expected: $2"
    echo "  actual:   $3"
  fi
}

# ---- What root may delete or write: settled before either script is run ----

# Both scripts run as root, one of them unattended. What they delete is not left to the code
# to work out: it is this list, and a change to it has to be made here as well.
#
# uninstall.sh, in full apart from comments: the sudoers rule first, since it is the piece
# that matters if the run is cut short; the property list next, so that a half-finished removal
# is not started again at every boot with pieces missing; stopping the daemon last, because
# that ends the script when the daemon is the one running it.
check "uninstall.sh does exactly this and nothing else" \
'set -u
[ "$(/usr/bin/id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
/bin/rm -f /etc/sudoers.d/sleepguard
/bin/rm -f /Library/LaunchDaemons/local.sleepguard.enforce.plist
/bin/rm -f "/Library/Application Support/SleepGuard/enforce.sh"
/bin/rm -f "/Library/Application Support/SleepGuard/app-missing"
/bin/rm -f "/Library/Application Support/SleepGuard/uninstall.sh"
/bin/rmdir "/Library/Application Support/SleepGuard" 2>/dev/null
echo "SleepGuard: sudoers rule and backstop removed."
/bin/launchctl bootout system/local.sleepguard.enforce 2>/dev/null
exit 0' \
"$(grep -v -e '^#' -e '^$' scripts/uninstall.sh)"

# enforce.sh: every line that deletes, moves or writes a file. Its own marker, in its own
# root-owned folder, and nothing in the folder the app shares with it.
check "enforce.sh deletes and writes only its own marker file" \
'/bin/rm -f "/Library/Application Support/SleepGuard/app-missing"
: > "/Library/Application Support/SleepGuard/app-missing"' \
"$(grep -v '^[[:space:]]*#' scripts/enforce.sh |
    grep -E -e '(^|[^A-Za-z0-9_.-])(rm|rmdir|unlink|mv|cp|ln|dd|tee|touch|mkdir|chmod|chown|install|truncate)([^A-Za-z0-9_.-]|$)' \
            -e '(^|[^0-9&>])>>?[[:space:]]*[^&[:space:]]' |
    grep -v -E '>[[:space:]]*/dev/null' |
    sed 's/^[[:space:]]*//')"

if [ "$failures" -ne 0 ]; then
  echo "enforce: refusing to run the scripts until the above is settled"
  exit 1
fi

# ---- Stand-ins ----

# pmset: reports the state in $T/state, records every other invocation. The state `unreadable`
# gives output with no SleepDisabled line.
cat > "$T/pmset" <<EOF
#!/bin/sh
if [ "\$*" = "-g" ]; then
  echo 'System-wide power settings:'
  [ "\$(cat "$T/state")" = unreadable ] || printf ' SleepDisabled\t\t%s\n' "\$(cat "$T/state")"
  printf 'Currently in use:\n sleep                1\n'
else
  echo "\$*" >> "$T/pmset-calls"
  [ "\$*" = "-a disablesleep 0" ] && echo 0 > "$T/state"
fi
EOF
# sleep: returns at once, after running whatever the test says happens during the wait.
cat > "$T/sleep" <<EOF
#!/bin/sh
[ -x "$T/during-grace" ] && "$T/during-grace"
exit 0
EOF
# launchctl: records the call, then ends the backstop the way the real `bootout` does: on the
# spot, so nothing the script meant to do afterwards happens.
cat > "$T/launchctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/launchctl-calls"
kill -9 "\$(cat "$T/backstop.pid")"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/logger"
# id: says root, which the removal insists on.
printf '#!/bin/sh\necho 0\n' > "$T/id"
chmod +x "$T/pmset" "$T/sleep" "$T/launchctl" "$T/logger" "$T/id"

rewrite() {
  sed -e "s#/usr/bin/pmset#$T/pmset#g" \
      -e "s#/Users/Shared/SleepGuard#$T/shared#g" \
      -e "s#/usr/bin/logger#$T/logger#g" \
      -e "s#/bin/sleep#$T/sleep#g" \
      -e "s#/bin/launchctl#$T/launchctl#g" \
      -e "s#/usr/bin/id#$T/id#g" \
      -e "s#/Library/Application Support/SleepGuard#$T/support#g" \
      -e "s#/Library/LaunchDaemons#$T/daemons#g" \
      -e "s#/etc/sudoers.d#$T/sudoers.d#g" \
      -e "s#/Applications#$T/apps#g" \
      "$1"
}
rewrite scripts/enforce.sh > "$T/enforce.sh"
rewrite scripts/uninstall.sh > "$T/uninstall.sh"
# After the rewrite the only absolute paths left may be ones inside the scratch folder and these
# tools. Anything else would be read, run or deleted for real.
strays=$(grep -h -v '^[[:space:]]*#' "$T/enforce.sh" "$T/uninstall.sh" |
  sed "s#$T/[A-Za-z0-9._/-]*##g" |
  grep -o -E "(^|[[:space:]\"'=>(])/[A-Za-z0-9._-][A-Za-z0-9._/-]*" |
  sed 's#^[^/]*##' | sort -u |
  grep -v -x -e /bin/rm -e /bin/rmdir -e /bin/sh -e /bin/date -e /usr/bin/awk -e /usr/bin/head -e /usr/bin/sed -e /dev/null)
if [ -n "$strays" ]; then
  echo "enforce: refusing to run, a script still references real system paths:"
  echo "$strays" | sed 's/^/  /'
  exit 1
fi

now=$(date +%s)
future=$((now + 3600))
past=$((now - 60))

# ---- Enforcing the expiry ----

# run <name> <SleepDisabled 0|1> <expiry file content, or - for no file> <reset|keep>
run() {
  name=$1 state=$2 expiry=$3 want=$4
  rm -rf "$T/shared" "$T/pmset-calls"
  mkdir "$T/shared"
  echo "$state" > "$T/state"
  [ "$expiry" = "-" ] || printf '%s' "$expiry" > "$T/shared/expires-at"
  sh "$T/enforce.sh"
  rm -f "$T/during-grace"
  if [ "$want" = reset ]; then want_calls="-a disablesleep 0"; else want_calls=; fi
  check "$name" "pmset calls '$want_calls'" "pmset calls '$(cat "$T/pmset-calls" 2>/dev/null)'"
}

run "sleep allowed: nothing to enforce"                 0 -              keep
run "sleep allowed with a lapsed expiry left on file"   0 "$past"        keep
run "disabled with a future expiry: left alone"         1 "$future"      keep
run "disabled indefinitely: left alone"                 1 253402300799   keep
# Surrounding whitespace is accepted by the app's parser too; the two must agree.
run "disabled with a padded future expiry: left alone"  1 "  $future
"                                                                        keep
run "disabled past its expiry: reset"                   1 "$past"        reset
# The expiry file belongs to the app, in a folder any user can write to. Root reads it and
# leaves it where it is; the app clears a stale one itself.
check "...and the expiry file is left for the app to clear" "$past" "$(cat "$T/shared/expires-at" 2>/dev/null)"
run "disabled with no expiry on file: reset"            1 -              reset
run "disabled with text for an expiry: reset"           1 soon           reset
run "disabled with a negative expiry: reset"            1 -5             reset
# 30 digits overflow the shell's integer comparison; that error must not read as "not expired".
run "disabled with an overlong expiry: reset"           1 999999999999999999999999999999 reset

# `sudo pmset -a disablesleep 1` typed in a terminal while the app is running: the app adopts it
# with an expiry within 15 seconds. The backstop must not win that race and undo it.
printf '#!/bin/sh\nprintf %%s %s > "%s/shared/expires-at"\n' "$future" "$T" > "$T/during-grace"
chmod +x "$T/during-grace"
run "disabled with no expiry, app adopts it during the wait: left alone" 1 - keep

# ...and if the app turned sleep back on during the wait, there is nothing left to reset.
printf '#!/bin/sh\necho 0 > "%s/state"\n' "$T" > "$T/during-grace"
chmod +x "$T/during-grace"
run "disabled with no expiry, sleep re-enabled during the wait: left alone" 1 - keep

# Somebody swaps the shared folder for a link to a folder of their choosing, holding a file
# with the same name. Root must not delete through that link.
rm -rf "$T/shared" "$T/pmset-calls" "$T/elsewhere"
mkdir "$T/elsewhere"
printf '%s' "$past" > "$T/elsewhere/expires-at"
ln -s "$T/elsewhere" "$T/shared"
echo 1 > "$T/state"
sh "$T/enforce.sh"
check "shared folder swapped for a link: sleep is reset, the file behind the link survives" \
  "pmset calls '-a disablesleep 0', file kept" \
  "pmset calls '$(cat "$T/pmset-calls" 2>/dev/null)', file $([ -e "$T/elsewhere/expires-at" ] && echo kept || echo DELETED)"
rm -rf "$T/shared" "$T/elsewhere"

# ---- Removing itself once the app has been deleted ----

# What the installer package leaves on disk, with a bystander next to every piece.
lay_out() {
  rm -rf "$T/support" "$T/daemons" "$T/sudoers.d" "$T/apps" "$T/shared"
  rm -f "$T/launchctl-calls" "$T/pmset-calls"
  mkdir -p "$T/support" "$T/daemons" "$T/sudoers.d" "$T/shared" "$T/apps/SleepGuard.app" "$T/apps/Other.app"
  cp "$T/enforce.sh" "$T/uninstall.sh" "$T/support/"
  : > "$T/daemons/local.sleepguard.enforce.plist"
  : > "$T/daemons/com.example.other.plist"
  : > "$T/sudoers.d/sleepguard"
  : > "$T/sudoers.d/other"
}

# Runs the installed copy the way launchd does, with its pid on file for the fake launchctl.
# $1 is the argument launchd passes, or nothing.
backstop() {
  sh -c 'echo $$ > "$1/backstop.pid"; exec sh "$1/support/enforce.sh" $2' sh "$T" "$1" > /dev/null 2> "$T/stderr" &
  wait $! 2>/dev/null
  cat "$T/stderr" >&2
}

# What is left afterwards, in words.
left() {
  pieces=0
  for piece in daemons/local.sleepguard.enforce.plist sudoers.d/sleepguard support/enforce.sh support/uninstall.sh; do
    [ -e "$T/$piece" ] && pieces=$((pieces + 1))
  done
  case $pieces in
    4) helper="backstop installed" ;;
    0) if [ -e "$T/support" ]; then helper="backstop removed but its folder left"; else helper="backstop removed"; fi ;;
    *) helper="backstop HALF removed" ;;
  esac
  if [ -e "$T/support/app-missing" ]; then absence=noted; else absence="not noted"; fi
  bystanders=untouched
  for other in daemons/com.example.other.plist sudoers.d/other apps/Other.app; do
    [ -e "$T/$other" ] || bystanders=DAMAGED
  done
  echo "$helper, absence $absence, bystanders $bystanders, launchctl '$(cat "$T/launchctl-calls" 2>/dev/null)', pmset '$(cat "$T/pmset-calls" 2>/dev/null)'"
}

# retire <name> <argument or -> <app: there|gone|no-folder> <absence so far: noted|new>
#        <SleepDisabled 0|1|unreadable> <expiry or -> <what should be left>
retire() {
  name=$1 mode=$2 app=$3 before=$4 state=$5 expiry=$6 want=$7
  lay_out
  [ "$mode" = "-" ] && mode=
  [ "$app" = gone ] && rmdir "$T/apps/SleepGuard.app"
  [ "$app" = no-folder ] && mv "$T/apps" "$T/apps-away"
  [ "$before" = noted ] && : > "$T/support/app-missing"
  echo "$state" > "$T/state"
  [ "$expiry" = "-" ] || printf '%s' "$expiry" > "$T/shared/expires-at"
  backstop "$mode"
  [ "$app" = no-folder ] && mv "$T/apps-away" "$T/apps"
  check "$name" "$want" "$(left)"
}

retire "app in place: backstop stays" \
  remove-with-app there new 0 - \
  "backstop installed, absence not noted, bystanders untouched, launchctl '', pmset ''"
retire "app gone, first sighting: only noted" \
  remove-with-app gone new 0 - \
  "backstop installed, absence noted, bystanders untouched, launchctl '', pmset ''"
retire "app gone on two runs in a row: backstop removed, daemon stopped" \
  remove-with-app gone noted 0 "$past" \
  "backstop removed, absence not noted, bystanders untouched, launchctl 'bootout system/local.sleepguard.enforce', pmset ''"

# The same run again, looked at file by file: the pieces of the backstop are gone and every
# other file is still there, the expiry file in the shared folder included.
checks=$((checks + 1))
want_tree="apps
apps/Other.app
daemons
daemons/com.example.other.plist
shared
shared/expires-at
sudoers.d
sudoers.d/other"
got_tree=$(cd "$T" && find apps daemons sudoers.d support shared 2>/dev/null | sort)
if [ "$got_tree" != "$want_tree" ]; then
  failures=$((failures + 1))
  echo "FAIL: removal deletes the backstop's own files and nothing else"
  echo "  expected to be left:"; echo "$want_tree" | sed 's/^/    /'
  echo "  actually left:";       echo "$got_tree"  | sed 's/^/    /'
fi

retire "app back after one sighting: the note is dropped" \
  remove-with-app there noted 0 - \
  "backstop installed, absence not noted, bystanders untouched, launchctl '', pmset ''"
# "Two runs in a row" has to hold while a keep-awake is on as well, or a sighting from long ago
# would still count.
retire "app back after one sighting, during a keep-awake: the note is dropped all the same" \
  remove-with-app there noted 1 "$future" \
  "backstop installed, absence not noted, bystanders untouched, launchctl '', pmset ''"
retire "app gone, first sighting, during a keep-awake: noted, the keep-awake left alone" \
  remove-with-app gone new 1 "$future" \
  "backstop installed, absence noted, bystanders untouched, launchctl '', pmset ''"
retire "installed from a checkout, without the argument: never removes itself" \
  - gone noted 0 - \
  "backstop installed, absence noted, bystanders untouched, launchctl '', pmset ''"
retire "installed from a checkout: a keep-awake outlives the app in /Applications" \
  - gone noted 1 "$future" \
  "backstop installed, absence noted, bystanders untouched, launchctl '', pmset ''"

# A keep-awake cannot outlive the app that set it: nothing could show it or end it any more,
# and "indefinitely" would keep the Mac awake, and the backstop installed, for good. The
# backstop ends it; the removal follows on the next run, once sleep is allowed.
retire "app gone twice with a keep-awake still running: the keep-awake ends, removal waits a run" \
  remove-with-app gone noted 1 "$future" \
  "backstop installed, absence noted, bystanders untouched, launchctl '', pmset '-a disablesleep 0'"
retire "app gone twice with an indefinite keep-awake: it ends too" \
  remove-with-app gone noted 1 253402300799 \
  "backstop installed, absence noted, bystanders untouched, launchctl '', pmset '-a disablesleep 0'"
retire "app gone twice, keep-awake lapsed: sleep is reset first, removal waits a run" \
  remove-with-app gone noted 1 "$past" \
  "backstop installed, absence noted, bystanders untouched, launchctl '', pmset '-a disablesleep 0'"
retire "app gone twice, but pmset cannot be read: waits" \
  remove-with-app gone noted unreadable - \
  "backstop installed, absence noted, bystanders untouched, launchctl '', pmset ''"
retire "the Applications folder itself is missing: cannot tell, stays" \
  remove-with-app no-folder noted 0 - \
  "backstop installed, absence not noted, bystanders untouched, launchctl '', pmset ''"

# A file in the backstop's folder that the installer did not put there is not ours to delete.
lay_out
rmdir "$T/apps/SleepGuard.app"
: > "$T/support/app-missing"
: > "$T/support/somebody-elses-file"
echo 0 > "$T/state"
backstop remove-with-app
check "a stranger's file in the backstop's folder survives the removal" \
  "backstop removed but its folder left, kept" \
  "$(left | cut -d, -f1), $([ -e "$T/support/somebody-elses-file" ] && echo kept || echo DELETED)"

if [ "$failures" -eq 0 ]; then echo "enforce: $checks checks passed"; else echo "enforce: $failures of $checks checks FAILED"; fi
[ "$failures" -eq 0 ]
