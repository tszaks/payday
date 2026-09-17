import Foundation
import Testing
@testable import PaydayCore

@Suite("PayrollCalendarPolicy")
struct PayrollCalendarPolicyTests {
    static let zone = TimeZone(identifier: "America/New_York")!
    static let monday = CivilDay(year: 2025, month: 12, day: 29)

    static func json(weekday: Int, zone: String = "America/New_York") -> Data {
        Data("""
        {"id": "55555555-5555-4555-8555-555555555555", "effectiveFrom": "2025-12-29",
         "workweekStartWeekday": \(weekday), "payrollTimeZone": "\(zone)"}
        """.utf8)
    }

    @Test("Every weekday 1...7 decodes and round-trips", arguments: 1...7)
    func validWeekdays(weekday: Int) throws {
        let policy = try JSONDecoder().decode(PayrollCalendarPolicy.self, from: Self.json(weekday: weekday))
        #expect(policy.workweekStartWeekday == weekday)
        #expect(policy.overtimeThresholdMinutes == 2400)
        #expect(policy.overtimeMultiplierHundredths == 150)
        #expect(policy.payrollTimeZone.identifier == "America/New_York")
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(PayrollCalendarPolicy.self, from: data) == policy)
    }

    @Test("A workweekStartWeekday outside 1...7 is a DecodingError, not a trap", arguments: [0, 8, -1, 7 + 7, Int.max, Int.min])
    func invalidWeekdayThrows(weekday: Int) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PayrollCalendarPolicy.self, from: Self.json(weekday: weekday))
        }
        do {
            _ = try JSONDecoder().decode(PayrollCalendarPolicy.self, from: Self.json(weekday: weekday))
            Issue.record("weekday \(weekday) decoded")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.last?.stringValue == "workweekStartWeekday")
            #expect(context.debugDescription.contains("\(weekday)"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("An unknown time zone identifier is a DecodingError")
    func unknownZoneThrows() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PayrollCalendarPolicy.self, from: Self.json(weekday: 2, zone: "Mars/Olympus_Mons"))
        }
    }

    @Test("weekdayRange matches CivilDay's Sunday=1 ... Saturday=7 convention")
    func rangeMatchesCivilDay() {
        #expect(PayrollCalendarPolicy.weekdayRange == 1...7)
        #expect(Self.monday.weekday == 2)
        // Every weekday value that is a legal policy value is also a legal startOfWorkweek argument.
        for weekday in PayrollCalendarPolicy.weekdayRange {
            #expect(Self.monday.startOfWorkweek(startingOn: weekday).weekday == weekday)
        }
    }

    @Test("Memberwise init accepts the whole legal range")
    func memberwiseAcceptsRange() {
        for weekday in PayrollCalendarPolicy.weekdayRange {
            let policy = PayrollCalendarPolicy(id: UUID(), effectiveFrom: Self.monday, workweekStartWeekday: weekday,
                                               payrollTimeZone: Self.zone)
            #expect(policy.workweekStartWeekday == weekday)
        }
        // Out-of-range values trap by precondition; that path is not exercisable
        // from Swift Testing and is covered by the decoding test above.
    }
}
