// Decisions with no side effects: parsing, expiry arithmetic, and what a tick should do.
// Everything here is covered by Tests/PolicyTests; main.swift does the I/O.

import Foundation

let eveningCutoffHour = 23
let morningHour = 7
/// "Indefinitely" is stored as an expiry in year 9999, so enforce.sh needs no special case.
let indefinite = Date(timeIntervalSince1970: 253402300799)

func isIndefinite(_ date: Date) -> Bool { date >= indefinite }

/// nil when the output has no SleepDisabled line.
func parseSleepDisabled(pmsetOutput: String) -> Bool? {
    for line in pmsetOutput.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.first == "SleepDisabled", parts.count > 1 { return parts[1] == "1" }
    }
    return nil
}

/// Accepts exactly what enforce.sh accepts: 1–12 ASCII digits. Anything else is "no expiry",
/// which also keeps NaN and infinity out of the date arithmetic.
func parseExpiry(_ text: String) -> Date? {
    let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...12).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
          let seconds = TimeInterval(digits) else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

func nextOccurrence(ofHour hour: Int, after now: Date, calendar: Calendar = .current) -> Date {
    let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
    return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)!
}

/// From the evening cutoff until the morning hour.
func isNight(now: Date, calendar: Calendar = .current) -> Bool {
    let hour = calendar.component(.hour, from: now)
    return hour >= eveningCutoffHour || hour < morningHour
}

/// Plain "keep awake" lasts until this evening's cutoff; at night it is only 2 hours,
/// so a forgotten toggle never runs through the night.
func defaultExpiry(now: Date, calendar: Calendar = .current) -> Date {
    if isNight(now: now, calendar: calendar) { return now.addingTimeInterval(2 * 3600) }
    return nextOccurrence(ofHour: eveningCutoffHour, after: now, calendar: calendar)
}

/// A lapsed or missing expiry is extended from now, not from the past.
func extendedExpiry(current: Date?, byHours hours: Int, now: Date) -> Date {
    max(current ?? now, now).addingTimeInterval(Double(hours) * 3600)
}

func formatRemaining(_ seconds: TimeInterval) -> String {
    let m = max(0, Int(seconds) / 60)
    return m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))m" : "\(m)m"
}

/// Everything a tick can observe.
struct Snapshot {
    var sleepDisabled: Bool?
    var expiry: Date?
    var onBattery = false
    var offOnBattery = true
    var now: Date
    /// Set after an automatic turn-off failed, so the admin prompt is not raised on every tick.
    var retryNotBefore: Date?
}

enum OffReason: Equatable {
    case expired(Date)
    case onBattery
}

enum TickAction: Equatable {
    case none
    case clearStaleExpiry
    case adoptExpiry(Date)
    case turnOff(OffReason)
}

func tickAction(_ s: Snapshot, calendar: Calendar = .current) -> TickAction {
    guard let sleepDisabled = s.sleepDisabled else { return .none }
    guard sleepDisabled else {
        // Sleep was re-enabled outside the app. A leftover expiry would be inherited by the
        // next manual enable, so it goes.
        return s.expiry == nil ? .none : .clearStaleExpiry
    }
    let mayTurnOff = s.retryNotBefore.map { s.now >= $0 } ?? true
    if let expiry = s.expiry, expiry <= s.now { return mayTurnOff ? .turnOff(.expired(expiry)) : .none }
    if s.offOnBattery && s.onBattery { return mayTurnOff ? .turnOff(.onBattery) : .none }
    if s.expiry == nil { return .adoptExpiry(defaultExpiry(now: s.now, calendar: calendar)) }
    return .none
}
