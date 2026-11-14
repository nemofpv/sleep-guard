# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SleepGuard is a macOS menu bar app (one Swift/AppKit file, macOS 13+) that toggles `pmset -a disablesleep` and guarantees that every "keep awake" expires. There is no Xcode project, no SwiftPM package, no dependencies, no tests and no linter — `main.swift` is compiled directly with `swiftc`.

## Commands

```sh
./build.sh                                # rebuild SleepGuard.app from scratch (swiftc -O, then ad-hoc codesign)
swiftc -typecheck main.swift              # fast compile check that leaves the bundle alone
pkill -x SleepGuard; open SleepGuard.app  # relaunch; `open` alone does not load a rebuilt binary while the old one runs
```

Inspecting state while debugging:

```sh
pmset -g | grep SleepDisabled             # the real system flag
cat /Users/Shared/SleepGuard/expires-at   # epoch seconds; file absent = no active keep-awake
defaults read local.sleepguard            # app preferences (offOnBattery)
```

Running the app and using its menu changes a system-wide power setting and can raise an admin password prompt. If a test leaves sleep disabled, restore it with `sudo pmset -a disablesleep 0`.

## Architecture

There are two pieces of state, and most of the code exists to keep them consistent:

1. **The system flag** — `SleepDisabled` in `pmset -g` output. It is the only truth about whether sleep is disabled. The app never trusts a cached value or an exit status: it re-reads the flag after every write, on every tick and on every menu open. `state` is `Bool?`, where `nil` means the output could not be parsed.
2. **The expiry file** — `/Users/Shared/SleepGuard/expires-at`, a plain integer of epoch seconds.

The invariant is: sleep disabled ⇒ an unexpired expiry exists. Two things enforce it:

- **`tick()` in the app, every 15 s.** Re-enables sleep once the expiry has passed. If sleep is disabled but there is no expiry file (someone ran `pmset` outside the app), it adopts `defaultExpiry()` rather than leaving it open-ended. It also re-enables sleep on battery power when `offOnBattery` is set (default true), so with that preference on, a keep-awake started on battery is cancelled within one tick.
- **`enforce.sh`, the root backstop** for when the app is not running. It treats a missing or non-numeric expiry as 0 and re-enables sleep immediately — unlike the app, which adopts a default expiry in that case. It logs resets with `logger -t sleepguard`.

### The contract between `main.swift` and `enforce.sh`

The expiry path and file format are duplicated in both files; change them together. "Indefinitely" is stored as an expiry of `253402300799` (year 9999) specifically so that `enforce.sh` needs no special case — keep it a plain numeric timestamp.

### Ordering that must be preserved

- `setOn` writes the expiry *before* disabling sleep, and deletes it again if the `pmset` write fails, so the backstop never sees disabled sleep without an expiry.
- `setOff` deletes the expiry only *after* sleep is confirmed re-enabled, so a failed turn-off is retried on the next tick.
- `extend` only rewrites the expiry file; it makes no `pmset` call.

### Privileges

`writeSleepDisabled` first tries `sudo -n pmset …`, which succeeds only if a passwordless sudoers rule for `pmset` is installed. Otherwise it falls back to an AppleScript `with administrator privileges` prompt. Success is decided by re-reading the flag.

### Default expiry policy

`defaultExpiry()` lasts until 23:00 (`eveningCutoffHour`). Between 23:00 and 07:00 (`morningHour`) it is only 2 hours, so a forgotten toggle never runs through the night.

### Menu

The menu is rebuilt from scratch in `menuNeedsUpdate` each time it opens; which items appear depends on whether sleep is allowed, disabled with a timed expiry, or disabled indefinitely.

## Gotchas

- `SleepGuard.app` is build output. `build.sh` deletes it and regenerates `Info.plist` from a heredoc, so bundle metadata (bundle ID, `LSUIElement`, minimum OS) is edited in `build.sh`, never in the bundle. The bundle ID `local.sleepguard` is also the UserDefaults domain; changing it resets the user's `offOnBattery` preference.
- Comments in `main.swift` and `enforce.sh` refer to an `install.sh` that installs a LaunchDaemon (running `enforce.sh` every 5 minutes) and the passwordless sudoers rule. Neither `install.sh` nor a LaunchDaemon plist is in this repository, and `enforce.sh` is not marked executable. Do not assume the backstop or the sudoers rule is installed on the machine.
