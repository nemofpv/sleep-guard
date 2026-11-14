// SleepGuard — menu bar toggle for `pmset disablesleep` that always expires.
//
// Every "keep awake" has an expiry time, written to /Users/Shared/SleepGuard/expires-at.
// The app turns sleep back on when it passes. scripts/install.sh adds a root LaunchDaemon that
// does the same every 5 minutes, so the expiry also holds while this app is not running.
//
// This file does the I/O and the menu; the decisions live in Policy.swift.

import AppKit
import IOKit.ps

let pmsetPath = "/usr/bin/pmset"
let sharedDir = "/Users/Shared/SleepGuard"
let expiryPath = sharedDir + "/expires-at"
/// Written by scripts/install.sh. When it exists, enforce.sh runs whether or not this app does.
let backstopPlist = "/Library/LaunchDaemons/local.sleepguard.enforce.plist"
/// How long to wait after an automatic turn-off failed before trying, and possibly prompting, again.
let autoOffRetryInterval: TimeInterval = 5 * 60

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// nil when pmset output can't be read.
func readSleepDisabled() -> Bool? {
    parseSleepDisabled(pmsetOutput: run(pmsetPath, ["-g"]).out)
}

/// Uses the passwordless sudoers rule from scripts/install.sh; without it, asks for an admin
/// password, showing `why` in the prompt. `why` must not contain quotes or backslashes.
func writeSleepDisabled(_ on: Bool, why: String) -> Bool {
    let value = on ? "1" : "0"
    if run("/usr/bin/sudo", ["-n", pmsetPath, "-a", "disablesleep", value]).status != 0 {
        let script = "do shell script \"\(pmsetPath) -a disablesleep \(value)\" with prompt \"\(why)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }
    return readSleepDisabled() == on
}

func readExpiry() -> Date? {
    (try? String(contentsOfFile: expiryPath, encoding: .utf8)).flatMap(parseExpiry)
}

/// nil removes the file. False when the file could not be written or removed.
@discardableResult
func writeExpiry(_ date: Date?) -> Bool {
    let fm = FileManager.default
    guard let date else {
        try? fm.removeItem(atPath: expiryPath)
        return !fm.fileExists(atPath: expiryPath)
    }
    do {
        try fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
        try String(Int(date.timeIntervalSince1970)).write(toFile: expiryPath, atomically: true, encoding: .utf8)
        return true
    } catch {
        return false
    }
}

func onBattery() -> Bool {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return (type as String) == kIOPMBatteryPowerKey
}

let timeFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var state: Bool?
    private var lastMessage: String?
    /// Set while an automatic turn-off is failing. See Snapshot.retryNotBefore.
    private var retryNotBefore: Date?
    /// True while a privileged write is in flight, which can mean waiting at the admin prompt.
    /// A tick in that window would see the expiry file and the pmset flag out of step.
    private var writing = false

    private var offOnBattery: Bool {
        get { UserDefaults.standard.object(forKey: "offOnBattery") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "offOnBattery") }
    }

    private var backstopInstalled: Bool { FileManager.default.fileExists(atPath: backstopPlist) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        tick()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard !writing else { return }
        state = readSleepDisabled()
        let snapshot = Snapshot(sleepDisabled: state, expiry: readExpiry(), onBattery: onBattery(),
                                offOnBattery: offOnBattery, now: Date(), retryNotBefore: retryNotBefore)
        switch tickAction(snapshot) {
        case .none:
            break
        case .clearStaleExpiry:
            if writeExpiry(nil) { lastMessage = "Sleep was re-enabled outside SleepGuard" }
        case .adoptExpiry(let expiry):
            lastMessage = writeExpiry(expiry)
                ? "Disabled outside SleepGuard → expires \(timeFormat.string(from: expiry))"
                : "Sleep is disabled with no expiry: cannot write \(expiryPath)"
        case .turnOff(.expired(let expiry)):
            setOff("Expired at \(timeFormat.string(from: expiry))", automatic: true)
        case .turnOff(.onBattery):
            setOff("On battery power", automatic: true)
        }
        if state != true { retryNotBefore = nil }
        updateButton()
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let symbol: String
        switch state {
        case true?: symbol = retryNotBefore == nil ? "cup.and.saucer.fill" : "exclamationmark.triangle.fill"
        case false?: symbol = "moon.zzz"
        case nil: symbol = "questionmark.circle"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SleepGuard")
        button.image?.isTemplate = true
        if state == true, let exp = readExpiry() {
            button.title = isIndefinite(exp) ? " ∞" : " " + formatRemaining(exp.timeIntervalSinceNow)
        } else {
            button.title = ""
        }
    }

    private func setOn(until expiry: Date) {
        writing = true
        defer { writing = false }
        let alreadyOn = readSleepDisabled() == true
        // The expiry goes on file before sleep is disabled, so the two are never seen the other way round.
        if !writeExpiry(expiry) {
            lastMessage = "Could not save the expiry: nothing changed"
        } else if alreadyOn || writeSleepDisabled(true, why: "SleepGuard wants to keep this Mac awake.") {
            // Already on means only the expiry changed, which needs no admin rights.
            lastMessage = nil
            retryNotBefore = nil
        } else {
            writeExpiry(nil)
            lastMessage = "Could not disable sleep"
        }
        state = readSleepDisabled()
        updateButton()
    }

    /// `automatic` marks a turn-off the user did not ask for just now; if it fails it is retried
    /// after `autoOffRetryInterval` rather than on the next tick.
    private func setOff(_ reason: String?, automatic: Bool = false) {
        writing = true
        defer { writing = false }
        let why = automatic
            ? "SleepGuard: the keep-awake period is over. Allow this Mac to sleep again."
            : "SleepGuard wants to let this Mac sleep again."
        if writeSleepDisabled(false, why: why) {
            writeExpiry(nil)
            retryNotBefore = nil
            lastMessage = reason.map { "\($0) → sleep allowed" }
        } else {
            if automatic { retryNotBefore = Date().addingTimeInterval(autoOffRetryInterval) }
            lastMessage = (reason.map { "\($0), but could" } ?? "Could") + " not re-enable sleep!"
        }
        state = readSleepDisabled()
        updateButton()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        state = readSleepDisabled()
        updateButton()
        menu.removeAllItems()

        let status: String
        switch state {
        case true?:
            let exp = readExpiry()
            if let exp, isIndefinite(exp) {
                status = "Sleep DISABLED indefinitely"
            } else {
                status = "Sleep DISABLED" + (exp.map { " until \(timeFormat.string(from: $0)) (\(formatRemaining($0.timeIntervalSinceNow)) left)" } ?? "")
            }
        case false?: status = "Sleep allowed (normal)"
        case nil: status = "Could not read pmset state"
        }
        menu.addItem(info(status))
        if let lastMessage { menu.addItem(info(lastMessage)) }
        menu.addItem(.separator())

        if state == true {
            menu.addItem(action("Allow sleep now", #selector(turnOff)))
            if let exp = readExpiry(), isIndefinite(exp) {
                menu.addItem(action("Switch to until \(timeFormat.string(from: defaultExpiry(now: Date())))", #selector(keepAwakeDefault)))
            } else {
                for h in [1, 2] { menu.addItem(action("Extend +\(h)h", #selector(extend(_:)), tag: h)) }
                menu.addItem(action("Keep awake indefinitely", #selector(keepAwakeIndefinitely)))
            }
        } else {
            // On battery with the preference on, the next tick would turn a keep-awake straight
            // back off, so the menu does not offer one.
            let blocked = offOnBattery && onBattery()
            if blocked { menu.addItem(info("On battery: uncheck “Allow sleep when unplugged” to keep awake")) }
            var items = [action("Keep awake until \(timeFormat.string(from: defaultExpiry(now: Date())))", #selector(keepAwakeDefault))]
            for h in [1, 2, 4] { items.append(action("Keep awake for \(h)h", #selector(keepAwakeHours(_:)), tag: h)) }
            items.append(action("Keep awake overnight (until 0\(morningHour):00)", #selector(keepAwakeOvernight)))
            items.append(action("Keep awake indefinitely", #selector(keepAwakeIndefinitely)))
            for i in items {
                i.isEnabled = !blocked
                menu.addItem(i)
            }
        }

        menu.addItem(.separator())
        let battery = action("Allow sleep when unplugged", #selector(toggleBattery))
        battery.state = offOnBattery ? .on : .off
        menu.addItem(battery)
        menu.addItem(.separator())
        // Quit only quits; stopping a keep-awake is "Allow sleep now". The reassurance is shown
        // only when it is true, i.e. when the backstop is there to enforce the expiry.
        let quitTitle = state == true && backstopInstalled ? "Quit (expiry is still enforced)" : "Quit"
        menu.addItem(action(quitTitle, #selector(quit), key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, tag: Int = 0, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        i.tag = tag
        return i
    }

    @objc private func turnOff() { setOff(nil) }
    @objc private func keepAwakeDefault() { setOn(until: defaultExpiry(now: Date())) }
    @objc private func keepAwakeHours(_ sender: NSMenuItem) { setOn(until: Date().addingTimeInterval(Double(sender.tag) * 3600)) }
    @objc private func keepAwakeOvernight() { setOn(until: nextOccurrence(ofHour: morningHour, after: Date())) }
    @objc private func keepAwakeIndefinitely() { setOn(until: indefinite) }
    @objc private func extend(_ sender: NSMenuItem) {
        // Sleep may have been re-enabled since the menu was drawn; then there is nothing to extend.
        guard readSleepDisabled() == true else { tick(); return }
        if writeExpiry(extendedExpiry(current: readExpiry(), byHours: sender.tag, now: Date())) {
            lastMessage = nil
            retryNotBefore = nil
        } else {
            lastMessage = "Could not save the expiry: nothing changed"
        }
        updateButton()
    }
    @objc private func toggleBattery() { offOnBattery.toggle(); tick() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
