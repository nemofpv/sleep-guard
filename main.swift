// SleepGuard — menu bar toggle for `pmset disablesleep` that always expires.
//
// Every "keep awake" has an expiry time, written to /Users/Shared/SleepGuard/expires-at.
// The app turns sleep back on when it passes; the root LaunchDaemon installed by
// install.sh does the same every 5 minutes, so it still happens if this app is not running.

import AppKit
import IOKit.ps

let pmsetPath = "/usr/bin/pmset"
let sharedDir = "/Users/Shared/SleepGuard"
let expiryPath = sharedDir + "/expires-at"
let eveningCutoffHour = 23
let morningHour = 7
/// "Indefinitely" is stored as an expiry in year 9999, so enforce.sh needs no special case.
let indefinite = Date(timeIntervalSince1970: 253402300799)

func isIndefinite(_ date: Date) -> Bool { date >= indefinite }

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
    for line in run(pmsetPath, ["-g"]).out.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.first == "SleepDisabled", parts.count > 1 { return parts[1] == "1" }
    }
    return nil
}

/// Uses the passwordless sudoers rule from install.sh, falls back to an admin password prompt.
func writeSleepDisabled(_ on: Bool) -> Bool {
    let value = on ? "1" : "0"
    if run("/usr/bin/sudo", ["-n", pmsetPath, "-a", "disablesleep", value]).status != 0 {
        let script = "do shell script \"\(pmsetPath) -a disablesleep \(value)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }
    return readSleepDisabled() == on
}

func readExpiry() -> Date? {
    guard let s = try? String(contentsOfFile: expiryPath, encoding: .utf8),
          let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return Date(timeIntervalSince1970: t)
}

func writeExpiry(_ date: Date?) {
    let fm = FileManager.default
    guard let date else { try? fm.removeItem(atPath: expiryPath); return }
    try? fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
    try? String(Int(date.timeIntervalSince1970)).write(toFile: expiryPath, atomically: true, encoding: .utf8)
}

func onBattery() -> Bool {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return (type as String) == kIOPMBatteryPowerKey
}

func nextOccurrence(ofHour hour: Int, after now: Date = Date()) -> Date {
    let cal = Calendar.current
    let today = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
    return today > now ? today : cal.date(byAdding: .day, value: 1, to: today)!
}

/// Plain "keep awake" lasts until this evening's cutoff; late at night it is only 2 hours,
/// so a forgotten toggle never runs through the night.
func defaultExpiry(now: Date = Date()) -> Date {
    let hour = Calendar.current.component(.hour, from: now)
    if hour >= eveningCutoffHour || hour < morningHour { return now.addingTimeInterval(2 * 3600) }
    return nextOccurrence(ofHour: eveningCutoffHour, after: now)
}

func formatRemaining(_ seconds: TimeInterval) -> String {
    let m = max(0, Int(seconds) / 60)
    return m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))m" : "\(m)m"
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

    private var offOnBattery: Bool {
        get { UserDefaults.standard.object(forKey: "offOnBattery") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "offOnBattery") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        tick()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        state = readSleepDisabled()
        if state == true {
            if let exp = readExpiry() {
                if exp <= Date() { setOff("Expired at \(timeFormat.string(from: exp))") }
            } else {
                // Enabled outside the app: give it the default expiry instead of leaving it open-ended.
                writeExpiry(defaultExpiry())
            }
            if state == true, offOnBattery, onBattery() { setOff("Unplugged from power") }
        }
        updateButton()
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let symbol: String
        switch state {
        case true?: symbol = "cup.and.saucer.fill"
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
        writeExpiry(expiry)
        if writeSleepDisabled(true) {
            lastMessage = nil
        } else {
            writeExpiry(nil)
            lastMessage = "Could not disable sleep"
        }
        state = readSleepDisabled()
        updateButton()
    }

    private func setOff(_ reason: String?) {
        if writeSleepDisabled(false) {
            writeExpiry(nil)
            lastMessage = reason.map { "\($0) → sleep allowed" }
        } else {
            lastMessage = "Could not re-enable sleep!"
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
                menu.addItem(action("Switch to until \(timeFormat.string(from: defaultExpiry()))", #selector(keepAwakeDefault)))
            } else {
                for h in [1, 2] { menu.addItem(action("Extend +\(h)h", #selector(extend(_:)), tag: h)) }
                menu.addItem(action("Keep awake indefinitely", #selector(keepAwakeIndefinitely)))
            }
        } else {
            let def = defaultExpiry()
            menu.addItem(action("Keep awake until \(timeFormat.string(from: def))", #selector(keepAwakeDefault)))
            for h in [1, 2, 4] { menu.addItem(action("Keep awake for \(h)h", #selector(keepAwakeHours(_:)), tag: h)) }
            menu.addItem(action("Keep awake overnight (until 0\(morningHour):00)", #selector(keepAwakeOvernight)))
            menu.addItem(action("Keep awake indefinitely", #selector(keepAwakeIndefinitely)))
        }

        menu.addItem(.separator())
        let battery = action("Allow sleep when unplugged", #selector(toggleBattery))
        battery.state = offOnBattery ? .on : .off
        menu.addItem(battery)
        menu.addItem(.separator())
        menu.addItem(action("Quit (expiry is still enforced)", #selector(quit), key: "q"))
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
    @objc private func keepAwakeDefault() { setOn(until: defaultExpiry()) }
    @objc private func keepAwakeHours(_ sender: NSMenuItem) { setOn(until: Date().addingTimeInterval(Double(sender.tag) * 3600)) }
    @objc private func keepAwakeOvernight() { setOn(until: nextOccurrence(ofHour: morningHour)) }
    @objc private func keepAwakeIndefinitely() { setOn(until: indefinite) }
    @objc private func extend(_ sender: NSMenuItem) {
        let base = max(readExpiry() ?? Date(), Date())
        writeExpiry(base.addingTimeInterval(Double(sender.tag) * 3600))
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
