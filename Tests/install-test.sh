#!/bin/sh
# Runs scripts/install.sh and scripts/pkg/postinstall against a scratch copy of the folders they
# write to, with stand-ins for the steps that need root. Run with scripts/test.sh.
# Neither can be tried for real without changing this Mac, so this checks what they lay down:
# the sudoers rule, the backstop's two scripts, the LaunchDaemon's property list, who owns what,
# and in which order.
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

# ---- Stand-ins. Those that change something as root write what they were asked into $T/calls. ----

# install: copies a file or makes a folder like the real one, without the change of owner.
cat > "$T/install" <<EOF
#!/bin/sh
asked=install
folder=no
while [ \$# -gt 0 ]; do
  case \$1 in
    -d) folder=yes; asked="\$asked \$1"; shift ;;
    -o|-g|-m) asked="\$asked \$1 \$2"; shift 2 ;;
    *) break ;;
  esac
done
if [ "\$folder" = yes ]; then
  echo "\$asked -> \$1" >> "$T/calls"
  mkdir -p "\$1"
else
  echo "\$asked -> \$2" >> "$T/calls"
  cp "\$1" "\$2"
fi
EOF
cat > "$T/chown" <<EOF
#!/bin/sh
echo "chown \$*" >> "$T/calls"
EOF
# launchctl: loading the daemon fails while $T/bootstrap-fails exists.
cat > "$T/launchctl" <<EOF
#!/bin/sh
echo "launchctl \$*" >> "$T/calls"
[ "\$1" = bootstrap ] && [ -e "$T/bootstrap-fails" ] && exit 5
exit 0
EOF
# visudo: the real syntax check, unless $T/sudoers-check-fails exists.
cat > "$T/visudo" <<EOF
#!/bin/sh
echo "visudo" >> "$T/calls"
[ -e "$T/sudoers-check-fails" ] && exit 1
exec /usr/sbin/visudo "\$@"
EOF
# id: says root when asked who is running. Looks accounts up for real, unless
# $T/id-knows-everyone exists: then every name is an account, spelled as given.
cat > "$T/id" <<EOF
#!/bin/sh
if [ "\${1:-}" = -u ]; then echo 0; exit 0; fi
if [ -e "$T/id-knows-everyone" ]; then
  for name; do :; done
  printf '%s\n' "\$name"
  exit 0
fi
exec /usr/bin/id "\$@"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/sleep"
printf '#!/bin/sh\necho carol\n' > "$T/stat"
chmod +x "$T/install" "$T/chown" "$T/launchctl" "$T/visudo" "$T/id" "$T/sleep" "$T/stat"

# install.sh takes the two scripts it installs from the folder it is in.
mkdir "$T/bundle"
cp scripts/enforce.sh scripts/uninstall.sh "$T/bundle/"
sed -e "s#/usr/bin/install#$T/install#g" \
    -e "s#/usr/sbin/chown#$T/chown#g" \
    -e "s#/bin/launchctl#$T/launchctl#g" \
    -e "s#/usr/sbin/visudo#$T/visudo#g" \
    -e "s#/usr/bin/id#$T/id#g" \
    -e "s#/bin/sleep#$T/sleep#g" \
    -e "s#/Library/Application Support/SleepGuard#$T/support#g" \
    -e "s#/Library/LaunchDaemons#$T/daemons#g" \
    -e "s#/etc/sudoers.d#$T/sudoers.d#g" \
    scripts/install.sh > "$T/bundle/install.sh"
# After the rewrite the only absolute paths left may be ones inside the scratch folder, these
# tools, and two that are text rather than something to run: /bin/sh in the property list and
# /usr/bin/pmset in the sudoers rule. Anything else would be written or run for real.
strays=$(grep -v '^[[:space:]]*#' "$T/bundle/install.sh" |
  sed "s#$T/[A-Za-z0-9._/-]*##g" |
  grep -o -E "(^|[[:space:]\"'=>(])/[A-Za-z0-9._-][A-Za-z0-9._/-]*" |
  sed 's#^[^/]*##' | sort -u |
  grep -v -x -e /bin/rm -e /bin/cat -e /bin/chmod -e /usr/bin/mktemp -e /usr/bin/dirname -e /dev/null -e /bin/sh -e /usr/bin/pmset)
