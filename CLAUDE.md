# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SleepGuard is a macOS menu bar app (Swift/AppKit, macOS 13+) that toggles `pmset -a disablesleep` and guarantees that every "keep awake" expires. There is no Xcode project, no SwiftPM package and no dependencies: `scripts/build.sh` compiles `Sources/SleepGuard/*.swift` with `swiftc` and assembles the bundle by hand. README.md describes the user-facing behaviour, including a table of what happens when `pmset` is changed outside the app; keep it in step with behaviour changes.

## Commands

```sh
scripts/test.sh                                      # all tests: policy checks, then the root scripts against a fake pmset and scratch folders
scripts/build.sh                                     # build/SleepGuard.app for this machine's architecture
VERSION=1.2.0 UNIVERSAL=1 scripts/build.sh           # what the release workflow runs
scripts/package.sh                                   # build/SleepGuard-<version>.pkg from the built app
pkill -x SleepGuard; open build/SleepGuard.app       # relaunch; `open` alone does not load a rebuilt binary while the old one runs
swift scripts/make-icon.swift Resources/icon-source.jpg Resources/AppIcon.png   # only when the artwork changes
```

There is no way to run a single check; the three suites together take a few seconds. The tests are plain programs rather than XCTest, so they run with the Command Line Tools alone, which do not include XCTest. A failing check prints `FAIL` with the expected and actual values, and the suite exits non-zero.

Inspecting state while debugging:

```sh
pmset -g | grep SleepDisabled             # the real system flag
cat /Users/Shared/SleepGuard/expires-at   # epoch seconds; file absent = no active keep-awake
defaults read local.sleepguard            # app preferences (offOnBattery)
```

The tests and the build never touch the real power settings. Running the app does, system-wide, and can raise an admin password prompt. If a manual test leaves sleep disabled, restore it with `sudo pmset -a disablesleep 0`. Do not run `scripts/install.sh`: it needs sudo and installs a sudoers rule and a root LaunchDaemon on this machine. For the same reason do not open or install the package that `scripts/package.sh` builds; look inside it with `pkgutil --expand-full` instead.

## Architecture

There are two pieces of state, and most of the code exists to keep them consistent:

1. **The system flag**: `SleepDisabled` in `pmset -g` output. It is the only truth about whether sleep is disabled. The app re-reads it after every write, on every tick and on every menu open; it never trusts a cached value or an exit status. `nil` means the output could not be parsed, and nothing is changed on a `nil`.
2. **The expiry file**: `/Users/Shared/SleepGuard/expires-at`, epoch seconds as 1–12 ASCII digits.

The invariant is: sleep disabled ⇒ an unexpired expiry exists. Either side can also be changed from a terminal at any time, so each tick reconciles them rather than assuming the app made the last change.

### Where the logic lives

- `Sources/SleepGuard/Policy.swift` holds every decision as a pure function. `tickAction(Snapshot)` maps what a tick observes to one action: nothing, clear a stale expiry, adopt an expiry, or turn off. New behaviour goes here, test first, in `Tests/PolicyTests/main.swift`.
- `Sources/SleepGuard/main.swift` is the I/O and the menu: it builds the `Snapshot`, carries out the action, and rebuilds the menu from scratch in `menuNeedsUpdate` each time it opens. It has no tests, so keep it thin.
- `Sources/SleepGuard/MenuLook.swift` is the menu's appearance: `badge()` draws the row icons and `statusHeader()` the block at the top. The palette comes from the app icon, not the system colours: gold (`.awake`) for everything that keeps the Mac awake, night blue (`.sleep`) for everything that lets it sleep, grey (`.neutral`) for the rest, red (`.alert`) only for a failure. Keep new rows inside that scheme. The menu cannot be seen from a terminal; to check a visual change, compile `MenuLook.swift` together with a throwaway `main.swift` that draws the badges into a PNG, and look at that.
- `scripts/enforce.sh` is the root backstop for when the app is not running, installed as a LaunchDaemon that runs every 5 minutes. Installed by the package, it also removes itself once the app has been deleted; see "Self-removal" below.
- `scripts/install.sh` and `scripts/uninstall.sh` set up and remove the sudoers rule and the backstop. `scripts/pkg/postinstall` is what the installer package runs as root: `install.sh --remove-with-app`, for the person installing.
- `Tests/enforce-test.sh` runs the real `enforce.sh` and `uninstall.sh`, and `Tests/install-test.sh` the real `install.sh` and `postinstall`, with their system paths rewritten by `sed` to a scratch directory and stand-ins for `pmset`, `launchctl`, `id` and the like. That only works while the scripts spell those paths out in full (`/usr/bin/pmset`, `/Users/Shared/SleepGuard`, `/usr/bin/logger`, `/bin/sleep`, `/bin/launchctl`, `/usr/bin/id`, `/usr/bin/install`, `/usr/sbin/chown`, `/usr/sbin/visudo`, `/usr/bin/stat`, `/Applications`, `/etc/sudoers.d`, `/Library/LaunchDaemons`, `/Library/Application Support/SleepGuard`). After the rewrite each test lists the absolute paths still in the script and refuses to run it unless every one is on a short list of harmless tools; a new tool has to be added to that list. Do not weaken this: a script run with a real path left in it deletes or runs the real thing.

