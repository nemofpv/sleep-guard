# SleepGuard

<img src="Resources/AppIcon.png" width="128" alt="SleepGuard icon">

A macOS menu bar toggle for `pmset disablesleep` that always expires.

`sudo pmset -a disablesleep 1` keeps a Mac awake even with the lid closed, and stays on until someone remembers to turn it off. SleepGuard puts that switch in the menu bar and gives every "keep awake" an end time, so a forgotten toggle cannot run through the night or drain a laptop in a bag.

Requires macOS 13 or later.

## Install

Download `SleepGuard-<version>.pkg` from the [latest release](https://github.com/nemofpv/sleep-guard/releases/latest), open it and follow the installer. It asks for an admin password once, puts SleepGuard into the Applications folder and sets up [the helper](#what-the-installer-sets-up) that spares you a password prompt on every change. Every release is a universal build for Apple silicon and Intel.

The package is not notarized, so macOS refuses to open a copy downloaded with a browser on the first try. Go to System Settings → Privacy & Security, find the note about the package and click **Open Anyway**. Installing from a terminal skips that step:

```sh
gh release download --repo nemofpv/sleep-guard --pattern '*.pkg'
sudo installer -pkg SleepGuard-*.pkg -target /
```

From source (needs the Xcode Command Line Tools):

```sh
scripts/build.sh
scripts/package.sh
open build/SleepGuard-0.0.0.pkg
```

To start SleepGuard at login, add it under System Settings → General → Login Items.

To update, quit SleepGuard, install the newer package over the old one and open SleepGuard again. SleepGuard [tells you](#update-check) when there is a newer release.

### What the installer sets up

Changing `disablesleep` needs root. Without help, macOS would ask for an admin password every time SleepGuard turns keep-awake on or off, including the automatic turn-off when the time runs out. So the installer adds two things outside the app:

- **A sudoers rule** in `/etc/sudoers.d/sleepguard` that lets the user who ran the installer run exactly two commands without a password: `pmset -a disablesleep 0` and `pmset -a disablesleep 1`. Nothing else becomes passwordless.
- **A backstop** in `/Library/LaunchDaemons/local.sleepguard.enforce.plist`, with its two scripts in `/Library/Application Support/SleepGuard`. It checks every 5 minutes as root and re-enables sleep once the expiry has passed. With it, the expiry holds even if the app has crashed or been force-quit.

### Update check

When it starts, and once a day after that, SleepGuard asks GitHub for the number of the latest release. If that is newer than the installed version, **Update available** appears at the top of the menu, under the status block, and clicking it opens the release page in the browser. Nothing is downloaded or installed on its own.

This is the only use SleepGuard makes of the network. The request carries nothing about you or the Mac; GitHub sees the IP address it comes from, as with any web request. To switch the check off:

```sh
defaults write local.sleepguard checkForUpdates -bool false
```

That applies from the next start of SleepGuard at the latest. A build from source that was given no `VERSION` shows `v0.0.0` and never checks.

## Uninstall

Quit SleepGuard and drag it from Applications to the Trash. Within about ten minutes the backstop notices that the app is gone and removes itself and the sudoers rule. If the Mac is shut down before that, it finishes within a few minutes of the next start. That removal deletes the files listed above and nothing else. If a keep-awake was still running, because the app was force-quit rather than quit, the backstop ends it first and removes itself on its next check: a keep-awake does not outlive the app that could show or stop it.

To remove both at once instead of waiting:

```sh
sudo "/Library/Application Support/SleepGuard/uninstall.sh"
```

Left behind are the app's preferences, the folder `/Users/Shared/SleepGuard` and the installer's receipt. To clear those too:

```sh
defaults delete local.sleepguard
rm -rf /Users/Shared/SleepGuard
sudo pkgutil --forget local.sleepguard.pkg
```

## Using it

Click the menu bar icon. The top of the menu says what the Mac is doing; under **Keep awake**, pick how long to stay awake:

| Choice | Lasts until |
|---|---|
| Until tonight, 23:00 | tonight's cutoff. Not offered between 23:00 and 07:00, when it would be the same as 2 hours |
| For 1 hour / 2 hours / 4 hours | that long from now |
| Until morning, 07:00 | the next 07:00 |
| Indefinitely | you turn it off |

While it is on, the menu bar icon is a coffee cup with the time left, and the menu changes to:

- **Allow sleep now** ends the keep-awake and leaves SleepGuard running.
- **Add 1 hour / Add 2 hours** push the end time back.
- **Change to** opens the same list of choices, to replace the end time without stopping first.

Gold icons keep the Mac awake, blue ones let it sleep. The installed version is in the top right corner of the menu.

**Allow sleep when unplugged** (on by default) ends keep-awake within 15 seconds of the Mac going onto battery. While it is checked and the Mac is on battery, the keep-awake choices are greyed out.

## What happens when…

| Situation | Result |
|---|---|
| You run `sudo pmset -a disablesleep 1` in a terminal | Within 15 seconds SleepGuard adopts it and gives it the default expiry, as if you had picked "Until tonight, 23:00". On battery with "Allow sleep when unplugged" checked, it is turned off instead. |
| The same, but SleepGuard is not running | With the backstop installed, sleep is re-enabled within about 5 minutes. Without it, sleep stays disabled until SleepGuard is next started, which then adopts it. |
| You run `sudo pmset -a disablesleep 0` during a keep-awake | SleepGuard notices within 15 seconds, discards the expiry and notes it in the menu. A later manual enable starts fresh. |
| The expiry passes | Sleep is re-enabled by the app, or by the backstop within 5 minutes if the app is not running. |
| The expiry passes and the sudoers rule is not installed | macOS asks for an admin password. If nobody answers or the prompt is cancelled, the icon becomes a warning triangle and SleepGuard asks again every 5 minutes. **Allow sleep now** retries at once. |
| You quit SleepGuard during a keep-awake | The menu item reads **Quit and allow sleep**: sleep is re-enabled, then the app closes. If sleep cannot be re-enabled, the app stays open and the menu says why. |
| SleepGuard crashes or is force-quit during a keep-awake | With the backstop installed the expiry is still enforced. Without it, sleep stays disabled until SleepGuard runs again and picks the expiry back up. This is the case the backstop exists for. |
| `/Users/Shared/SleepGuard/expires-at` is deleted or holds anything but a timestamp | It counts as "no expiry". The app assigns the default expiry; if the app is not running, the backstop re-enables sleep. |
| You drag SleepGuard to the Trash | Within about ten minutes the backstop removes itself and the sudoers rule. A keep-awake left running by a force-quit, "Indefinitely" included, is ended first. |
| You move SleepGuard out of Applications, or rename it | The backstop cannot tell that from deleting it, so it ends a running keep-awake and removes itself and the sudoers rule. SleepGuard keeps working but asks for a password on every change; run the installer again to put things back. |

## Development

```sh
scripts/test.sh     # policy tests, then the root scripts against a fake pmset and scratch folders
scripts/build.sh    # build/SleepGuard.app
scripts/package.sh  # build/SleepGuard-<version>.pkg from the built app
```

None of them touches the real power settings or installs anything. Running the app changes the power settings; opening the package installs the helper.

GitHub Actions runs all three on every push that changes the sources, tests, scripts or icon. Pushes that only touch documentation are skipped.

| Path | Contents |
|---|---|
| `Sources/SleepGuard/Policy.swift` | The decisions: parsing, expiry arithmetic, what each 15-second tick should do, when to look for an update and whether a release is newer. No I/O. |
| `Sources/SleepGuard/main.swift` | The menu and the I/O: `pmset`, the expiry file, the power source. |
| `Sources/SleepGuard/MenuLook.swift` | How the menu looks: the badge icons, their colours, the status block at the top. |
| `Sources/SleepGuard/UpdateCheck.swift` | The request to GitHub for the latest release. The only network code. |
| `scripts/enforce.sh` | The backstop that the LaunchDaemon runs as root. |
| `scripts/install.sh`, `uninstall.sh` | Set up and remove the sudoers rule and the backstop. From a checkout, `sudo scripts/install.sh` sets them up to stay until `sudo scripts/uninstall.sh`. |
| `scripts/pkg/postinstall` | What the installer package runs after copying the app: `install.sh`, for the person installing. `package.sh` packs the three scripts above into the package next to it. |
| `scripts/make-icon.swift` | Rebuilds `Resources/AppIcon.png` from `Resources/icon-source.jpg`. |
| `Tests/` | The test programs that `scripts/test.sh` runs. |

## Releasing

A release is published when a version tag is pushed. Pushing commits alone never publishes one.

```sh
git tag v1.2.0
git push origin v1.2.0
```

The Release workflow runs the tests, builds the universal app with that version number, and publishes `SleepGuard-1.2.0.pkg` with a SHA-256 checksum on the [releases page](https://github.com/nemofpv/sleep-guard/releases). Running the workflow by hand from the Actions tab does a dry run: the same build, kept as a workflow artifact, with nothing published.

## License

MIT. See [LICENSE](LICENSE).
