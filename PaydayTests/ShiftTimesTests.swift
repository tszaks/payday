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
    @Test("a normal same-day shift measures straightforwardly")
    func normalCase() {
        #expect(ShiftTimes.hours(clockIn: time(9, 30), clockOut: time(17, 0)) == 7.5)
    }

    @Test("an overnight shift measures forward across midnight")
    func overnightWrap() {
        #expect(ShiftTimes.hours(clockIn: time(17, 0), clockOut: time(1, 30)) == 8.5)
    }

    @Test("minutes round to the nearest quarter hour")
    func quarterHourRounding() {
        #expect(ShiftTimes.hours(clockIn: time(10, 0), clockOut: time(14, 10)) == 4.25)
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
