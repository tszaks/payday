import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// Criterion 5 on the RECORDS arm, which was gated by one test while the
/// legacy arm was gated by five suites.
///
/// ## The measurement that produced this file
///
/// Criterion 5 says parity holds on real screen adapters. Counting suites
/// does not establish that — a suite can exist and gate nothing — so the
/// question was asked with a mutation instead: make `DashboardEarnings`
/// clamp its DATASET to today while `HistoryEarnings` does not, which is
/// exactly the cross-surface divergence criterion 5 forbids.
///
/// Run twice, once against each arm of the builder:
///
/// | Mutation | Suites catching | Failing tests |
/// |---|---|---|
/// | **legacy** arm clamps | 5 | 32 |
/// | **records** arm clamps, before this file | 1 | 3 |
/// | **records** arm clamps, after it | 2 | 14 |
///
/// The remaining gap — 5/32 against 2/14 — is PR 8's entry condition,
/// recorded in `docs/RELEASE_GATE.md`: PR 8 may not delete the legacy arm
/// until the records arm's catch count reaches what the legacy arm's was,
/// because deleting legacy deletes the 32 with it.
///
/// The legacy arm is deeply gated: `DashboardPeriodParityTests`
/// ("Dashboard period income equals the History row and period detail" —
/// criterion 5's first clause verbatim), the payday card, final-day
/// membership, and the cutoff suite all fail. The records arm was caught
/// only by `FlipGates5And7Tests.gate5FourConsumersAgree`, written the same
/// day.
///
/// **That asymmetry is backwards relative to risk.** The legacy arm is what
/// every account uses today and is scheduled for deletion in PR 8. The
/// records arm is what every account uses after conversion — and since S15
/// the flip is reachable, so the thinly gated arm is the one whose defects
/// would reach a person.
///
/// ## Why this is a new file rather than a parameterisation
///
/// The obvious move is to run the existing 22 Dashboard parity tests through
/// both arms. It is not available: those fixtures are hand-built `[TipEntry]`
/// values, and turning a legacy pair into a `ShiftRecord` is the SERVER's
/// deriver (`private.derive_shifts`), which has no Swift equivalent on
/// device. Projecting records INTO entries exists, but building the fixtures
/// that way would make every case mirror-derived — and a test built by
/// mirroring cannot catch a defect in the mirror.
///
/// So these construct records directly and assert the same CLAIMS, not the
/// same code. What is covered here is the gap the mutation exposed, not a
/// duplicate of the legacy suite.
@Suite("Dashboard parity on the records arm", .serialized)
@MainActor
struct DashboardRecordsArmParityTests {

    private static let zone = PaydayTestZone.payroll

