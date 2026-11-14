// Tests for Sources/SleepGuard/Policy.swift. Run with scripts/test.sh.
// A plain executable instead of XCTest, so it runs with the Command Line Tools alone.

import Foundation

var failures = 0
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: UInt = #line) {
    checks += 1
    guard actual != expected else { return }
    failures += 1
    print("FAIL line \(line): \(what)\n  expected: \(expected)\n  actual:   \(actual)")
}

let helsinki: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
    return c
}()

/// A wall-clock time in Helsinki on 14 Nov 2026 (or `day` of that month).
func at(_ hour: Int, _ minute: Int = 0, day: Int = 14) -> Date {
    helsinki.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

// MARK: pmset output

let pmsetOn = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby              1\n sleep                1 (sleep prevented by powerd)\n"
let pmsetOff = "System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n standby              1\n"

expect(parseSleepDisabled(pmsetOutput: pmsetOn), true, "SleepDisabled 1 reads as disabled")
expect(parseSleepDisabled(pmsetOutput: pmsetOff), false, "SleepDisabled 0 reads as allowed")
expect(parseSleepDisabled(pmsetOutput: "Currently in use:\n sleep                1\n"), nil,
       "the unrelated `sleep` setting is not mistaken for SleepDisabled")
expect(parseSleepDisabled(pmsetOutput: ""), nil, "empty output is unknown, not allowed")

// MARK: expiry file contents

expect(parseExpiry("1794690000\n"), Date(timeIntervalSince1970: 1794690000), "a plain timestamp with a newline parses")
expect(parseExpiry("  1794690000 \n"), Date(timeIntervalSince1970: 1794690000), "surrounding whitespace is ignored, as in enforce.sh")
expect(parseExpiry("253402300799").map(isIndefinite), true, "the year-9999 timestamp means indefinitely")
expect(parseExpiry(""), nil, "an empty file is no expiry")
expect(parseExpiry("soon"), nil, "text is no expiry")
// enforce.sh accepts digits only; anything else it treats as "no expiry". The app must agree,
// and must never turn these into a Date that crashes Int() or never compares as expired.
expect(parseExpiry("nan"), nil, "nan is no expiry")
expect(parseExpiry("inf"), nil, "inf is no expiry")
expect(parseExpiry("-5"), nil, "a negative number is no expiry")
expect(parseExpiry("1e12"), nil, "exponent notation is no expiry")
expect(parseExpiry("1794690000.5"), nil, "a fraction is no expiry")
expect(parseExpiry("17946 90000"), nil, "digits split by a space are no expiry")
expect(parseExpiry("9999999999999"), nil, "13 digits is no expiry (enforce.sh caps at 12)")

// MARK: expiry arithmetic

expect(defaultExpiry(now: at(14, 30), calendar: helsinki), at(23), "afternoon: until tonight's 23:00")
expect(defaultExpiry(now: at(7), calendar: helsinki), at(23), "07:00 sharp already counts as daytime")
expect(defaultExpiry(now: at(22, 59), calendar: helsinki), at(23), "22:59: one minute left until the cutoff")
expect(defaultExpiry(now: at(23), calendar: helsinki), at(1, day: 15), "23:00 sharp is night: 2 hours")
expect(defaultExpiry(now: at(3, 15), calendar: helsinki), at(5, 15), "small hours: 2 hours, not until 23:00")
expect(defaultExpiry(now: at(6, 59), calendar: helsinki), at(8, 59), "06:59 is still night: 2 hours")

expect(nextOccurrence(ofHour: 7, after: at(22), calendar: helsinki), at(7, day: 15), "overnight from the evening ends tomorrow 07:00")
expect(nextOccurrence(ofHour: 7, after: at(3), calendar: helsinki), at(7), "overnight from the small hours ends today 07:00")
expect(nextOccurrence(ofHour: 7, after: at(7), calendar: helsinki), at(7, day: 15), "at 07:00 sharp the next 07:00 is tomorrow")

expect(formatRemaining(59), "0m", "under a minute")
expect(formatRemaining(45 * 60), "45m", "minutes only below an hour")
expect(formatRemaining(3600), "1h00m", "exactly one hour")
expect(formatRemaining(2 * 3600 + 5 * 60 + 59), "2h05m", "minutes are zero-padded, seconds dropped")
expect(formatRemaining(-120), "0m", "an expiry in the past never shows negative time")

expect(extendedExpiry(current: at(18), byHours: 2, now: at(14)), at(20), "extending adds to the current expiry")
expect(extendedExpiry(current: at(13), byHours: 1, now: at(14)), at(15), "extending a lapsed expiry counts from now")
expect(extendedExpiry(current: nil, byHours: 1, now: at(14)), at(15), "extending with no expiry on file counts from now")

// MARK: what a tick does

let noon = at(12)

expect(tickAction(Snapshot(sleepDisabled: false, expiry: nil, now: noon), calendar: helsinki), .none,
       "sleep allowed, nothing on file: nothing to do")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: at(23), now: noon), calendar: helsinki), .none,
       "disabled with a future expiry: leave it")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: at(11), now: noon), calendar: helsinki), .turnOff(.expired(at(11))),
       "disabled past its expiry: turn off")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: noon, now: noon), calendar: helsinki), .turnOff(.expired(noon)),
       "the expiry instant itself counts as expired")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: indefinite, now: noon), calendar: helsinki), .none,
       "indefinite never expires")

