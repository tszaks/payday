import Testing
import Foundation
@testable import Payday

private func time(_ hour: Int, _ minute: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: hour, minute: minute))!
}

@Suite("ShiftTimes hours")
struct ShiftTimesTests {
    @Test("shift period uses the canonical 4 PM boundary")
    func inferredShiftPeriod() {
        #expect(ShiftTimes.period(for: time(15, 59)) == .lunch)
        #expect(ShiftTimes.period(for: time(16, 0)) == .dinner)
        #expect(ShiftTimes.period(for: time(17, 6)) == .dinner)
    }

    @Test("a normal same-day shift measures straightforwardly")
    func normalCase() {
        #expect(ShiftTimes.hours(clockIn: time(9, 30), clockOut: time(17, 0)) == 7.5)
    }

    @Test("an overnight shift measures forward across midnight")
    func overnightWrap() {
        #expect(ShiftTimes.hours(clockIn: time(17, 0), clockOut: time(1, 30)) == 8.5)
    }

    @Test("hours are exact to the minute, never rounded to the nearest quarter hour")
    func exactMinutes() {
        // 10:04 AM-4:27 PM = 383 minutes = 6.3833...h, period.
        let hours = ShiftTimes.hours(clockIn: time(10, 4), clockOut: time(16, 27))
        #expect(hours != nil)
        #expect(abs(hours! - 383.0 / 60.0) < 0.0001)
        // 10:00-14:10 is 250 minutes = 4.1666...h, not quarter-rounded to 4.25.
        let notRounded = ShiftTimes.hours(clockIn: time(10, 0), clockOut: time(14, 10))
        #expect(abs(notRounded! - 250.0 / 60.0) < 0.0001)
        #expect(notRounded != 4.25)
    }

    @Test("equal clock-in and clock-out reads as not set, not a 24-hour shift")
    func equalTimesIsNil() {
        #expect(ShiftTimes.hours(clockIn: time(9, 0), clockOut: time(9, 0)) == nil)
    }

    @Test("either side missing is nil")
    func eitherSideMissingIsNil() {
        #expect(ShiftTimes.hours(clockIn: time(9, 0), clockOut: nil) == nil)
        #expect(ShiftTimes.hours(clockIn: nil, clockOut: time(9, 0)) == nil)
        #expect(ShiftTimes.hours(clockIn: nil, clockOut: nil) == nil)
    }
}
