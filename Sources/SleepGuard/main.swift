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
/// How long to wait after an automatic turn-off failed before trying, and possibly prompting, again.
let autoOffRetryInterval: TimeInterval = 5 * 60
/// How long the menu keeps showing the last message.
let messageLifetime: TimeInterval = 12 * 3600

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
    private var lastMessage: String? { didSet { lastMessageAt = Date() } }
    private var lastMessageAt = Date()
    /// Set while an automatic turn-off is failing. See Snapshot.retryNotBefore.
    private var retryNotBefore: Date?
    /// True while a privileged write is in flight, which can mean waiting at the admin prompt.
    /// A tick in that window would see the expiry file and the pmset flag out of step.
    private var writing = false

    private var offOnBattery: Bool {
        get { UserDefaults.standard.object(forKey: "offOnBattery") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "offOnBattery") }
    }

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
    @discardableResult
    private func setOff(_ reason: String?, automatic: Bool = false) -> Bool {
        writing = true
        defer { writing = false }
        let why = automatic
            ? "SleepGuard: the keep-awake period is over. Allow this Mac to sleep again."
            : "SleepGuard wants to let this Mac sleep again."
        let ok = writeSleepDisabled(false, why: why)
        if ok {
            writeExpiry(nil)
            retryNotBefore = nil
            lastMessage = reason.map { "\($0) → sleep allowed" }
        } else {
            if automatic { retryNotBefore = Date().addingTimeInterval(autoOffRetryInterval) }
            lastMessage = (reason.map { "\($0), but could" } ?? "Could") + " not re-enable sleep!"
        }
        state = readSleepDisabled()
        updateButton()
        return ok
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        state = readSleepDisabled()
        updateButton()
        menu.removeAllItems()
        let now = Date()
        let expiry = readExpiry()

        // An old message is noise. One about a turn-off that is still failing stays.
        if retryNotBefore == nil, now.timeIntervalSince(lastMessageAt) > messageLifetime { lastMessage = nil }

        let header = NSMenuItem()
        switch state {
        case true?:
            let detail: String
            if let expiry, isIndefinite(expiry) {
                detail = "indefinitely, until you allow sleep"
            } else if let expiry {
                detail = "until \(timeFormat.string(from: expiry)), \(formatRemaining(expiry.timeIntervalSince(now))) left"
            } else {
                detail = "no end time set yet"
            }
            header.view = statusHeader(glyph: .symbol("cup.and.saucer.fill"), style: .awake, title: "Keeping awake", detail: detail)
        case false?:
            header.view = statusHeader(glyph: .symbol("moon.zzz.fill"), style: .sleep, title: "Sleep allowed", detail: "This Mac sleeps as usual")
        case nil:
            header.view = statusHeader(glyph: .symbol("questionmark"), style: .neutral, title: "State unknown", detail: "Could not read the pmset setting")
        }
        menu.addItem(header)
        if let lastMessage {
            menu.addItem(retryNotBefore == nil ? info(lastMessage, .symbol("info"), .neutral) : info(lastMessage, .symbol("exclamationmark"), .alert))
        }
        menu.addItem(.separator())

        if state == true {
            menu.addItem(action("Allow sleep now", .symbol("moon.zzz.fill"), .sleep, #selector(turnOff)))
            if let expiry, !isIndefinite(expiry) {
                for h in [1, 2] { menu.addItem(action("Add \(hours(h))", .text("+\(h)"), .awake, #selector(extend(_:)), tag: h)) }
            }
            // Picking a duration while already awake only replaces the end time.
            let change = NSMenuItem(title: "Change to", action: nil, keyEquivalent: "")
            change.image = badge(.symbol("arrow.triangle.2.circlepath"), .awake)
            let durations = NSMenu()
            durations.autoenablesItems = false
            durationItems(now: now).forEach(durations.addItem)
            change.submenu = durations
            menu.addItem(change)
        } else {
            // On battery with the preference on, the next tick would turn a keep-awake straight
            // back off, so the menu does not offer one.
            let blocked = offOnBattery && onBattery()
            if blocked { menu.addItem(info("On battery: uncheck “Allow sleep when unplugged” to keep awake", .symbol("battery.25"), .neutral)) }
            menu.addItem(sectionHeader("Keep awake"))
            for item in durationItems(now: now) {
                item.isEnabled = !blocked
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let battery = action("Allow sleep when unplugged", .symbol("powerplug.fill"), .sleep, #selector(toggleBattery))
        battery.state = offOnBattery ? .on : .off
        menu.addItem(battery)
        menu.addItem(.separator())
        menu.addItem(versionItem())
        menu.addItem(action(state == true ? "Quit and allow sleep" : "Quit", .symbol("power"), .neutral, #selector(quit), key: "q"))
    }

    /// The choices of how long to stay awake: the main list when sleep is allowed, and the
    /// "Change to" submenu while awake.
    private func durationItems(now: Date) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        // At night the default is 2 hours, which the list offers anyway.
        if !isNight(now: now) {
            items.append(action("Until tonight, \(timeFormat.string(from: defaultExpiry(now: now)))", .symbol("moon.stars.fill"), .awake, #selector(keepAwakeDefault)))
        }
        for h in [1, 2, 4] { items.append(action("For \(hours(h))", .text("\(h)"), .awake, #selector(keepAwakeHours(_:)), tag: h)) }
        let morning = nextOccurrence(ofHour: morningHour, after: now)
        items.append(action("Until morning, \(timeFormat.string(from: morning))", .symbol("sun.max.fill"), .awake, #selector(keepAwakeOvernight)))
        items.append(action("Indefinitely", .symbol("infinity"), .awake, #selector(keepAwakeIndefinitely)))
        return items
    }

    private func hours(_ n: Int) -> String { n == 1 ? "1 hour" : "\(n) hours" }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func versionItem() -> NSMenuItem {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let i = NSMenuItem(title: "SleepGuard \(version)", action: nil, keyEquivalent: "")
        let icon = NSApp.applicationIconImage.copy() as? NSImage
        icon?.size = NSSize(width: 18, height: 18)
        i.image = icon
        i.isEnabled = false
        return i
    }

    private func info(_ title: String, _ glyph: Glyph, _ style: BadgeStyle) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.image = badge(glyph, style)
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ glyph: Glyph, _ style: BadgeStyle, _ sel: Selector, tag: Int = 0, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.image = badge(glyph, style)
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
    @objc private func quit() {
        // Quitting always ends a keep-awake, whether or not the backstop is installed.
        // If sleep cannot be re-enabled the app stays, and the menu says why.
        if readSleepDisabled() == true, !setOff(nil) { return }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
