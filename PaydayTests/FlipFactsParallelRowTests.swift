import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// `PeriodDetailFacts` and `DashboardFacts` gain a record-backed row list
/// beside their legacy one, the same shape #55 established for
/// `DayDetailFacts`.
///
/// Additive: both parameters are defaulted, so every existing caller is
/// unchanged and nothing passes records until the writer flip. Asserted now so
/// the flip's change at each screen is "pass the other list" rather than
/// "hope the selection matches".
///
/// What is being pinned is the selection rule, not the arithmetic. Each screen
/// filters its rows by the ids the ENGINE selected (`PeriodDetailFacts`) or by
/// the engine's civil-work-day membership (`DashboardFacts`), so the rows and
/// the hero are one set by construction. If the record path filtered
/// differently, a screen would show a total over the wrong rows -- which is
/// the criterion-5 failure in miniature.
@Suite("Flip: parallel record rows")
@MainActor
struct FlipFactsParallelRowTests {

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
                id: PolicyMigration.deterministicID("parallel/rate"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 283,
                provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("parallel/calendar"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: zone
            )]
        )
    }

    private static func records() -> [ShiftRecord] {
        [
            ShiftRecord(workDate: day(0), shiftPeriod: .lunch,
                        cashTipsCents: 2_200, creditTipsCents: 3_100,
                        tipOutCents: 400, hoursWorked: 4.25, recordedAt: day(0)),
            ShiftRecord(workDate: day(0), shiftPeriod: .dinner,
                        cashTipsCents: 5_600, creditTipsCents: 9_900,
                        hoursWorked: 5.5, recordedAt: day(0).addingTimeInterval(3_600)),
            ShiftRecord(workDate: day(2), cashTipsCents: 3_000,
                        hoursWorked: 6, recordedAt: day(2)),
        ]
    }

    /// Legacy rows carrying exactly the projected values, grouped the app's
    /// one way, so the only difference between the two inputs is the
    /// representation.
    private static func legacyGroups(_ records: [ShiftRecord])
        -> [(day: Date, shiftID: UUID, items: [TipEntry])] {
        let entries = records.flatMap { ShiftProjection.rows(for: $0) }.map { row in
            TipEntry(
                id: row.id, date: row.date, amountCents: row.amountCents,
                kind: row.kind, note: row.note, recordedAt: row.recordedAt,
                hoursWorked: row.hoursWorked, tipOutCents: row.tipOutCents,
                salesCents: row.salesCents, shiftPeriod: row.shiftPeriod,
                shiftID: row.shiftID, clockIn: row.clockIn, clockOut: row.clockOut,
                serverCount: row.serverCount, receiptMetrics: row.receiptMetrics
            )
        }
        return CalendarEarnings.shiftGroups(entries: entries, payrollTimeZone: zone)
    }

    private static func snapshot(_ records: [ShiftRecord]) -> EarningsSnapshot? {
        let policies = policies()
        let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
        return try? EarningsSnapshot.build(EarningsInputs(
            shifts: adapted.inputs,
            rates: policies.rates,
            calendars: policies.calendars,
            asOf: CivilDay(day(30), in: zone)
        ))
    }

    @Test("PeriodDetailFacts selects the same rows through either representation")
    func periodDetailSelectsTheSameRows() throws {
        let records = Self.records()
        let snap = Self.snapshot(records)
        let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: Self.day(13))
        let period = PayPeriodCalculator(
            payrollTimeZone: Self.zone, schedule: schedule,
            calendar: Calendar(identifier: .gregorian)
        ).period(containing: Self.day(0))

        let legacy = PeriodDetailFacts(
            snapshot: snap, shiftDays: Self.legacyGroups(records),
            paycheckRecords: [], period: period, schedule: schedule,
            payrollTimeZone: Self.zone
        )
        let viaRecords = PeriodDetailFacts(
            snapshot: snap, shiftDays: [], shiftRecordDays: records,
            paycheckRecords: [], period: period, schedule: schedule,
            payrollTimeZone: Self.zone
        )

        // The same shifts, selected by the same engine ids. Hoisted to locals
        // because the nested map/sorted inside `#expect` defeated the type
        // checker outright ("unable to type-check this expression in
        // reasonable time"), the same shape that broke a parameterized test
        // earlier in this project.
        let legacyIDs: [String] = legacy.shiftDays.map { $0.shiftID.uuidString }.sorted()
        let recordIDs: [String] = viaRecords.shiftRecordDays.map { $0.id.uuidString }.sorted()
        #expect(legacyIDs == recordIDs)
        // Non-empty, or this compares two empty lists.
        #expect(!viaRecords.shiftRecordDays.isEmpty)
        // The double-shift day is found through either path.
        #expect(legacy.multiShiftDays == viaRecords.multiShiftDays)
        #expect(!viaRecords.multiShiftDays.isEmpty, "day 0 holds two shifts")
        // Never both populated.
        #expect(legacy.shiftRecordDays.isEmpty)
        #expect(viaRecords.shiftDays.isEmpty)
    }

    @Test("DashboardFacts selects the same rows through either representation")
    func dashboardSelectsTheSameRows() throws {
        let records = Self.records()
        let snap = Self.snapshot(records)
        let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: Self.day(13))

        let legacy = DashboardFacts(
            snapshot: snap, allShifts: Self.legacyGroups(records),
            schedule: schedule, now: Self.day(1), forcedPaydayPhase: nil,
            dismissedClosedEnd: nil, dismissedCheckEnd: nil,
            payrollTimeZone: Self.zone
        )
        let viaRecords = DashboardFacts(
            snapshot: snap, allShifts: [], allShiftRecords: records,
            schedule: schedule, now: Self.day(1), forcedPaydayPhase: nil,
            dismissedClosedEnd: nil, dismissedCheckEnd: nil,
            payrollTimeZone: Self.zone
        )

        let legacyIDs: [String] = legacy.shiftDays.map { $0.shiftID.uuidString }.sorted()
        let recordIDs: [String] = viaRecords.shiftRecordDays.map { $0.id.uuidString }.sorted()
        #expect(legacyIDs == recordIDs)
        #expect(!viaRecords.shiftRecordDays.isEmpty)
        // The count is the same through either path, which matters because it
        // drives the "N shifts" copy and the row-list truncation.
        #expect(legacy.shiftCount == viaRecords.shiftCount)
        #expect(viaRecords.shiftCount > 0)
        #expect(legacy.shiftRecordDays.isEmpty)
        #expect(viaRecords.shiftDays.isEmpty)
    }
}
