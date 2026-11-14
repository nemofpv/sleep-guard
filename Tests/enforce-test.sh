#!/bin/sh
# Runs scripts/enforce.sh against a fake pmset and a scratch expiry file. Run with scripts/test.sh.
# The system paths inside the script are rewritten to point into a temporary directory, so the
# script under test carries no test hooks and the real power settings are never touched.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
failures=0
checks=0

# pmset: reports the state in $T/state, records every other invocation.
cat > "$T/pmset" <<EOF
#!/bin/sh
if [ "\$*" = "-g" ]; then
  printf 'System-wide power settings:\n SleepDisabled\t\t%s\nCurrently in use:\n sleep                1\n' "\$(cat "$T/state")"
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
printf '#!/bin/sh\nexit 0\n' > "$T/logger"
chmod +x "$T/pmset" "$T/sleep" "$T/logger"

sed -e "s#/usr/bin/pmset#$T/pmset#g" \
    -e "s#/Users/Shared/SleepGuard/expires-at#$T/expires-at#g" \
    -e "s#/usr/bin/logger#$T/logger#g" \
    -e "s#/bin/sleep#$T/sleep#g" \
    scripts/enforce.sh > "$T/enforce.sh"
if grep -q -e '/usr/bin/pmset' -e '/Users/Shared' "$T/enforce.sh"; then
  echo "enforce: refusing to run, the script still references real system paths"
  exit 1
fi

now=$(date +%s)
future=$((now + 3600))
past=$((now - 60))

# run <name> <SleepDisabled 0|1> <expiry file content, or - for no file> <reset|keep>
run() {
  name=$1 state=$2 expiry=$3 want=$4
  rm -f "$T/pmset-calls" "$T/expires-at"
  echo "$state" > "$T/state"
  [ "$expiry" = "-" ] || printf '%s' "$expiry" > "$T/expires-at"
  sh "$T/enforce.sh"
  rm -f "$T/during-grace"

  calls=$(cat "$T/pmset-calls" 2>/dev/null)
  checks=$((checks + 1))
  if [ "$want" = reset ]; then
    if [ "$calls" != "-a disablesleep 0" ] || [ -e "$T/expires-at" ]; then
      failures=$((failures + 1))
      echo "FAIL: $name"
      echo "  expected: pmset called with '-a disablesleep 0' and the expiry file removed"
      echo "  actual:   pmset calls '$calls', expiry file $([ -e "$T/expires-at" ] && echo present || echo removed)"
    fi
  else
    if [ -n "$calls" ]; then
      failures=$((failures + 1))
      echo "FAIL: $name"
      echo "  expected: sleep settings left alone"
      echo "  actual:   pmset calls '$calls'"
    fi
  fi
}

run "sleep allowed: nothing to enforce"                 0 -              keep
run "sleep allowed with a lapsed expiry left on file"   0 "$past"        keep
run "disabled with a future expiry: left alone"         1 "$future"      keep
run "disabled indefinitely: left alone"                 1 253402300799   keep
# Surrounding whitespace is accepted by the app's parser too; the two must agree.
run "disabled with a padded future expiry: left alone"  1 "  $future
"                                                                        keep
run "disabled past its expiry: reset"                   1 "$past"        reset
run "disabled with no expiry on file: reset"            1 -              reset
run "disabled with text for an expiry: reset"           1 soon           reset
run "disabled with a negative expiry: reset"            1 -5             reset
# 30 digits overflow the shell's integer comparison; that error must not read as "not expired".
run "disabled with an overlong expiry: reset"           1 999999999999999999999999999999 reset

# `sudo pmset -a disablesleep 1` typed in a terminal while the app is running: the app adopts it
# with an expiry within 15 seconds. The backstop must not win that race and undo it.
printf '#!/bin/sh\nprintf %%s %s > "%s/expires-at"\n' "$future" "$T" > "$T/during-grace"
chmod +x "$T/during-grace"
run "disabled with no expiry, app adopts it during the wait: left alone" 1 - keep

# ...and if the app turned sleep back on during the wait, there is nothing left to reset.
printf '#!/bin/sh\necho 0 > "%s/state"\n' "$T" > "$T/during-grace"
chmod +x "$T/during-grace"
run "disabled with no expiry, sleep re-enabled during the wait: left alone" 1 - keep

if [ "$failures" -eq 0 ]; then echo "enforce: $checks checks passed"; else echo "enforce: $failures of $checks checks FAILED"; fi
[ "$failures" -eq 0 ]