if [ -n "$strays" ]; then
  echo "install: refusing to run, the script still references real system paths:"
  echo "$strays" | sed 's/^/  /'
  exit 1
fi

fresh() {
  rm -rf "$T/support" "$T/daemons" "$T/sudoers.d"
  rm -f "$T/calls" "$T/bootstrap-fails" "$T/sudoers-check-fails" "$T/id-knows-everyone"
  mkdir "$T/daemons" "$T/sudoers.d"
}

# The arguments launchd will start the backstop with, joined by |.
arguments() {
  joined=
  i=0
  while arg=$(plutil -extract "ProgramArguments.$i" raw "$T/daemons/local.sleepguard.enforce.plist" 2>/dev/null); do
    joined="$joined${joined:+|}$arg"
    i=$((i + 1))
  done
  echo "$joined"
}

# Everything install.sh has put anywhere, one name per line.
installed() {
  (cd "$T" && find sudoers.d daemons support -type f 2>/dev/null | sort)
}

me=$(/usr/bin/id -un)

# ---- As the installer package runs it ----
fresh
sh "$T/bundle/install.sh" --remove-with-app "$me" > /dev/null
check "installer package: install.sh succeeds" 0 $?
check "installer package: the sudoers rule allows that user the two pmset commands and nothing else" \
  "$me ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" \
  "$(cat "$T/sudoers.d/sleepguard" 2>/dev/null)"
check "installer package: the property list is one launchd can read" \
  "$T/daemons/local.sleepguard.enforce.plist: OK" \
  "$(plutil -lint "$T/daemons/local.sleepguard.enforce.plist" 2>&1)"
check "installer package: the backstop is told to remove itself with the app" \
  "/bin/sh|$T/support/enforce.sh|remove-with-app" "$(arguments)"
check "installer package: the daemon's label is the one uninstall.sh stops" \
  "local.sleepguard.enforce" "$(plutil -extract Label raw "$T/daemons/local.sleepguard.enforce.plist" 2>&1)"
check "installer package: the backstop runs every 5 minutes" \
  "300" "$(plutil -extract StartInterval raw "$T/daemons/local.sleepguard.enforce.plist" 2>&1)"
check "installer package: the backstop script is installed unchanged" \
  same "$(cmp -s scripts/enforce.sh "$T/support/enforce.sh" && echo same || echo DIFFERENT)"
check "installer package: the removal script is installed next to it, unchanged" \
  same "$(cmp -s scripts/uninstall.sh "$T/support/uninstall.sh" && echo same || echo DIFFERENT)"
check "installer package: only root can change the property list" \
  644 "$(stat -f %Lp "$T/daemons/local.sleepguard.enforce.plist" 2>&1)"
# The rule is checked before anything is installed, since a broken file in sudoers.d breaks
# sudo. It goes live last, so that a failure on the way never leaves a passwordless rule
# behind with no backstop to remove it. Everything is owned by root and closed to others.
check "installer package: what is installed, owned by whom, in which order" \
"visudo
install -d -o root -g wheel -m 0755 -> $T/support
install -o root -g wheel -m 0755 -> $T/support/enforce.sh
install -o root -g wheel -m 0755 -> $T/support/uninstall.sh
chown root:wheel $T/daemons/local.sleepguard.enforce.plist
launchctl bootout system/local.sleepguard.enforce
launchctl bootstrap system $T/daemons/local.sleepguard.enforce.plist
install -o root -g wheel -m 0440 -> $T/sudoers.d/sleepguard" \
  "$(cat "$T/calls" 2>/dev/null)"

# ---- From a checkout: sudo scripts/install.sh [user] ----
fresh
sh "$T/bundle/install.sh" "$me" > /dev/null
check "checkout: without the option the backstop never removes itself" \
  "/bin/sh|$T/support/enforce.sh" "$(arguments)"

# ---- Installing again ----
fresh
mkdir "$T/support"
: > "$T/support/app-missing"
sh "$T/bundle/install.sh" --remove-with-app "$me" > /dev/null
check "installing again forgets that the app was once seen missing" \
  forgotten "$([ -e "$T/support/app-missing" ] && echo REMEMBERED || echo forgotten)"

