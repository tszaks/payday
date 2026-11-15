import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// Criterion 5 on the records path: parity holds on real screen adapters.
///
/// ## What this file gates
///
/// Criterion 5 says the Dashboard, History and Calendar show one figure for
/// one period, through the real screen adapters. A suite that exists is not
/// proof that it gates anything, so each case here is written to fail when
/// one surface diverges from another: for example, `DashboardEarnings`
/// clamping its dataset to today while `HistoryEarnings` does not.
///
/// `ShiftRecord`s are the only stored shape since the flip, so the records
/// builder is the only arm. These cases pin the claims that a person would
/// meet on screen: the final-day membership, the drawer's reconciliation,
/// the payday card, the cutoff and the order of the shift list.
///
/// ## Why the fixtures are records
///
/// The fixtures construct `ShiftRecord`s directly. Turning a pair of
/// entries into a record is the SERVER's deriver (`private.derive_shifts`),
/// which has no Swift equivalent on device, and a fixture built by mirroring
/// the deriver cannot catch a defect in the mirror.
///
/// So these cases assert CLAIMS about the screen, not the same code twice.
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
            records: records, policies: comp, payrollTimeZone: Self.zone
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
    /// It is the original audit's own measured defect — "a 5pm shift on the
    /// period's last day was in the row's total and absent from the
    /// detail's" — so it is pinned here on the path that carries it.
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

    // MARK: - The Dashboard sub-claims, on records

    /// Builds the facts the way `DashboardView.body` does, from records.
    private func facts(
        _ records: [ShiftRecord],
        now: Date,
        schedule: PaySchedule,
        forcedPaydayPhase: PaydayMoment.Phase? = nil,
        paychecks: [PaycheckRecord] = []
    ) -> DashboardFacts {
        let comp = Self.policies(rateCents: 1_800)
        let dataset = DashboardEarnings.build(
            records: records, policies: comp, payrollTimeZone: Self.zone, paychecks: paychecks
        )
        return DashboardFacts(
            snapshot: dataset.snapshot,
            allShiftRecords: dataset.shiftRecordDays,
            allTipRecords: dataset.tipRecords,
            withholdingModel: dataset.withholdingModel,
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
    /// under."**
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
        #expect(c.earnedIncomeCents > 0, "a zero drawer reconciles trivially")
        #expect(c.tipOutCents > 0, "the fixture must exercise a tip-out, or the sign is untested")

        // The rows the Dashboard draws, each against the engine's own
        // component for the hero period.
        let rows = facts.heroBreakdownRows
        #expect(rows.map(\.label) == ["Cash tips", "Credit tips", "Wages", "Earned", "Tipped out"])
        let byLabel = Dictionary(rows.map { ($0.label, $0.cents) }, uniquingKeysWith: { a, _ in a })
        #expect(byLabel["Cash tips"] == c.voluntaryCashCents)
        #expect(byLabel["Credit tips"] == c.voluntaryCreditCents)
        #expect(byLabel["Wages"] == c.regularWagesCents)
        let subtotal = try #require(byLabel["Earned"] ?? nil, "no subtotal row")
        let tipOut = try #require(byLabel["Tipped out"] ?? nil, "no tip-out row")
        #expect(tipOut == -c.tipOutCents, "Tipped out must SUBTRACT, or the bottom line is gross")

        // The reconciliation a person reads down the drawer: the addends make
        // the subtotal, and the subtotal minus the tip-out is the hero.
        let addends = rows
            .filter { $0.label != "Earned" && $0.label != "Tipped out" }
            .compactMap(\.cents)
            .reduce(0, +)
        #expect(addends == subtotal, "the drawer's addends must make its subtotal")
        #expect(subtotal + tipOut == facts.hero.cents,
                "the drawer's rows must sum to the bottom line above them")
        #expect(facts.heroBreakdownTotal.cents == facts.hero.cents)
    }

    /// **"Nothing after tax under 2 stubs."** The drawer's check rows keep
    /// the before-tax row whenever the gross is available; the after-tax
    /// row appears only once the person's own stubs can fit a model. (The
    /// same two figures were one caption line on the hero's face until
    /// 2026-11-07; the rows carry the same rule.)
    @Test("heroCheckNet is unavailable under 2 qualifying stubs and available with 3")
    func heroCheckNetNeedsStubs() throws {
        func stub(_ day: Int, _ gross: Int, _ net: Int?) -> PaycheckRecord {
            PaycheckRecord(periodStart: Self.at(2026, 8, day, hour: 0), periodEnd: Self.at(2026, 8, day + 1, hour: 0),
                           paidTipsCents: 0, grossPayCents: gross, netPayCents: net)
        }
        let now = Self.at(2026, 10, 7, hour: 12)

        // One full stub plus one with no net: one qualifies, so no model.
        let thin = facts(Self.records(), now: now, schedule: Self.schedule(),
                         paychecks: [stub(1, 200_000, 165_000), stub(5, 210_000, nil)])
        #expect(!thin.heroCheckGross.isUnavailable)
        #expect(thin.heroCheckNet.isUnavailable)
        let thinRows = thin.heroCheckRows
        #expect(thinRows.map(\.label) == ["On your check, before tax"])
        #expect(thinRows.first?.cents == thin.heroCheckGross.cents)
        #expect(thinRows.first?.wholeDollars == false, "the check so far is exact, not a prediction")
        #expect(MetricID.expectedPaycheckGross.allowedLabels.contains(thinRows[0].label))

        let three = facts(Self.records(), now: now, schedule: Self.schedule(),
                          paychecks: [stub(1, 200_000, 165_000), stub(5, 220_000, 179_000), stub(9, 180_000, 151_000)])
        #expect(!three.heroCheckNet.isUnavailable)
        #expect(three.heroCheckNet.metric == .expectedPaycheckNet)
        #expect(three.heroCheckNet.completeness == three.heroCheckGross.completeness)
        // The fixture's period gross is below the three stubs' range, so the
        // caption is the extrapolation warning, standing alone: the stub
        // count left it on 2026-11-07 at Tyler's request.
        #expect(three.heroCheckNet.caption == "Outside the checks it has seen")
        let threeRows = three.heroCheckRows
        #expect(threeRows.map(\.label) == ["On your check, before tax", "After tax, about"])
        #expect(threeRows.last?.cents == three.heroCheckNet.cents)
        #expect(threeRows.last?.wholeDollars == true, "the net is a prediction: whole dollars")
        #expect(threeRows.last?.caption == three.heroCheckNet.caption)
        #expect(threeRows.last?.caption?.contains("stubs") != true)
        #expect(MetricID.expectedPaycheckNet.allowedLabels.contains(threeRows[1].label))
    }

    /// **"The after-tax line never names the stub count."** Tyler,
    /// 2026-11-07, on the drawer's "After tax, about $N / From 7 stubs":
    /// "Can we remove the 'from X paystubs' line??" The count is how the
    /// model was fitted, not something to act on. The Payday card line now
    /// stands without a caption and keeps the figure's warning after it.
    @Test("paydayNetLine stands without a caption and carries a warning after it")
    func paydayNetLineWithoutStubCount() {
        func net(_ caption: String?) -> EarningsFigure {
            EarningsFigure(metric: .expectedPaycheckNet, amount: .cents(123_456),
                           label: "After tax, about", caption: caption, completeness: .empty)
        }
        #expect(TakeHomeCopy.paydayNetLine(net(nil)) == "About $1,235 after tax")
        #expect(TakeHomeCopy.paydayNetLine(net("Outside the checks it has seen"))
                == "About $1,235 after tax · outside the checks it has seen")
    }

    /// **"A partial check still says what it is missing."** Codex on PR
    /// #170: the payday card reports the period that just closed while the
    /// hero above may already describe the new one, so with no take-home
    /// line to carry the gross figure's warning, the "Before tax" line
    /// carries it. Still one line.
    @Test("paydayBeforeTaxLine carries the gross figure's warning on the one line")
    func paydayBeforeTaxLineCarriesTheWarning() {
        func gross(_ caption: String?) -> EarningsFigure {
            EarningsFigure(metric: .expectedPaycheckGross, amount: .cents(200_000),
                           label: "Expected", caption: caption, completeness: .empty)
        }
        #expect(TakeHomeCopy.paydayBeforeTaxLine(gross(nil)) == "Before tax")
        #expect(TakeHomeCopy.paydayBeforeTaxLine(gross("wages missing for 1 shift"))
                == "Before tax · wages missing for 1 shift")
    }

    /// **"A wage-only period still shows its check."** The ledger has no
    /// tip rows for it, so `BreakdownRow.hasBreakdown` says there is nothing
    /// to itemize; but the check rows live in the drawer now, so the drawer
    /// must open for them or the figure the face used to state becomes
    /// unreachable (Codex and Devin on PR #166).
    @Test("the drawer opens for a wage-only current period because its check rows exist")
    func wageOnlyPeriodKeepsItsCheckReachable() throws {
        let now = Self.at(2026, 10, 7, hour: 12)
        let wageOnly = [
            ShiftRecord(workDate: Self.at(2026, 10, 5), shiftPeriod: .dinner,
                        cashTipsCents: 0, creditTipsCents: 0,
                        hoursWorked: 8, recordedAt: Self.at(2026, 10, 5)),
        ]
        let facts = facts(wageOnly, now: now, schedule: Self.schedule())
        #expect(!facts.heroCheckGross.isUnavailable, "a priced shift backs a check figure")
        #expect(facts.heroCheckRows.map(\.label) == ["On your check, before tax"])
        #expect(facts.heroHasBreakdown, "the check rows are in the drawer, so the drawer must open")
    }

    /// **"The check is the tips line plus gratuity plus wages, and the gap
    /// from the hero is exactly the cash."**
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
        // a fixture mistake rather than a defect.
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

    /// **"The hero still says where this period stands against the usual,
    /// on records."**
    ///
    /// The pace line is gated on `paceDeltaCents`, which came from a
    /// `StatsEngine` fed `allShifts.flatMap(\.items)` — a sentence that is
    /// only true on the legacy arm. A flipped account showed the hero, the
    /// rows and the drawer over record data and silently dropped the one
    /// line that says whether the number is good. The starvation also took
    /// the tonight reveal, which is why this asserts `paceDeltaCents`
    /// rather than the copy: the copy was never the bug.
    @Test("the pace comparison still has a history to compare against, on records")
    func paceComparisonHasHistoryOnRecords() {
        // Two completed periods each hold a shift, so the baseline is a real
        // median and the copy says "your usual pace" rather than "last
        // period". The current shift is deliberately much larger, so the
        // sign of the delta is not an artifact of tip-out rounding.
        let records = [
            ShiftRecord(workDate: Self.at(2026, 10, 5), shiftPeriod: .dinner,
                        creditTipsCents: 30_000, hoursWorked: 8,
                        recordedAt: Self.at(2026, 10, 5)),
            ShiftRecord(workDate: Self.at(2026, 9, 20), shiftPeriod: .dinner,
                        creditTipsCents: 10_000, hoursWorked: 8,
                        recordedAt: Self.at(2026, 9, 20)),
            ShiftRecord(workDate: Self.at(2026, 9, 6), shiftPeriod: .dinner,
                        creditTipsCents: 10_000, hoursWorked: 8,
                        recordedAt: Self.at(2026, 9, 6)),
        ]
        let facts = facts(records, now: Self.at(2026, 10, 7, hour: 12),
                          schedule: Self.schedule())

        #expect(facts.heroIsCurrent, "mid-period: the hero is this period, so the line should draw")
        let delta = facts.paceDeltaCents
        #expect(delta != nil,
                "the records arm fed StatsEngine an empty history, so the pace line vanished")
        #expect((delta ?? 0) > 0, "30k this period against two 10k baselines must read ahead")
        #expect(facts.pacePeriodCount == 2)
    }

    /// **"Newest shift first, on records."**
    ///
    /// `@Query` has no sort, so `DashboardFacts` received records in
    /// insertion order and rendered them verbatim — oldest at the top on a
    /// flipped account. The order the screen needs is
    /// `ShiftDays.groupedByShift`'s: newest day first, lunch before dinner
    /// inside a day. This feeds the rows in scrambled order and asserts the
    /// screen's list reads that way.
    @Test("the shift list reads newest-first, on records")
    func shiftRowsReadNewestFirstOnRecords() {
        let oldest = ShiftRecord(workDate: Self.at(2026, 10, 1),
                                 creditTipsCents: 5_000, hoursWorked: 5,
                                 recordedAt: Self.at(2026, 10, 1))
        let sameDayDinner = ShiftRecord(workDate: Self.at(2026, 10, 5), shiftPeriod: .dinner,
                                        creditTipsCents: 8_000, hoursWorked: 5,
                                        recordedAt: Self.at(2026, 10, 5, hour: 23))
        let sameDayLunch = ShiftRecord(workDate: Self.at(2026, 10, 5), shiftPeriod: .lunch,
                                       creditTipsCents: 6_000, hoursWorked: 4,
                                       recordedAt: Self.at(2026, 10, 5, hour: 15))
        let newest = ShiftRecord(workDate: Self.at(2026, 10, 9), shiftPeriod: .dinner,
                                 creditTipsCents: 9_000, hoursWorked: 6,
                                 recordedAt: Self.at(2026, 10, 9))
        // Insertion order is the scramble: oldest first, and the same-day
        // pair dinner-before-lunch so both halves of the sort are tested.
        let facts = facts([oldest, sameDayDinner, sameDayLunch, newest],
                          now: Self.at(2026, 10, 7, hour: 12),
                          schedule: Self.schedule())

        #expect(facts.shiftRecordDays.map(\.id) ==
                [newest.id, sameDayLunch.id, sameDayDinner.id, oldest.id])
    }
}