### Contracts duplicated across files

Change these together:

- **Expiry path and format**: `main.swift`, `parseExpiry` in `Policy.swift`, and `read_expiry` in `enforce.sh`. Both parsers must accept exactly the same strings. "Indefinitely" is the timestamp `253402300799` (year 9999) so that neither needs a special case.
- **Backstop location**: the LaunchDaemon label `local.sleepguard.enforce` appears in both `install.sh` and `uninstall.sh`. Every file `install.sh` creates is listed by its full path in `uninstall.sh`; a new one has to be added there by hand. The app itself does not look for the backstop.
- **Self-removal switch**: the word `remove-with-app` is passed by `postinstall`, written into the LaunchDaemon's arguments by `install.sh` and tested by `enforce.sh`.
- **App location**: `/Applications/SleepGuard.app` is fixed in `enforce.sh`, in `postinstall` and, as install location plus bundle name, in `package.sh`.
- **Quit**: while a keep-awake is on, the item reads "Quit and allow sleep" and re-enables sleep before quitting, whether or not the backstop is installed. The user asked for exactly this and rejected both a plain Quit and a "Quit (expiry is still enforced)" variant; do not make it conditional again.
- **Timing**: the app ticks every 15 s; `enforce.sh` waits `GRACE_SECONDS=20` before overriding a `disablesleep` that has no expiry, so that a running app can adopt it first. The grace must stay longer than the tick.

### Ordering that must be preserved

- `setOn` writes the expiry before disabling sleep and removes it again if the `pmset` write fails. If sleep is already disabled it only rewrites the expiry, which needs no privileges.
- `setOff` removes the expiry only after sleep is confirmed re-enabled, so a failed turn-off is retried.
- The `writing` flag keeps `tick()` out while a privileged write is in flight. Without it, a tick during the admin prompt would see the expiry file with sleep still allowed and delete it as stale.

### Self-removal

Dragging the app to the Trash runs no code of the app's, so the backstop is what cleans up after it. The user's requirement, put very firmly, is that this removal can do nothing except remove the helper. Do not loosen any of the following:

