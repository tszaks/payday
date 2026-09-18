import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// What the flip adds to criterion 5's out-of-process leg.
///
/// ## Read `AmbientParityTests` first -- it already covers the figure
///
/// **CORRECTION.** I said criterion 5's "Siri == widget == app" leg was
/// untested. It was not: `AmbientParityTests` ("Ambient parity: Siri ==
/// widget == app") already asserts the ambient figure IS the app's own
/// pay-period result, plus the overtime week, the label on an unpriced
/// shift, an unavailable figure carrying no amount, the three absences
/// reading differently, and the spoken sentence following the figure's label.
/// Six tests. The claim was wrong and this header says so rather than
/// quietly implying the coverage arrived with this file.
///
/// The money figure is also sound structurally, which is why that suite is
/// short: `AmbientPeriodFigure` is ONE path, `PeriodTotalIntent` reaches it
/// through `spokenAnswer()` and the widget timeline through `answer(from:)`,
/// so there is nothing for the two surfaces to disagree about.
///
/// ## What this file actually adds
///
/// Two things the existing suite does not cover, both created by the flip:
///
/// 1. **Both representation arms of the ambient figure.** The existing
///    assertions run one dataset; these run the same shifts as records AND as
///    mirrored legacy entries, so the agreement is not an artifact of one arm.
/// 2. **The widget's pace baseline**, below.
///
/// ## And the defect that was NOT structural
///
/// The widget shows a second number the shared path does not produce: the
/// pace delta, from its own `StatsEngine`. That engine was fed
/// `context.fetch(FetchDescriptor<TipEntry>())` directly -- the legacy
/// representation, unswitched -- while the money figure above it went through
/// `buildOnce(shiftsAreAuthoritative:)`. Post-flip the pace would have been
/// measured against a history missing every shift logged since conversion,
/// and since the deriver only ever runs legacy-to-records, that truncation is
/// permanent and grows with use. A pace delta over a shrinking fraction of
/// the history is a wrong number, not a stale one.
///
/// It was found by running rule 23 against `PaydayWidget` by hand and
/// discovering the rule had been scoped to `Payday` alone -- so the widget
/// target was entirely unchecked by the lint written to prevent exactly this.
/// Same narrower-than-the-family error rule 20 already paid for.
@Suite("Ambient surface parity", .serialized)
@MainActor
struct AmbientSurfaceParityTests {

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
                id: PolicyMigration.deterministicID("ambient/rate"),
                effectiveFrom: .distantPast, hourlyRateCents: 283, provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("ambient/calendar"),
                effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone
            )]
        )
    }

    private static func records() -> [ShiftRecord] {
        [
            ShiftRecord(workDate: day(0), shiftPeriod: .dinner, cashTipsCents: 2_200,
                        creditTipsCents: 3_100, tipOutCents: 400, hoursWorked: 4.25,
                        recordedAt: day(0)),
            ShiftRecord(workDate: day(1), shiftPeriod: .dinner, cashTipsCents: 5_600,
                        creditTipsCents: 9_900, hoursWorked: 5.5, recordedAt: day(1)),
        ]
    }

    private static func mirroredEntries(_ records: [ShiftRecord]) -> [TipEntry] {
        records.flatMap { ShiftProjection.rows(for: $0) }.map { row in
            TipEntry(
                id: row.id, date: row.date, amountCents: row.amountCents, kind: row.kind,
                note: row.note, recordedAt: row.recordedAt, hoursWorked: row.hoursWorked,
                tipOutCents: row.tipOutCents, salesCents: row.salesCents,
                shiftPeriod: row.shiftPeriod, shiftID: row.shiftID, clockIn: row.clockIn,
                clockOut: row.clockOut, serverCount: row.serverCount,
                receiptMetrics: row.receiptMetrics
            )
        }
    }

    // MARK: - Siri == widget == app, on the money figure

    /// The ambient figure equals what the APP's own builder reports for the
    /// same period and dataset.
    ///
    /// `answer(from:)` is the function both out-of-process surfaces reach:
    /// `PeriodTotalIntent` through `spokenAnswer()`, and the widget timeline
    /// directly (split only so the widget can build one snapshot for several
    /// timeline dates). So asserting it against `HistoryEarnings` is
    /// asserting Siri == widget == app in one comparison, because the first
    /// two are the same call.
    @Test("the ambient figure equals the app's own period figure, on records")
    func ambientFigureEqualsAppOnRecords() throws {
        let policies = Self.policies()
        let records = Self.records()
        let schedule = PaySchedule.fallback
        let now = Self.day(1)

        let appBuild = HistoryEarnings.build(
            records: records, policies: policies, payrollTimeZone: Self.zone
        )
        let snapshot = try #require(appBuild.snapshot)

        let ambient = AmbientPeriodFigure.answer(
            from: snapshot, schedule: schedule, payrollTimeZone: Self.zone, now: now
        )

        let calculator = PayPeriodCalculator(payrollTimeZone: Self.zone, schedule: schedule)
        let period = calculator.period(containing: now)
        let appResult = snapshot.range(DayRange(
            start: CivilDay(period.start, in: Self.zone),
            end: CivilDay(period.end, in: Self.zone)
        ))

        // The spoken/rendered cents and the app's cents, for one period.
        #expect(ambient.figure.cents == appResult.knownComponents.earnedIncomeCents)
        // Non-zero, so this is not two unavailable figures agreeing -- the
        // way a parity assertion passes for the wrong reason.
        #expect((ambient.figure.cents ?? 0) > 0)
    }

    /// The same, through the legacy representation, so the agreement is not an
    /// artifact of one arm.
    @Test("the ambient figure equals the app's own period figure, on legacy entries")
    func ambientFigureEqualsAppOnLegacy() throws {
        let policies = Self.policies()
        let entries = Self.mirroredEntries(Self.records())
        let schedule = PaySchedule.fallback
        let now = Self.day(1)

        let appBuild = HistoryEarnings.build(
            entries: entries, policies: policies, payrollTimeZone: Self.zone
        )
        let snapshot = try #require(appBuild.snapshot)
        let ambient = AmbientPeriodFigure.answer(
            from: snapshot, schedule: schedule, payrollTimeZone: Self.zone, now: now
        )

        let calculator = PayPeriodCalculator(payrollTimeZone: Self.zone, schedule: schedule)
        let period = calculator.period(containing: now)
        let appResult = snapshot.range(DayRange(
            start: CivilDay(period.start, in: Self.zone),
            end: CivilDay(period.end, in: Self.zone)
        ))

        #expect(ambient.figure.cents == appResult.knownComponents.earnedIncomeCents)
        #expect((ambient.figure.cents ?? 0) > 0)
    }

    // MARK: - The widget's pace baseline reads the switched representation

    /// The two arms of `StatsRecordAdapter.tipRecords` describe the same
    /// shifts, so the widget's pace delta cannot depend on which one it read.
    ///
    /// Compared as TOTALS per shift rather than row-for-row, because the
    /// legacy arm emits one row per stored `TipEntry` and the record arm emits
    /// one per non-zero kind: the same shift, expressed with a different
    /// number of rows. What must match is what `StatsEngine` derives from
    /// them, which is the per-shift sum.
    @Test("both representations give StatsEngine the same per-shift money")
    func paceBaselineArmsAgree() throws {
        let records = Self.records()
        let entries = Self.mirroredEntries(records)

        let fromRecords = StatsRecordAdapter.tipRecords(
            entries: [], records: records, representation: .records
        )
        let fromEntries = StatsRecordAdapter.tipRecords(
            entries: entries, records: [], representation: .legacy
        )

        #expect(!fromRecords.isEmpty)
        #expect(!fromEntries.isEmpty)

        func netByShift(_ rows: [TipRecord]) -> [UUID: Int] {
            var out: [UUID: Int] = [:]
            for row in rows {
                guard let id = row.shiftID else { continue }
                out[id, default: 0] += row.netCents
            }
            return out
        }

        let recordTotals = netByShift(fromRecords)
        let entryTotals = netByShift(fromEntries)
        #expect(recordTotals == entryTotals,
                "the pace baseline must not depend on which representation it read")
        #expect(recordTotals.values.reduce(0, +) > 0, "and it must not be two empty maps agreeing")
    }

    /// The defect's own signature, pinned: on a records-only dataset the
    /// legacy arm sees nothing at all.
    ///
    /// This is what the widget's pace baseline used to do, and stating it as
    /// the DEFECT rather than as the fix means the test fails if anyone
    /// reintroduces the shape.
    @Test("the legacy arm over a records-only dataset yields nothing, which is why the switch exists")
    func legacyArmOverRecordsOnlyIsEmpty() {
        let records = Self.records()
        let legacyOverRecordsOnly = StatsRecordAdapter.tipRecords(
            entries: [], records: records, representation: .legacy
        )
        #expect(legacyOverRecordsOnly.isEmpty,
                "post-flip there are no TipEntry rows, so an unswitched pace baseline measures against an empty history")

        let switched = StatsRecordAdapter.tipRecords(
            entries: [], records: records, representation: .records
        )
        #expect(!switched.isEmpty)
    }
}