// `sudo pmset -a disablesleep 1` typed in a terminal: no expiry on file.
expect(tickAction(Snapshot(sleepDisabled: true, expiry: nil, now: noon), calendar: helsinki), .adoptExpiry(at(23)),
       "disabled outside the app by day: adopt tonight's cutoff")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: nil, now: at(2)), calendar: helsinki), .adoptExpiry(at(4)),
       "disabled outside the app at night: adopt 2 hours")

// `sudo pmset -a disablesleep 0` typed in a terminal while a keep-awake was running: the
// expiry file is left behind. If it stayed, the next manual enable would inherit it — and
// a leftover "indefinitely" would make that enable silently permanent.
expect(tickAction(Snapshot(sleepDisabled: false, expiry: at(23), now: noon), calendar: helsinki), .clearStaleExpiry,
       "sleep re-enabled outside the app: drop the leftover expiry")
expect(tickAction(Snapshot(sleepDisabled: false, expiry: indefinite, now: noon), calendar: helsinki), .clearStaleExpiry,
       "sleep re-enabled outside the app: drop a leftover indefinite expiry")
expect(tickAction(Snapshot(sleepDisabled: nil, expiry: at(23), now: noon), calendar: helsinki), .none,
       "pmset unreadable: never delete an expiry on a guess")

// Battery
expect(tickAction(Snapshot(sleepDisabled: true, expiry: at(23), onBattery: true, offOnBattery: true, now: noon), calendar: helsinki),
       .turnOff(.onBattery), "on battery with the preference on: turn off")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: at(23), onBattery: true, offOnBattery: false, now: noon), calendar: helsinki),
       .none, "on battery with the preference off: leave it")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: nil, onBattery: true, offOnBattery: true, now: noon), calendar: helsinki),
       .turnOff(.onBattery), "disabled outside the app while on battery: turn off rather than adopt")
expect(tickAction(Snapshot(sleepDisabled: false, expiry: nil, onBattery: true, offOnBattery: true, now: noon), calendar: helsinki),
       .none, "on battery with sleep already allowed: nothing to do")

// A failed automatic turn-off (no sudoers rule, admin prompt cancelled) must not re-prompt every 15 s.
expect(tickAction(Snapshot(sleepDisabled: true, expiry: at(11), now: noon, retryNotBefore: at(12, 5)), calendar: helsinki), .none,
       "after a failed turn-off: wait for the retry time")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: at(11), now: at(12, 5), retryNotBefore: at(12, 5)), calendar: helsinki),
       .turnOff(.expired(at(11))), "after a failed turn-off: try again once the retry time arrives")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: at(23), onBattery: true, now: noon, retryNotBefore: at(12, 5)), calendar: helsinki),
       .none, "the retry wait applies to the battery turn-off too")
expect(tickAction(Snapshot(sleepDisabled: true, expiry: nil, now: noon, retryNotBefore: at(12, 5)), calendar: helsinki),
       .adoptExpiry(at(23)), "the retry wait does not stop adopting an expiry")

print(failures == 0 ? "policy: \(checks) checks passed" : "policy: \(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