- `uninstall.sh` is the only removal code, for a person with `sudo` and for the backstop alike. The backstop `exec`s its root-owned copy and passes it nothing. The script takes no input, and each deletion names one spelled-out file that `install.sh` created in a folder only root can write to: no variables, no wildcards, no recursive delete, and `rmdir` for the folder, so that a file somebody else put there keeps it in place. It touches nothing under `/Users` or `/Applications` and never calls `pmset`.
- `Tests/enforce-test.sh` holds a copy of `uninstall.sh`'s commands, and of every line in `enforce.sh` that deletes or writes a file, and refuses to run anything if they differ. A change to what root deletes is therefore made in two places on purpose. The test then runs the removal in a scratch tree with a bystander next to every piece and checks that only the pieces are gone.
- The order in `uninstall.sh`: the sudoers rule first, since it is the piece that matters if the run is cut short; the property list next, so that a half-finished removal is not started again at every boot with pieces missing; `launchctl bootout` last, because it kills the script on the spot when the daemon is the one running it.
- The trigger in `enforce.sh` needs all of: the argument `remove-with-app`, which only the installer package sets, so a backstop installed from a checkout never removes itself; `/Applications` present and `/Applications/SleepGuard.app` absent on two runs in a row, remembered in the marker file `app-missing` in the backstop's own root-owned folder, which covers the moment an update replaces the app; and `SleepDisabled` reading exactly `0`, so the removal never coincides with a change to the power settings.
- A keep-awake does not outlive the app. If the app is gone (two runs in a row) while sleep is disabled, the backstop re-enables sleep whatever the expiry says, and removes itself on the next run. Without this, "Indefinitely" followed by a restart and the Trash would keep the Mac awake and the backstop installed for good. This is `enforce.sh` doing its ordinary job with the one `pmset` command it has always run; `uninstall.sh` stays free of it.
- Moving or renaming the app counts as deleting it. That is accepted and described in the README.

### Privileges

`writeSleepDisabled` first tries `sudo -n pmset …`, which succeeds only with the sudoers rule from `install.sh`. Otherwise it falls back to an AppleScript admin prompt; the prompt text is interpolated into AppleScript source, so it must stay free of quotes and backslashes. An automatic turn-off that fails sets `retryNotBefore`, which suppresses further attempts for 5 minutes so the prompt is not raised on every tick.

`enforce.sh` runs as root and reads a file an ordinary user controls. It may only compare that content as a number. It must not create, write or delete anything in `/Users/Shared/SleepGuard`, because whatever root does in a user-writable directory can be redirected with a symlink. After it has reset sleep it leaves the expiry file where it is; the app's next tick clears it as stale. `install.sh` copies `enforce.sh` and `uninstall.sh` to a root-owned location for the same reason: root must never execute a script from a user-writable path. That includes the app in `/Applications`, which any admin account can replace: the installer package carries the scripts itself and `postinstall` runs the `install.sh` next to it.

`install.sh` writes a user name into a sudoers file. It accepts only a plain name that `id -un` gives back unchanged, checks the rule with `visudo` before installing anything, and puts the rule in place last, after the daemon is loaded, so that a failure on the way cannot leave a passwordless rule behind with no backstop.

## Build and release

- `build/` is disposable output. `build.sh` regenerates `Info.plist` from a heredoc, so bundle metadata is edited in `build.sh`. The bundle ID `local.sleepguard` is also the UserDefaults domain; changing it resets the user's `offOnBattery` preference.
- The app bundle carries no scripts. `package.sh` packs `install.sh`, `enforce.sh` and `uninstall.sh` into the package's scripts folder next to `postinstall`, so `install.sh` must keep finding the other two next to itself, there as in `scripts/`.
- `Resources/AppIcon.png` is generated from `Resources/icon-source.jpg`; edit the artwork, not the PNG.
- `scripts/package.sh` packs the built app into an installer package with `pkgbuild`. The package installs the app into `/Applications` and then runs `scripts/pkg/postinstall`. Its component property list switches relocation off: by default the Installer would update a copy of the app wherever it finds one, such as `build/SleepGuard.app` in a checkout, instead of installing into `/Applications`. The payload holds only `SleepGuard.app`, not an `Applications` folder around it. There is no disk image any more: the user chose the installer over drag-to-install so that nobody has to run a script by hand.
- `.github/workflows/ci.yml` runs `scripts/test.sh`, a universal build and `scripts/package.sh` on pushes that change `Sources/`, `Tests/`, `scripts/`, `Resources/AppIcon.png` or the workflow itself. Anything else (documentation, the icon artwork, the release workflow) is deliberately skipped, because it cannot change the result and macOS runners are billed at ten times the Linux rate while the repository is private. A new file or folder that the build or the tests read must be added to `paths` there, or changes to it go unchecked.
- `.github/workflows/release.yml` publishes a release when a tag matching `v1.2.3` is pushed, and does a non-publishing dry run on manual dispatch. The app is signed ad hoc and not notarized, and the package is not signed.
