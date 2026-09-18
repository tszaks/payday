import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// The class-B row work, additive: `DayDetailFacts` gains a record-backed
/// initializer beside its legacy one, and nothing calls it until the writer
/// flip.
///
/// It exists now so the equivalence can be asserted BEFORE anything depends on
/// it. At flip time the change is which initializer the view calls; if the two
/// are proven to agree first, that switch carries no arithmetic risk.
///
/// The decision this piece settled is worth recording, because it was the one
/// generating the complexity. The row facts looked representation-bound, so
/// the options seemed to be an enum over both representations or a generic
/// over `LegacyShiftRow`. Reading `rowFacts` showed it only ever used
/// `shiftID`, `day` and the shift's period -- three scalars, all of which sit
/// directly on a `ShiftRecord`. So neither an enum nor a generic is needed:
/// the facts are keyed on scalars and each representation supplies them from
/// its own shape. What DOES need the live object is targeting, since these
/// rows are the edit and delete targets and `ProjectedShiftRow` is
/// deliberately un-persistable -- which is why `shiftRecords` is `[ShiftRecord]`
/// and not a projection.
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

    /// Legacy rows carrying exactly the projected values, so the only
    /// difference between the two inputs is the representation. Built from the
    /// projection rather than hand-written, because hand-written values would
    /// test my transcription instead of the two paths.
    private static func mirroredEntries(_ records: [ShiftRecord]) -> [TipEntry] {
        records.flatMap { ShiftProjection.rows(for: $0) }.map { row in
            TipEntry(
                id: row.id, date: row.date, amountCents: row.amountCents,
                kind: row.kind, note: row.note, recordedAt: row.recordedAt,
                hoursWorked: row.hoursWorked, tipOutCents: row.tipOutCents,
                salesCents: row.salesCents, shiftPeriod: row.shiftPeriod,
                shiftID: row.shiftID, clockIn: row.clockIn, clockOut: row.clockOut,
                serverCount: row.serverCount, receiptMetrics: row.receiptMetrics
            )
        }
    }

    @Test("both initializers report the same total, stamp and shift ids")
    func bothPathsAgree() throws {
        let records = Self.records()
        let policies = Self.policies()
        let legacy = DayDetailFacts(
            allEntries: Self.mirroredEntries(records), date: Self.day(0),
            policies: policies, payrollTimeZone: Self.zone
        )
        let viaRecords = DayDetailFacts(
            shiftRecords: records, date: Self.day(0),
            policies: policies, payrollTimeZone: Self.zone
        )

        // The money.
        #expect(legacy.total.cents == viaRecords.total.cents)
        #expect(legacy.total.label == viaRecords.total.label)
        // Non-zero, so this is not two unavailable figures agreeing -- the way
        // an earlier parity test in this project passed for the wrong reason.
        let cents = try #require(viaRecords.total.cents)
        #expect(cents > 0)

        // Gate 4's digest identity, at this surface. Assertable only because
        // the manifest canonicalization landed first (#45): before that, a
        // shift with an explicit zero tip-out fingerprinted differently
        // through the two adapters.
        #expect(legacy.stamp?.digest == viaRecords.stamp?.digest)

        // The same shifts, in the same order, and both lists non-empty.
        #expect(legacy.shifts.map(\.shiftID) == viaRecords.shiftRecords.map(\.id))
        #expect(viaRecords.shiftRecords.count == 2)

        // The two row lists never both hold rows, so a screen cannot render
        // both representations at once.
        #expect(legacy.shiftRecords.isEmpty)
        #expect(viaRecords.shifts.isEmpty)
    }

    /// The row facts are keyed on scalars, so the same row reads identically
    /// whichever representation supplied it.
    @Test("a row's facts are the same through either representation")
    func rowFactsAgree() throws {
        let records = Self.records()
        let policies = Self.policies()
        let legacy = DayDetailFacts(
            allEntries: Self.mirroredEntries(records), date: Self.day(0),
            policies: policies, payrollTimeZone: Self.zone
        )
        let viaRecords = DayDetailFacts(
            shiftRecords: records, date: Self.day(0),
            policies: policies, payrollTimeZone: Self.zone
        )

        for (group, record) in zip(legacy.shifts, viaRecords.shiftRecords) {
            let a = legacy.rowFacts(for: group, shiftCount: 2, note: nil)
            let b = viaRecords.rowFacts(for: record, shiftCount: 2, note: nil)
            #expect(a.amount.cents == b.amount.cents, "row \(record.id) amount")
            #expect(a.amount.label == b.amount.label, "row \(record.id) label")
            #expect(a.period == b.period, "row \(record.id) period")
            #expect(a.day == b.day, "row \(record.id) day")
        }

        // And the rows sum to the hero, through the record path, which is the
        // criterion-5 clause this screen owns.
        let rowSum = viaRecords.shiftRecords
            .map { viaRecords.rowFacts(for: $0, shiftCount: 2, note: nil).amount.cents ?? 0 }
            .reduce(0, +)
        #expect(rowSum == viaRecords.total.cents)
    }

    /// A day with no shifts is an empty day, not a failed read.
    @Test("a day with no records reports no shifts without claiming a failure")
    func emptyDayIsNotAFailure() {
        let viaRecords = DayDetailFacts(
            shiftRecords: Self.records(), date: Self.day(5),
            policies: Self.policies(), payrollTimeZone: Self.zone
        )
        #expect(viaRecords.shiftRecords.isEmpty)
        #expect(viaRecords.snapshot != nil, "the snapshot built; the day is simply empty")
    }
}