    private static func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func policies(rateCents: Int) -> CompensationPolicies {
        CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("recordsarm/rate"),
                effectiveFrom: .distantPast, hourlyRateCents: rateCents, provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("recordsarm/calendar"),
                effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone
            )]
        )
    }

    /// Two shifts in one biweekly period, one before "now" and one after, so
    /// a to-date cutoff is observably different from the period total. That
    /// gap is what makes the cutoff claim testable at all.
    private static func records() -> [ShiftRecord] {
        [
            ShiftRecord(workDate: at(2026, 10, 5), shiftPeriod: .dinner,
                        cashTipsCents: 0, creditTipsCents: 30_000, tipOutCents: 4_000,
                        hoursWorked: 8, recordedAt: at(2026, 10, 5)),
            ShiftRecord(workDate: at(2026, 10, 9), shiftPeriod: .dinner,
                        cashTipsCents: 0, creditTipsCents: 25_000,
                        hoursWorked: 8, recordedAt: at(2026, 10, 9)),
        ]
    }

    private static func currentRange() -> DayRange {
        DayRange(
            start: CivilDay(at(2026, 9, 28, hour: 0), in: zone),
            end: CivilDay(at(2026, 10, 11, hour: 0), in: zone)
        )
    }

    /// **The cutoff is a QUERY argument, not a second dataset.**
    ///
    /// This is the claim the mutation broke and that only one test caught on
    /// this arm. If the dataset itself were clamped, the two questions below
    /// could not disagree — and their disagreement is the whole point of a
    /// to-date hero sitting on a whole-period screen.
    @Test("one records dataset answers both the to-date and the whole-period question")
    func oneRecordsDatasetTwoScopes() throws {
        let comp = Self.policies(rateCents: 1_800)
        let snapshot = try #require(DashboardEarnings.build(
            records: Self.records(), policies: comp, payrollTimeZone: Self.zone
        ).snapshot)

        let range = Self.currentRange()
        let whole = snapshot.range(range)
        let toDate = snapshot.range(range, asOf: CivilDay(Self.at(2026, 10, 7, hour: 12), in: Self.zone))

        // The dataset is UNCLAMPED: the whole-period answer includes the
        // October 9 shift, which is after the cutoff.
        #expect(whole.knownComponents.earnedIncomeCents
                > toDate.knownComponents.earnedIncomeCents,
                "if these are equal the dataset was clamped, not the query")
        #expect(toDate.knownComponents.earnedIncomeCents > 0,
                "and the to-date answer is not simply empty")
    }

    /// **Criterion 5's first clause on this arm:** Dashboard == the History
    /// row == period detail, all three from records.
    ///
    /// Asserted through the builders the screens actually call, so a
    /// divergence in either builder's dataset shows up here rather than in
    /// a restatement of their arithmetic.
    @Test("Dashboard, the History row and period detail agree on one records period")
    func threeSurfacesAgreeOnRecords() throws {
        let comp = Self.policies(rateCents: 1_800)
        let records = Self.records()
        let range = Self.currentRange()

        let dashboard = try #require(DashboardEarnings.build(
            records: records, policies: comp, payrollTimeZone: Self.zone
        ).snapshot)
        let history = try #require(HistoryEarnings.build(
            entries: [], records: records, policies: comp,
            payrollTimeZone: Self.zone, representation: .records
        ).snapshot)

        let fromDashboard = dashboard.range(range).knownComponents.earnedIncomeCents
        let fromHistory = history.range(range).knownComponents.earnedIncomeCents

        #expect(fromDashboard == fromHistory)
        // Non-zero, so this is not two empty snapshots agreeing — the way a
        // parity assertion passes for the wrong reason.
        #expect(fromDashboard > 0)
        // One dataset, provably: the stamps match, so the two surfaces are
        // not merely arriving at the same total from different inputs.
        #expect(dashboard.stamp.digest == history.stamp.digest)
    }

    /// A shift on the FINAL day of the period is inside the engine's range.
    ///
    /// The legacy arm has `DashboardFinalDayMembershipTests` for this, and it
    /// failed under the mutation. The records arm had nothing. It is the
    /// original audit's own measured defect — "a 5pm shift on the period's
    /// last day was in the row's total and absent from the detail's" — so it
    /// is worth pinning on the arm that will carry it.
    @Test("a shift at 5pm on the period's final day is inside the records range")
    func finalDayShiftIsInRange() throws {
        let comp = Self.policies(rateCents: 1_800)
        // 17:00 on the period's last day. `PayPeriod.end` is that day's
        // midnight, which is what used to exclude it.
        let finalDay = Self.at(2026, 10, 11, hour: 17)
        let records = [ShiftRecord(
            workDate: finalDay, shiftPeriod: .dinner,
            cashTipsCents: 0, creditTipsCents: 12_000, hoursWorked: 6,
            recordedAt: finalDay
        )]

        let snapshot = try #require(DashboardEarnings.build(
            records: records, policies: comp, payrollTimeZone: Self.zone
        ).snapshot)
        let result = snapshot.range(Self.currentRange())

        #expect(result.knownComponents.earnedIncomeCents > 0,
                "the final day's shift must be inside the period, not after it")
        #expect(result.shiftIDs.contains(records[0].id),
                "and it must be THIS shift, not a total that happens to be non-zero")
    }

    // MARK: - The calendar-day chain, on the records arm

    /// **Criterion 5's second clause, end to end, on records:**
    /// calendar day == day detail == the sum of that day's shifts == the
    /// chart point.
    ///
    /// Measured before writing it, the same way the Dashboard gap was found:
    /// clamping `CalendarEarnings`' records-arm dataset to today failed ONE
    /// suite and three tests, all of them `gate5CalendarAgreesOnRecords`,
    /// written the same day. The legacy arm of the equivalent Dashboard
    /// mutation failed five suites and thirty-two tests.
    ///
    /// Four links, asserted as one identity rather than four separate
    /// equalities, because the defect this forbids is any ONE of them
    /// drifting: a tile that agrees with the chart while the day sheet it
    /// opens disagrees is the same failure as all four disagreeing.
    @Test("calendar day == day detail == sum of that day's shifts == chart point, on records")
    func calendarDayChainAgreesOnRecords() throws {
        let comp = Self.policies(rateCents: 1_800)
        let day = Self.at(2026, 10, 5)
        // Two shifts on ONE day, so "the sum of that day's shifts" is a real
        // sum rather than a single value trivially equal to itself.
        let records = [
            ShiftRecord(workDate: day, shiftPeriod: .lunch, cashTipsCents: 4_000,
                        creditTipsCents: 6_000, tipOutCents: 1_000, hoursWorked: 5,
                        recordedAt: day),
            ShiftRecord(workDate: day, shiftPeriod: .dinner, cashTipsCents: 3_000,
                        creditTipsCents: 9_000, hoursWorked: 6,
                        recordedAt: day.addingTimeInterval(3_600)),
        ]
        let civil = CivilDay(day, in: Self.zone)

        // 1. The calendar tile's day.
        let calendar = try #require(CalendarEarnings.snapshot(
            records: records, policies: comp, payrollTimeZone: Self.zone
        ))
        let tileCents = calendar.day(civil).knownComponents.earnedIncomeCents

        // 2. The day sheet that tile opens.
        let detail = DayDetailFacts(
            shiftRecords: records, date: day, policies: comp, payrollTimeZone: Self.zone
        )
        let detailCents = detail.total.cents

        // 3. The sum of that day's shifts, from the snapshot's own valuations.
        let shiftSum = calendar.shifts
            .filter { $0.workDay == civil }
            .reduce(0) { $0 + $1.components.earnedIncomeCents }

        // 4. The chart point for that day.
        let chart = EarningsChartFacts(
            snapshot: calendar,
            range: DayRange(start: civil, end: civil),
            timeZone: Self.zone
        )
        // One day in the range, so exactly one bar. Asserted rather than
        // assumed, because `first` on an empty array would make the
        // comparison below vacuously nil == nil.
        #expect(chart.points.count == 1, "a one-day range must draw exactly one bar")
        let chartCents = chart.points.first?.figure.cents

        #expect(tileCents > 0, "a zero day would satisfy every equality below trivially")
        #expect(detailCents == tileCents, "the day sheet must match the tile that opened it")
        #expect(shiftSum == tileCents, "the tile must be the sum of that day's own shifts")
        #expect(chartCents == tileCents, "the chart point must be the same day total")
        // And the day really does hold BOTH shifts, so the sum is a sum.
        #expect(calendar.day(civil).shiftIDs.count == 2)
    }

    // MARK: - The Dashboard sub-claims the legacy arm gates and records did not

    /// Builds the facts the way `DashboardView.body` does, from records.
    private func facts(
        _ records: [ShiftRecord],
        now: Date,
        schedule: PaySchedule,
        forcedPaydayPhase: PaydayMoment.Phase? = nil
    ) -> DashboardFacts {
        let comp = Self.policies(rateCents: 1_800)
        let dataset = DashboardEarnings.build(
            records: records, policies: comp, payrollTimeZone: Self.zone
        )
        return DashboardFacts(
            snapshot: dataset.snapshot,
            allShifts: dataset.shiftDays,
            allShiftRecords: dataset.shiftRecordDays,
            schedule: schedule,
            now: now,
            forcedPaydayPhase: forcedPaydayPhase,
            dismissedClosedEnd: nil,
            dismissedCheckEnd: nil,
            payrollTimeZone: Self.zone
        )
    }

    private static func schedule() -> PaySchedule {
        PaySchedule(
            frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0),
            payDelayDays: 5, firstWeekday: 2
        )
    }

    /// **"The drawer's rows reconcile to the bottom line it prints them
    /// under."** The legacy arm gates this
    /// (`DashboardPeriodParityTests.drawerRowsReconcile`, which failed under
    /// the mutation); the records arm did not.
    ///
    /// Criterion 5 at its smallest scale: a total printed directly above the
    /// rows it is made of. If those disagree the screen contradicts itself
    /// without needing a second surface.
    @Test("the drawer's rows reconcile to their bottom line, on records")
    func drawerRowsReconcileOnRecords() throws {
        let facts = facts(Self.records(), now: Self.at(2026, 10, 7, hour: 12),
                          schedule: Self.schedule())
        let snapshot = try #require(facts.snapshot)
        let result = snapshot.payPeriod(
            DayRange(start: CivilDay(facts.heroPeriod.start, in: Self.zone),
                     end: CivilDay(facts.heroPeriod.end, in: Self.zone)),
            asOf: CivilDay(Self.at(2026, 10, 7, hour: 12), in: Self.zone)
        )
        let c = result.knownComponents

        // Bound to locals first: the same expression inline trips the type
        // checker's time budget, which is a compiler error rather than a
        // test failure and reads as something else entirely.
        let tips = c.voluntaryCashCents + c.voluntaryCreditCents
        let gross = tips + c.gratuityFeesCents - c.tipOutCents
        let wages = c.regularWagesCents + c.overtimeWagesCents

        #expect(gross + wages == c.earnedIncomeCents,
                "the drawer's rows must sum to the bottom line above them")
        #expect(c.earnedIncomeCents > 0, "a zero drawer reconciles trivially")
        #expect(c.tipOutCents > 0, "the fixture must exercise a tip-out, or the sign is untested")
    }

    /// **"The check is the tips line plus gratuity plus wages, and the gap
    /// from the hero is exactly the cash."** The legacy arm gates this
    /// (`DashboardPaydayCardTests.checkReconcilesAgainstTheHero`); the
    /// records arm did not.
    ///
    /// The claim matters because the payday card and the hero sit on ONE
    /// screen showing different numbers ON PURPOSE — the check excludes cash
    /// the person already has. "Different on purpose" is only defensible if
    /// the difference is exactly the cash, and this is what makes that
    /// checkable rather than assertable.
    ///
    /// Asserted against the screen's OWN three figures rather than
    /// arithmetic rebuilt here, so a test cannot agree with itself while
    /// disagreeing with the screen.
    @Test("the payday card's check differs from the hero by exactly the cash, on records")
    func checkReconcilesAgainstTheHeroOnRecords() throws {
        // Both cash and credit, or the gap below is zero and proves nothing.
        let day = Self.at(2026, 10, 5)
        let records = [
            ShiftRecord(workDate: day, shiftPeriod: .dinner,
                        cashTipsCents: 7_000, creditTipsCents: 20_000,
                        tipOutCents: 2_000, hoursWorked: 8, recordedAt: day),
        ]
        // `.periodClosed` is what puts the payday card on screen at all --
        // the card is about the period whose CHECK is due, not the period in
        // progress. Without it `predictedPaycheck` is `.unavailable` over
        // zero shifts and the assertion below compares against nil, which is
        // a fixture mistake rather than a defect. The legacy test forces the
        // same phase for the same reason.
        let facts = facts(records, now: Self.at(2026, 10, 7, hour: 12),
                          schedule: Self.schedule(), forcedPaydayPhase: .periodClosed)

        let hero = try #require(facts.hero.cents)
        let check = try #require(facts.predictedPaycheck.cents)
        let cash = try #require(facts.paydayCash.cents)

        #expect(hero - check == cash,
                "the gap between the hero and the check must be exactly the cash")
        #expect(cash > 0, "the fixture must carry cash, or the gap is zero")
        #expect(check > 0)
    }
}
