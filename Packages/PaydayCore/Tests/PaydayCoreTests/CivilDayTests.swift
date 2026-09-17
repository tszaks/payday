import Foundation
import Testing
@testable import PaydayCore

@Suite("CivilDay")
struct CivilDayTests {
    @Test("2026-09-28 is a Monday (weekday 2)")
    func weekdayOfKnownMonday() {
        #expect(CivilDay(year: 2026, month: 9, day: 28).weekday == 2)
    }

    @Test("Weekdays across a known week", arguments: [
        ("2026-09-27", 1), ("2026-09-28", 2), ("2026-09-29", 3), ("2026-09-30", 4),
        ("2026-10-01", 5), ("2026-10-02", 6), ("2026-10-03", 7), ("2026-10-04", 1),
        ("1970-01-01", 5), ("2000-02-29", 3), ("1969-12-31", 4),
    ])
    func weekdays(iso: String, expected: Int) throws {
        let day = try #require(CivilDay(iso: iso))
        #expect(day.weekday == expected)
    }

    @Test("Monday-start workweek containing Sunday 2026-10-04 begins 2026-09-28")
    func mondayStartWorkweek() {
        let sunday = CivilDay(year: 2026, month: 10, day: 4)
        #expect(sunday.startOfWorkweek(startingOn: 2) == CivilDay(year: 2026, month: 9, day: 28))
    }

    @Test("Sunday-start workweek containing Sunday 2026-10-04 begins that day")
    func sundayStartWorkweek() {
        let sunday = CivilDay(year: 2026, month: 10, day: 4)
        #expect(sunday.startOfWorkweek(startingOn: 1) == sunday)
    }

    @Test("Saturday-start workweek containing Monday 2026-09-28 begins 2026-09-26")
    func saturdayStartWorkweek() {
        let monday = CivilDay(year: 2026, month: 9, day: 28)
        #expect(monday.startOfWorkweek(startingOn: 7) == CivilDay(year: 2026, month: 9, day: 26))
    }

    @Test("daysBetween is signed and crosses month and year boundaries")
    func daysBetween() {
        let a = CivilDay(year: 2026, month: 9, day: 28)
        let b = CivilDay(year: 2026, month: 10, day: 4)
        #expect(CivilDay.daysBetween(a, b) == 6)
        #expect(CivilDay.daysBetween(b, a) == -6)
        #expect(CivilDay.daysBetween(a, a) == 0)
        #expect(CivilDay.daysBetween(CivilDay(year: 2025, month: 12, day: 31), CivilDay(year: 2026, month: 1, day: 1)) == 1)
        #expect(CivilDay.daysBetween(CivilDay(year: 2028, month: 1, day: 1), CivilDay(year: 2029, month: 1, day: 1)) == 366)
    }

    @Test("adding(days:) walks forwards and backwards across boundaries")
    func adding() {
        let a = CivilDay(year: 2026, month: 9, day: 28)
        #expect(a.adding(days: 6) == CivilDay(year: 2026, month: 10, day: 4))
        #expect(a.adding(days: -28) == CivilDay(year: 2026, month: 8, day: 31))
        #expect(a.adding(days: 0) == a)
        #expect(CivilDay(year: 2028, month: 2, day: 28).adding(days: 1) == CivilDay(year: 2028, month: 2, day: 29))
        #expect(CivilDay(year: 2027, month: 2, day: 28).adding(days: 1) == CivilDay(year: 2027, month: 3, day: 1))
    }

    @Test("2028 is a leap year: Feb 29 2028 is valid, Feb 29 2027 is not, 1900 is not, 2000 is")
    func leapYears() {
        #expect(CivilDay(iso: "2028-02-29") != nil)
        #expect(CivilDay(iso: "2027-02-29") == nil)
        #expect(CivilDay(iso: "1900-02-29") == nil)
        #expect(CivilDay(iso: "2000-02-29") != nil)
        #expect(CivilDay(year: 2028, month: 1, day: 1).isLeapYear)
        #expect(!CivilDay(year: 2026, month: 1, day: 1).isLeapYear)
    }

    @Test("iso round-trips and rejects malformed strings", arguments: [
        "2026-09-28", "2028-02-29", "0001-01-01", "9999-12-31", "2026-01-05",
    ])
    func isoRoundTrip(iso: String) throws {
        let day = try #require(CivilDay(iso: iso))
        #expect(day.iso == iso)
        #expect(CivilDay(dayNumber: day.dayNumber) == day)
    }

    @Test("iso rejects malformed input", arguments: [
        "2026-9-28", "2026/09/28", "20260928", "2026-13-01", "2026-04-31", "2026-00-10", "", "2026-09-28T00:00", "２０２６-09-28",
    ])
    func isoRejects(iso: String) {
        #expect(CivilDay(iso: iso) == nil)
    }

    @Test("Date conversion uses the given time zone, not the process zone")
    func dateInTimeZone() throws {
        // 2026-09-28 03:30:00 UTC is still 2026-09-27 in New York (UTC-4).
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let instant = try #require(utc.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 3, minute: 30)))
        #expect(CivilDay(instant, in: TimeZone(identifier: "UTC")!) == CivilDay(year: 2026, month: 9, day: 28))
        #expect(CivilDay(instant, in: TimeZone(identifier: "America/New_York")!) == CivilDay(year: 2026, month: 9, day: 27))
        #expect(CivilDay(instant, in: TimeZone(identifier: "Pacific/Honolulu")!) == CivilDay(year: 2026, month: 9, day: 27))
        #expect(CivilDay(instant, in: TimeZone(identifier: "Asia/Tokyo")!) == CivilDay(year: 2026, month: 9, day: 28))
    }

    @Test("Comparable orders by year, then month, then day")
    func ordering() {
        #expect(CivilDay(year: 2026, month: 9, day: 28) < CivilDay(year: 2026, month: 10, day: 1))
        #expect(CivilDay(year: 2025, month: 12, day: 31) < CivilDay(year: 2026, month: 1, day: 1))
        #expect(CivilDay.distantPast < CivilDay(year: 2026, month: 1, day: 1))
        #expect(CivilDay(year: 2026, month: 1, day: 1) < CivilDay.distantFuture)
    }

    @Test("Codable encodes as the ISO string")
    func codable() throws {
        let day = CivilDay(year: 2026, month: 9, day: 28)
        let data = try JSONEncoder().encode([day])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-09-28\"]")
        #expect(try JSONDecoder().decode([CivilDay].self, from: data) == [day])
    }

    @Test("Day numbers agree with Foundation's Gregorian calendar over a long span")
    func dayNumberAgreesWithFoundation() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let epoch = Date(timeIntervalSince1970: 0)
        for offset in stride(from: -20000, through: 40000, by: 37) {
            let date = Date(timeInterval: Double(offset) * 86400, since: epoch)
            let comps = utc.dateComponents([.year, .month, .day, .weekday], from: date)
            let day = CivilDay(dayNumber: offset)
            #expect((day.year, day.month, day.day) == (comps.year!, comps.month!, comps.day!))
            #expect(day.weekday == comps.weekday!)
            #expect(day.dayNumber == offset)
        }
    }
}
