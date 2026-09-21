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
/// The ambient figure against the app's own builder, on the one stored
/// representation — the flip's two-arm leg retired with the legacy arm.
///
/// ## The defect that was NOT structural
///
/// The widget shows a second number the shared path does not produce: the
/// pace delta, from its own `StatsEngine`. That engine was fed
/// `context.fetch(FetchDescriptor<TipEntry>())` directly -- the legacy
/// representation, unswitched -- while the money figure above it went through
/// `buildOnce`. Post-flip the pace would have been measured against a history
/// missing every shift logged since conversion. The adapter is now the single
/// boundary, so the truncation bug the switch prevented cannot re-form.
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

    /// The pace baseline's single arm — `StatsRecordAdapter.tipRecords` over
    /// records — must actually SEE the stored shifts. An adapter returning
    /// empty here is the truncation defect's residual shape.
    @Test("the pace baseline sees every stored shift")
    func paceBaselineSeesTheRecords() {
        let rows = StatsRecordAdapter.tipRecords(from: Self.records())
        #expect(!rows.isEmpty)
        let total = rows.reduce(0) { $0 + $1.netCents }
        #expect(total == (2_200 + 3_100 - 400) + (5_600 + 9_900),
                "the pace baseline must sum the same shifts the ledger values")
    }
}