# ---- Failures on the way ----
fresh
: > "$T/sudoers-check-fails"
sh "$T/bundle/install.sh" --remove-with-app "$me" > /dev/null 2>&1
check "a sudoers rule that fails its check: install.sh fails" 1 $?
check "...and nothing at all is installed" "" "$(installed)"

fresh
: > "$T/bootstrap-fails"
sh "$T/bundle/install.sh" --remove-with-app "$me" > /dev/null 2>&1
check "the daemon cannot be loaded: install.sh fails" 5 $?
check "...and no passwordless rule is left behind without its backstop" \
  absent "$([ -e "$T/sudoers.d/sleepguard" ] && echo PRESENT || echo absent)"

# ---- A user name is written into a sudoers file, so it is not taken on trust ----

# refused <name of the check> <user name argument>
refused() {
  sh "$T/bundle/install.sh" --remove-with-app "$2" > /dev/null 2>&1
  check "$1: refused, nothing installed" "exit 1, installed ''" "exit $?, installed '$(installed)'"
}

# With an `id` that vouches for every name, only install.sh's own rules stand in the way.
fresh; : > "$T/id-knows-everyone"
refused "a user name carrying sudoers syntax" 'ALL ALL=(ALL) NOPASSWD: ALL #'
fresh; : > "$T/id-knows-everyone"
refused "a user name with a space" 'some one'
fresh; : > "$T/id-knows-everyone"
refused "root as the user" root
fresh; : > "$T/id-knows-everyone"
env -u SUDO_USER sh "$T/bundle/install.sh" --remove-with-app > /dev/null 2>&1
check "no user name and nobody behind sudo: refused, nothing installed" "exit 1, installed ''" "exit $?, installed '$(installed)'"
# With the real `id`: it finds an account by number and in any case, but a sudoers rule under
# such a spelling would not match the account, or would mean something else.
fresh
refused "an account that does not exist" no-such-account-here
fresh
refused "the user's number in place of the name" "$(/usr/bin/id -u)"
fresh
refused "the user's name in the wrong case" "$(echo "$me" | tr '[:lower:]' '[:upper:]')"

# ---- The installer package's postinstall: who the helper is set up for ----

mkdir "$T/pkg-scripts"
sed -e "s#/usr/bin/stat#$T/stat#g" scripts/pkg/postinstall > "$T/pkg-scripts/postinstall"
# postinstall may name these and nothing else outside the scratch folder: it must find
# install.sh next to itself, not in /Applications, where others can write.
strays=$(grep -v '^[[:space:]]*#' "$T/pkg-scripts/postinstall" |
  sed "s#$T/[A-Za-z0-9._/-]*##g" |
  grep -o -E "(^|[[:space:]\"'=>(])/[A-Za-z0-9._-][A-Za-z0-9._/-]*" |
  sed 's#^[^/]*##' | sort -u |
  grep -v -x -e /bin/sh -e /usr/bin/dirname -e /dev/console)
if [ -n "$strays" ]; then
  echo "install: refusing to run postinstall, it still references real system paths:"
  echo "$strays" | sed 's/^/  /'
  exit 1
fi
# In the package install.sh sits next to postinstall; here a stand-in that notes its arguments.
printf '#!/bin/sh\necho "$*" > "%s/install-args"\n' "$T" > "$T/pkg-scripts/install.sh"

# postinstall_as <name of the check> <expected arguments> <environment assignments...>
postinstall_as() {
  name=$1 want=$2
  shift 2
  rm -f "$T/install-args"
  env -u USER -u SUDO_USER "$@" sh "$T/pkg-scripts/postinstall" /dev/null /dev/null /dev/null
  check "$name" "$want" "$(cat "$T/install-args" 2>/dev/null)"
}
postinstall_as "postinstall, opened in the Installer: for the person installing" \
  "--remove-with-app alice" USER=alice
postinstall_as "postinstall, under sudo installer: for the person who ran sudo" \
  "--remove-with-app bob" USER=root SUDO_USER=bob
postinstall_as "postinstall, with neither to go by: for whoever is logged in at the screen" \
  "--remove-with-app carol" USER=root

if [ "$failures" -eq 0 ]; then echo "install: $checks checks passed"; else echo "install: $failures of $checks checks FAILED"; fi
[ "$failures" -eq 0 ]
