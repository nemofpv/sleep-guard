# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SleepGuard is a macOS menu bar app (Swift/AppKit, macOS 13+) that toggles `pmset -a disablesleep` and guarantees that every "keep awake" expires. There is no Xcode project, no SwiftPM package and no dependencies: `scripts/build.sh` compiles `Sources/SleepGuard/*.swift` with `swiftc` and assembles the bundle by hand. README.md describes the user-facing behaviour, including a table of what happens when `pmset` is changed outside the app; keep it in step with behaviour changes.

## Commands

```sh
scripts/test.sh                                      # all tests: policy checks, then enforce.sh against a fake pmset
scripts/build.sh                                     # build/SleepGuard.app for this machine's architecture
VERSION=1.2.0 UNIVERSAL=1 scripts/build.sh           # what the release workflow runs
scripts/package.sh                                   # build/SleepGuard-<version>.dmg from the built app
pkill -x SleepGuard; open build/SleepGuard.app       # relaunch; `open` alone does not load a rebuilt binary while the old one runs
swift scripts/make-icon.swift Resources/icon-source.jpg Resources/AppIcon.png   # only when the artwork changes
```

There is no way to run a single test; both suites together take a few seconds. The tests are plain programs rather than XCTest, so they run with the Command Line Tools alone, which do not include XCTest. A failing check prints `FAIL` with the expected and actual values, and the suite exits non-zero.

Inspecting state while debugging:

```sh
pmset -g | grep SleepDisabled             # the real system flag
cat /Users/Shared/SleepGuard/expires-at   # epoch seconds; file absent = no active keep-awake
defaults read local.sleepguard            # app preferences (offOnBattery)
```

The tests and the build never touch the real power settings. Running the app does, system-wide, and can raise an admin password prompt. If a manual test leaves sleep disabled, restore it with `sudo pmset -a disablesleep 0`. Do not run `scripts/install.sh`: it needs sudo and installs a sudoers rule and a root LaunchDaemon on this machine.

## Architecture

There are two pieces of state, and most of the code exists to keep them consistent:

1. **The system flag**: `SleepDisabled` in `pmset -g` output. It is the only truth about whether sleep is disabled. The app re-reads it after every write, on every tick and on every menu open; it never trusts a cached value or an exit status. `nil` means the output could not be parsed, and nothing is changed on a `nil`.
2. **The expiry file**: `/Users/Shared/SleepGuard/expires-at`, epoch seconds as 1–12 ASCII digits.

The invariant is: sleep disabled ⇒ an unexpired expiry exists. Either side can also be changed from a terminal at any time, so each tick reconciles them rather than assuming the app made the last change.

### Where the logic lives

- `Sources/SleepGuard/Policy.swift` holds every decision as a pure function. `tickAction(Snapshot)` maps what a tick observes to one action: nothing, clear a stale expiry, adopt an expiry, or turn off. New behaviour goes here, test first, in `Tests/PolicyTests/main.swift`.
- `Sources/SleepGuard/main.swift` is the I/O and the menu: it builds the `Snapshot`, carries out the action, and rebuilds the menu from scratch in `menuNeedsUpdate` each time it opens. It has no tests, so keep it thin.
- `scripts/enforce.sh` is the root backstop for when the app is not running, installed as a LaunchDaemon that runs every 5 minutes. `Tests/enforce-test.sh` runs the real script with its system paths rewritten by `sed` to a scratch directory; that only works while the script spells those paths out in full (`/usr/bin/pmset`, `/Users/Shared/SleepGuard/expires-at`, `/usr/bin/logger`, `/bin/sleep`), and the test refuses to run otherwise.

### Contracts duplicated across files

Change these together:

- **Expiry path and format**: `main.swift`, `parseExpiry` in `Policy.swift`, and `read_expiry` in `enforce.sh`. Both parsers must accept exactly the same strings. "Indefinitely" is the timestamp `253402300799` (year 9999) so that neither needs a special case.
- **Backstop location**: the LaunchDaemon label `local.sleepguard.enforce` appears in `install.sh`, `uninstall.sh`, and `backstopPlist` in `main.swift`. The app checks that the plist exists only to decide whether the Quit item may say "expiry is still enforced". Quit itself never changes the sleep setting; stopping a keep-awake is the separate "Allow sleep now" item, and the two stay separate.
- **Timing**: the app ticks every 15 s; `enforce.sh` waits `GRACE_SECONDS=20` before overriding a `disablesleep` that has no expiry, so that a running app can adopt it first. The grace must stay longer than the tick.

### Ordering that must be preserved

- `setOn` writes the expiry before disabling sleep and removes it again if the `pmset` write fails. If sleep is already disabled it only rewrites the expiry, which needs no privileges.
- `setOff` removes the expiry only after sleep is confirmed re-enabled, so a failed turn-off is retried.
- The `writing` flag keeps `tick()` out while a privileged write is in flight. Without it, a tick during the admin prompt would see the expiry file with sleep still allowed and delete it as stale.

### Privileges

`writeSleepDisabled` first tries `sudo -n pmset …`, which succeeds only with the sudoers rule from `install.sh`. Otherwise it falls back to an AppleScript admin prompt; the prompt text is interpolated into AppleScript source, so it must stay free of quotes and backslashes. An automatic turn-off that fails sets `retryNotBefore`, which suppresses further attempts for 5 minutes so the prompt is not raised on every tick.

`enforce.sh` runs as root and reads a file an ordinary user controls. It may only compare that content as a number. It must not write into `/Users/Shared/SleepGuard`, because a root write into a user-writable directory can be redirected with a symlink. `install.sh` copies `enforce.sh` to a root-owned location for the same reason: root must never execute a script from a user-writable path.

## Build and release

- `build/` is disposable output. `build.sh` regenerates `Info.plist` from a heredoc, so bundle metadata is edited in `build.sh`. The bundle ID `local.sleepguard` is also the UserDefaults domain; changing it resets the user's `offOnBattery` preference.
- `build.sh` copies `enforce.sh`, `install.sh` and `uninstall.sh` into `Contents/Resources`, so `install.sh` must keep finding `enforce.sh` next to itself.
- `Resources/AppIcon.png` is generated from `Resources/icon-source.jpg`; edit the artwork, not the PNG.
- `scripts/package.sh` packs the built app and an `Applications` symlink into the disk image. `Resources/dmg-layout` is a Finder `.DS_Store` that it copies in to fix the window size and icon positions; it is generated by `scripts/make-dmg-layout.py`, which needs the `ds_store` Python package and is run only when the layout changes. The layout is keyed by file name, so the names `SleepGuard.app` and `Applications` must match in both scripts.
- `.github/workflows/ci.yml` runs `scripts/test.sh`, a universal build and `scripts/package.sh` on pushes that change `Sources/`, `Tests/`, `scripts/`, `Resources/AppIcon.png`, `Resources/dmg-layout` or the workflow itself. Anything else (documentation, the icon artwork, the release workflow) is deliberately skipped, because it cannot change the result and macOS runners are billed at ten times the Linux rate while the repository is private. A new file or folder that the build or the tests read must be added to `paths` there, or changes to it go unchecked.
- `.github/workflows/release.yml` publishes a release when a tag matching `v1.2.3` is pushed, and does a non-publishing dry run on manual dispatch. The app is signed ad hoc and not notarized.
