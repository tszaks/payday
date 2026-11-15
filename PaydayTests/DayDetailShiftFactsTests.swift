import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// Day-detail row facts, on the records arm, which is now the only arm. The
/// facts are keyed on scalars (`shiftID`, `day`, the shift's period) supplied
/// by `ShiftRecord` directly; the records stay live objects because these rows
/// are the edit and delete targets and `ProjectedShiftRow` is deliberately
/// un-persistable.
@Suite("Day detail shift facts")
@MainActor
struct DayDetailShiftFactsTests {

    private static let zone = TimeZone(identifier: "America/New_York")!

    private static func day(_ offset: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let base = cal.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        return cal.date(byAdding: .day, value: offset, to: base)!
    }

    private static func policies() -> CompensationPolicies {
        CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("daydetail/rate"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 283,
                provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("daydetail/calendar"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: zone
            )]
        )
    }

    /// Two shifts on one day, one of them wage-only, which is the case a join
    /// or a writer is most likely to lose.
    private static func records() -> [ShiftRecord] {
        [
            ShiftRecord(
                workDate: day(0), shiftPeriod: .lunch,
                cashTipsCents: 2_200, creditTipsCents: 3_100,
                tipOutCents: 400, hoursWorked: 4.25, recordedAt: day(0)
            ),
            ShiftRecord(
                workDate: day(0), shiftPeriod: .dinner,
                hoursWorked: 5.5, recordedAt: day(0).addingTimeInterval(3_600)
            ),
        ]
    }

    @Test("the day total is real and the shift list carries the records")
    func factsCarryTheRecords() throws {
        let records = Self.records()
        let facts = DayDetailFacts(
            shiftRecords: records, date: Self.day(0),
            policies: Self.policies(), payrollTimeZone: Self.zone
        )

        // The money: non-zero, so this is not an unavailable figure.
        let cents = try #require(facts.total.cents)
        #expect(cents > 0)
        #expect(facts.stamp?.digest != nil)

        // Exactly the shifts the engine selected for that day, lunch first.
        let engineSelection = try #require(facts.snapshot?.day(
            CivilDay(Self.day(0), in: Self.zone)
        ).shiftIDs)
        #expect(Set(facts.shiftRecords.map(\.id)) == Set(engineSelection))
        #expect(facts.shiftRecords.map(\.id) == records.map(\.id))
        #expect(Set(facts.shiftRecords.map(\.id)) == Set(records.map(\.id)))
        #expect(facts.shiftRecords.count == 2)
    }

    /// The row facts are keyed on scalars, and the rows sum to the hero --
    /// the criterion-5 clause this screen owns.
    @Test("row facts key on the record's scalars and sum to the total")
    func rowsSumToTheTotal() {
        let facts = DayDetailFacts(
            shiftRecords: Self.records(), date: Self.day(0),
            policies: Self.policies(), payrollTimeZone: Self.zone
        )

        for record in facts.shiftRecords {
            let row = facts.rowFacts(for: record, shiftCount: 2, note: nil)
            #expect(row.day == record.workDate, "row \(record.id) day")
            #expect(row.period == record.shiftPeriod, "row \(record.id) period")
            #expect(row.dayHasMultipleShifts)
            #expect(row.amount.cents != nil, "row \(record.id) valued")
        }

        let rowSum = facts.shiftRecords
            .map { facts.rowFacts(for: $0, shiftCount: 2, note: nil).amount.cents ?? 0 }
            .reduce(0, +)
        #expect(rowSum == facts.total.cents)
    }

    /// The rows are listed in the order the ledger allocates a day in, not in
    /// id order: these ids sort untagged, dinner, lunch.
    @Test("a double day lists lunch, then dinner, then an untagged shift")
    func doubleDayListsLunchFirst() {
        let untagged = ShiftRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            workDate: Self.day(0), creditTipsCents: 1_000, recordedAt: Self.day(0)
        )
        let dinner = ShiftRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            workDate: Self.day(0), shiftPeriod: .dinner, creditTipsCents: 6_000,
            recordedAt: Self.day(0)
        )
        let lunch = ShiftRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            workDate: Self.day(0), shiftPeriod: .lunch, creditTipsCents: 4_000,
            recordedAt: Self.day(0).addingTimeInterval(3_600)
        )
        let facts = DayDetailFacts(
            shiftRecords: [untagged, dinner, lunch], date: Self.day(0),
            policies: Self.policies(), payrollTimeZone: Self.zone
        )
        #expect(facts.shiftRecords.map(\.id) == [lunch.id, dinner.id, untagged.id])
    }

    /// A day with no shifts is an empty day, not a failed read.
    @Test("a day with no records reports no shifts without claiming a failure")
    func emptyDayIsNotAFailure() {
        let facts = DayDetailFacts(
            shiftRecords: Self.records(), date: Self.day(5),
            policies: Self.policies(), payrollTimeZone: Self.zone
        )
        #expect(facts.shiftRecords.isEmpty)
        #expect(facts.snapshot != nil, "the snapshot built; the day is simply empty")
    }
}
