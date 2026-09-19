import Testing
import Foundation
@testable import Payday

// MARK: - Fixtures

/// A gregorian calendar in the payroll zone, with the workweek start the
/// payroll calendar policy owns (Monday here, weekday 2).
private func payrollCalendar(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    calendar.firstWeekday = firstWeekday
    return calendar
}

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
    payrollCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func shiftID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
}

/// The compensation history a test STATES as its own. `LegacySnapshotBridge`
/// values with `PolicyStore.policies`, the user's real effective-dated
/// history, never a scalar this file re-stamps as `.distantPast`.
private func testPolicies(rateCents: Int? = 283, workweekStartWeekday: Int = 2) -> CompensationPolicies {
    let calendar = PayrollCalendarPolicy(
        id: PolicyMigration.deterministicID("history/calendar/\(workweekStartWeekday)"),
        effectiveFrom: .distantPast,
        workweekStartWeekday: workweekStartWeekday,
        payrollTimeZone: PaydayTestZone.payroll
    )
    guard let rateCents, rateCents > 0 else {
        return CompensationPolicies(rates: [], calendars: [calendar])
    }
    return CompensationPolicies(
        rates: [PayRatePolicy(
            id: PolicyMigration.deterministicID("history/rate/\(rateCents)"),
            effectiveFrom: .distantPast,
            hourlyRateCents: rateCents,
            provenance: .confirmed
        )],
        calendars: [calendar]
    )
}

/// Biweekly, ending Sat 2026-10-10, so `period(containing:)` yields
/// 2026-09-27 ... 2026-10-10 — the fourteen days every shape below lives in.
private func testSchedule(firstWeekday: Int = 2) -> PaySchedule {
    PaySchedule(
        frequency: .biweekly,
        anchorPeriodEnd: at(2026, 10, 10, hour: 0),
        firstWeekday: firstWeekday
    )
}

private let testPeriod = PayPeriod(start: at(2026, 9, 27, hour: 0), end: at(2026, 10, 10, hour: 0))

/// One render of both History surfaces over the same snapshot, which is what
/// every parity assertion here compares.
private struct HistoryRender {
    let snapshot: EarningsSnapshot?
    let build: HistoryEarnings.Build
    let list: PeriodsPageFacts
    let detail: PeriodDetailFacts

    init(
        entries: [TipEntry],
        paychecks: [PaycheckRecord] = [],
        policies: CompensationPolicies = testPolicies(),
        schedule: PaySchedule? = testSchedule(),
        period: PayPeriod = testPeriod,
        now: Date = at(2026, 10, 3)
    ) {
        let calendar = payrollCalendar()
        build = HistoryEarnings.build(
            entries: entries,
            policies: policies,
            payrollTimeZone: PaydayTestZone.payroll,
            calendar: calendar
        )
        snapshot = build.snapshot
        list = PeriodsPageFacts(
            snapshot: build.snapshot,
            paycheckRecords: paychecks,
            schedule: schedule,
            payrollTimeZone: PaydayTestZone.payroll,
            now: now,
            calendar: calendar
        )
        detail = PeriodDetailFacts(
            snapshot: build.snapshot,
            shiftDays: build.shiftDays,
            paycheckRecords: paychecks,
            period: period,
            schedule: schedule,
            payrollTimeZone: PaydayTestZone.payroll,
            calendar: calendar
        )
    }

    /// The list row for the period `detail` rendered.
    var row: PeriodsPageFacts.Row? {
        list.rows.first { $0.period == testPeriod }
    }
}

/// C1's five shifts with Thursday's hours missing, moved into the test
/// period: 615, 585, 630, nil and 360 minutes at $2.83, zero tips. The week
/// is `.partial(missingHours: 1)`, its wages are 10330, and $/hr reads
/// 4 of 5 shifts.
private func c1Entries() -> [TipEntry] {
    let minutes: [Double?] = [615, 585, 630, nil, 360]
    return minutes.enumerated().map { index, m in
        TipEntry(
            date: at(2026, 9, 28 + index),
            amountCents: 0,
            kind: .credit,
            hoursWorked: m.map { $0 / 60 },
            shiftPeriod: .dinner,
            shiftID: shiftID(index + 1)
        )
    }
}

/// H1: 10000c over 300 minutes plus 10000c with no hours logged at all, and
/// no rate policy. $/hr is 2000c over the COVERED shift only, not 4000c over
/// the whole period's income.
private func h1Entries() -> [TipEntry] {
    [
        TipEntry(date: at(2026, 9, 28), amountCents: 10_000, kind: .cash, hoursWorked: 5,
                 shiftPeriod: .dinner, shiftID: shiftID(1)),
        TipEntry(date: at(2026, 9, 29), amountCents: 10_000, kind: .cash,
                 shiftPeriod: .dinner, shiftID: shiftID(2))
    ]
}

// MARK: - The invariant

/// Definition of Done #5, the History clause: **the History row equals period
/// detail equals that period's range query.**
///
/// Measured on the real adapters, not a helper: `PeriodsPageFacts` and
/// `PeriodDetailFacts` are constructed here exactly as `PeriodsView` and
/// `PeriodDetailView` construct them, over one `HistoryEarnings.build`.
@Suite("A History row, the period it opens, and the range query are one answer")
struct HistoryRowEqualsPeriodDetailTests {
    @Test("row, hero and range query agree to the cent, select the same shifts, and carry the same stamp")
    func rowEqualsDetailEqualsRangeQuery() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 5_000, kind: .credit, hoursWorked: 4.25,
                     shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 9, 28, hour: 18), amountCents: 6_000, kind: .credit, hoursWorked: 5.5,
                     shiftPeriod: .dinner, shiftID: shiftID(2)),
            TipEntry(date: at(2026, 10, 2), amountCents: 4_000, kind: .cash, hoursWorked: 6,
                     tipOutCents: 800, shiftPeriod: .dinner, shiftID: shiftID(3))
        ]
        let render = HistoryRender(entries: entries)
        let snapshot = try #require(render.snapshot)
        let row = try #require(render.row)
        let hero = try #require(render.detail.result)

        // The third answer, asked straight of the engine.
        let query = snapshot.range(DayRange(
            start: CivilDay(testPeriod.start, in: PaydayTestZone.payroll),
            end: CivilDay(testPeriod.end, in: PaydayTestZone.payroll)
        ))

        // W1's day (5000 + 1203, 6000 + 1556) plus a 4000 cash shift netting
        // 3200 after its 800 tip-out, with 6h at 283c.
        #expect(query.knownComponents.earnedIncomeCents == 5_000 + 6_000 + 2_759 + 4_000 - 800 + 1_698)
        #expect(row.earned.cents == query.knownComponents.earnedIncomeCents)
        #expect(hero.knownComponents.earnedIncomeCents == query.knownComponents.earnedIncomeCents)
        #expect(row.earned.cents == render.detail.hero.cents)

        // Same selection, not merely the same total.
        #expect(row.result?.shiftIDs == query.shiftIDs)
        #expect(hero.shiftIDs == query.shiftIDs)
        #expect(hero.shiftIDs.count == 3)

        // Same dataset, provably: one stamp behind both surfaces.
        #expect(render.list.stamp == render.detail.stamp)
        #expect(render.list.stamp == snapshot.stamp)
        #expect(row.result?.manifestDigest == hero.manifestDigest)

        // And the rows under the hero are the hero's own shifts.
        let rowCents = render.detail.shiftDays.compactMap {
            snapshot.valuation($0.shiftID)?.components.earnedIncomeCents
        }
        #expect(rowCents.count == 3)
        #expect(rowCents.reduce(0, +) == hero.knownComponents.earnedIncomeCents)
    }

    /// The divergence this migration closes, measured on both superseded
    /// formulas.
    ///
    /// `PeriodsPageFacts` bucketed an entry by
    /// `calculator.period(containing: entry.date)`, which is the period that
    /// entry's day falls in. `PeriodDetailFacts` filtered instead on
    /// `entry.date >= period.start && entry.date <= period.end`, and
    /// `period.end` is MIDNIGHT of the period's last day. So any shift on a
    /// period's last day whose timestamp is not exactly midnight counted in
    /// the History row and was invisible on the screen that row opened: not
    /// in its total, not in its chart, not even in its Shifts list.
    ///
    /// `docs/METRICS.md` HP-07 records the fragility as a reliance
    /// ("this relies on TipEntry.date being midnight-normalized at every
    /// write path"), which makes it a bug waiting on one unnormalized row
    /// from sync, an import, or an older build.
    @Test("MEASURED: a 5pm shift on the period's last day was in the row's total and absent from the detail's")
    func lastDayShiftUsedToVanishFromTheDetail() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 3_000, kind: .credit, hoursWorked: 5,
                     shiftPeriod: .dinner, shiftID: shiftID(1)),
            // The period's last day, logged at 5pm rather than midnight.
            TipEntry(date: at(2026, 10, 10), amountCents: 7_000, kind: .credit, hoursWorked: 5,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]

        // The superseded formulas, run here rather than described.
        let calendar = payrollCalendar()
        let calculator = PayPeriodCalculator(
            payrollTimeZone: PaydayTestZone.payroll,
            schedule: testSchedule(),
            calendar: calendar
        )
        let oldRowEntries = entries.filter { calculator.period(containing: $0.date) == testPeriod }
        let oldDetailEntries = entries.filter { $0.date >= testPeriod.start && $0.date <= testPeriod.end }
        #expect(oldRowEntries.count == 2)
        #expect(oldDetailEntries.count == 1, "the 5pm shift on the last day failed `date <= period.end`")
        #expect(TipBreakdown.total(of: oldRowEntries).netTotalCents == 10_000)
        #expect(TipBreakdown.total(of: oldDetailEntries).netTotalCents == 3_000)

        // One engine, one selection: both surfaces now see both shifts.
        let render = HistoryRender(entries: entries)
        let row = try #require(render.row)
        let hero = try #require(render.detail.result)
        #expect(hero.shiftIDs.count == 2)
        #expect(render.detail.shiftDays.count == 2)
        #expect(row.earned.cents == hero.knownComponents.earnedIncomeCents)
        // 10h in one Monday-start week at 283c is 2830, no overtime.
        #expect(row.earned.cents == 10_000 + 2_830)
    }

    /// The rows partition the timeline, so the list cannot show a total that
    /// double-counts or loses a shift at a period boundary.
    @Test("the visible rows sum to one range query over the same span")
    func rowsPartitionTheSpan() throws {
        let entries = (0..<8).map { index in
            TipEntry(
                date: at(2026, 8, 1 + index * 5),
                amountCents: 1_000,
                kind: .credit,
                hoursWorked: 8,
                shiftPeriod: .dinner,
                shiftID: shiftID(index + 1)
            )
        }
        let render = HistoryRender(entries: entries)
        let snapshot = try #require(render.snapshot)
        let rows = render.list.rows
        #expect(rows.count > 1)

        let first = try #require(rows.last)
        let last = try #require(rows.first)
        let whole = snapshot.range(DayRange(
            start: CivilDay(first.period.start, in: PaydayTestZone.payroll),
            end: CivilDay(last.period.end, in: PaydayTestZone.payroll)
        ))
        let summed = rows.compactMap(\.earned.cents).reduce(0, +)
        #expect(rows.compactMap(\.earned.cents).count == rows.count)
        #expect(summed == whole.knownComponents.earnedIncomeCents)
        #expect(whole.completeness.totalShifts == 8)
    }

    /// The reason the snapshot covers the WHOLE history and not the period:
    /// the ledger allocates overtime over a complete workweek, so a snapshot
    /// bounded by the pay period loses the overtime a straddling week
    /// produced. `docs/METRICS.md` HP-01 and HP-15 record that loss as a
    /// live divergence ("wages' weekly OT sees only this period's entries").
    @Test("a workweek straddling the period boundary keeps the overtime it produced")
    func straddlingWorkweekKeepsItsOvertime() throws {
        // Mon 2026-09-21 through Fri 2026-09-25 are 10h each — 50 hours, so
        // the Monday-start workweek of 2026-09-21 is already 10 hours past
        // the threshold. Those five days are OUTSIDE the test period, which
        // starts Sun 2026-09-27 — and 2026-09-27 is the LAST day of that
        // same workweek. So the period's only shift is a straddler.
        var entries = (0..<5).map { index in
            TipEntry(date: at(2026, 9, 21 + index), amountCents: 0, kind: .credit, hoursWorked: 10,
                     shiftPeriod: .dinner, shiftID: shiftID(index + 1))
        }
        entries.append(TipEntry(date: at(2026, 9, 27), amountCents: 0, kind: .credit, hoursWorked: 8,
                                shiftPeriod: .dinner, shiftID: shiftID(6)))

        let render = HistoryRender(entries: entries, policies: testPolicies(rateCents: 1_000))
        let snapshot = try #require(render.snapshot)
        // The week is 58 hours, so every one of Sunday's 8 is overtime.
        let straddler = try #require(snapshot.valuation(shiftID(6)))
        #expect(straddler.components.overtimeWagesCents == 8 * 1_500)
        #expect(straddler.components.regularWagesCents == 0)
        #expect(try #require(render.detail.result).shiftIDs == [shiftID(6)])
        #expect(render.detail.hero.cents == 12_000)

        // Handed ONLY the period's own shifts, the same Sunday is straight
        // time: 8h x $10. That 4000c gap is what a per-period snapshot loses.
        let periodOnly = HistoryEarnings.build(
            entries: entries.filter { $0.date >= testPeriod.start },
            policies: testPolicies(rateCents: 1_000),
            payrollTimeZone: PaydayTestZone.payroll,
            calendar: payrollCalendar()
        )
        #expect(periodOnly.snapshot?.valuation(shiftID(6))?.components.overtimeWagesCents == 0)
        #expect(periodOnly.snapshot?.valuation(shiftID(6))?.components.regularWagesCents == 8_000)
        #expect(straddler.components.wagesCents - 8_000 == 4_000)
    }
}

// MARK: - The chart under the hero

/// Definition of Done #5: the chart point equals the day total, and the bars
/// reconcile with the figure above them. Wave 0 made every bar an
/// `EarningsResult`; this is the assertion that period detail's hero is the
/// same query the bars sum to.
@Suite("Period detail's chart reconciles with its own hero")
struct PeriodChartReconcilesWithHeroTests {
    @Test("the bars sum to the hero, and the chart's whole-range answer IS the hero's result")
    func barsSumToTheHero() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 5_000, kind: .credit, hoursWorked: 4.25,
                     shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 9, 28, hour: 18), amountCents: 6_000, kind: .credit, hoursWorked: 5.5,
                     shiftPeriod: .dinner, shiftID: shiftID(2)),
            TipEntry(date: at(2026, 10, 2), amountCents: 4_000, kind: .cash, hoursWorked: 6,
                     tipOutCents: 800, shiftPeriod: .dinner, shiftID: shiftID(3))
        ]
        let render = HistoryRender(entries: entries)
        let hero = try #require(render.detail.result)
        let chart = render.detail.chartFacts

        // A fourteen-day period is still daily, so there is one bar per day.
        #expect(chart.granularity == .day)
        #expect(chart.points.count == 14)
        #expect(chart.points.reduce(0) { $0 + $1.cents } == hero.knownComponents.earnedIncomeCents)

        let whole = try #require(chart.whole)
        #expect(whole.knownComponents == hero.knownComponents)
        #expect(whole.shiftIDs == hero.shiftIDs)
        #expect(whole.manifestDigest == hero.manifestDigest)
        #expect(chart.stamp == render.detail.stamp)

        // The double-shift day is one bar worth both of its shifts, which is
        // the W1 allocation and not two independent roundings.
        let monday = try #require(chart.points.first { $0.range.start == CivilDay(year: 2026, month: 9, day: 28) })
        #expect(monday.cents == 5_000 + 6_000 + 2_759)
        #expect(monday.cents != 5_000 + 6_000 + 2_760)
    }

    @Test("a partial day's bar knows it is partial, so the chart can say so")
    func partialDayBarIsMarked() throws {
        let render = HistoryRender(entries: c1Entries())
        let chart = render.detail.chartFacts
        let thursday = try #require(chart.points.first { $0.range.start == CivilDay(year: 2026, month: 10, day: 1) })
        #expect(thursday.isPartial)
        #expect(chart.points.filter(\.isPartial).count == 1)
    }
}

// MARK: - The two audit findings

/// HP-08. The period's $/hr divided the WHOLE wage-inclusive total by only
/// the hours that were logged, so a shift with tips and no hours inflated the
/// rate while contributing nothing to its denominator — fixture H1, and the
/// registry's `hourlyRate` row is explicit that both sides are taken over the
/// covered shifts only and that the figure "carries N of M".
@Suite("Period detail's $/hr is the engine's covered rate, and it says what it covers")
struct PeriodHourlyRateCoverageTests {
    @Test("MEASURED: H1's period read $40/hr with no coverage stated; it now reads $20.00/hr over 1 of 2 shifts")
    func h1RateExcludesTheUncoveredShiftFromBothSides() throws {
        let render = HistoryRender(entries: h1Entries(), policies: testPolicies(rateCents: nil))
        let result = try #require(render.detail.result)

        // The engine's rate: covered income over covered minutes.
        #expect(result.hourlyRateCents == 2_000)
        #expect(result.coveredShiftCount == 1)
        #expect(result.completeness.totalShifts == 2)
        #expect(render.detail.hourlyRateCaption == "Averaging $20.00/hr · 1 of 2 shifts")

        // The superseded formula, run rather than described: the whole
        // period's income over only the logged hours.
        let groups = render.build.shiftDays
        let loggedHours = WageEstimate.loggedHours(shiftGroups: groups.map(\.items))
        #expect(loggedHours == 5)
        let oldDollarsPerHour = Double(result.knownComponents.earnedIncomeCents) / 100 / loggedHours
        #expect(Int((oldDollarsPerHour * 100).rounded()) == 4_000, "H1's wrongAnswers.allIncomeOverCoveredMinutes")
        #expect(Money.wholeDollarString(fromCents: 4_000) == "$40")
    }

    @Test("C1's partial week reads the fixture's own caption, 4 of 5 shifts")
    func c1RateStatesItsCoverage() throws {
        let render = HistoryRender(entries: c1Entries())
        let result = try #require(render.detail.result)
        #expect(result.hourlyRateCents == 283)
        #expect(render.detail.hourlyRateCaption == "Averaging $2.83/hr · 4 of 5 shifts")
    }

    @Test("with every shift covered the caption states the rate and nothing else")
    func fullCoverageStatesNoFraction() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 0, kind: .credit, hoursWorked: 10,
                     shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let render = HistoryRender(entries: entries, policies: testPolicies(rateCents: 1_000))
        #expect(render.detail.hourlyRateCaption == "Averaging $10.00/hr")
    }

    @Test("no covered minutes means no rate, never a fabricated $0/hr")
    func noCoverageRendersNoRate() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 5_000, kind: .cash,
                     shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let render = HistoryRender(entries: entries)
        #expect(try #require(render.detail.result).hourlyRateCents == nil)
        #expect(render.detail.hourlyRateCaption == nil)
    }
}

/// HP-10 and [SC-02]/[SC-03]. The drawer's four figures now come from
/// `BreakdownRow.ledgerRows(_:)`, `.total(_:)`, `.lipText(_:)` and
/// `.hasBreakdown(_:)` over one `EarningsResult` — wave 0 wrote and tested
/// all four and left them with no production caller. The tip-out in
/// particular is READ from `components.tipOutCents` instead of being
/// reconstructed as `max(0, cash + credit + gratuity − net)` across two
/// independent helper chains.
@Suite("Period detail's drawer is the shared ledger composition")
struct PeriodDrawerReadsTheLedgerTests {
    private func tipOutEntries() -> [TipEntry] {
        [
            TipEntry(date: at(2026, 9, 28), amountCents: 12_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 2_000, shiftPeriod: .dinner, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 9, 29), amountCents: 3_000, kind: .cash, hoursWorked: 4,
                     shiftPeriod: .lunch, shiftID: shiftID(2))
        ]
    }

    @Test("the Tipped out row is the ledger's own tip-out, not a difference of two chains")
    func tipOutIsRead() throws {
        let render = HistoryRender(entries: tipOutEntries())
        let result = try #require(render.detail.result)
        let components = result.knownComponents
        #expect(components.tipOutCents == 2_000)

        let tippedOut = try #require(render.detail.breakdownRows.first { $0.label == "Tipped out" })
        #expect(tippedOut.cents == -2_000)

        // The subtotal above it is `EarningsComponents.grossBeforeTipOutCents`,
        // the engine's, rather than a four-term addition written out twice.
        let earned = try #require(render.detail.breakdownRows.first { $0.label == "Earned" })
        #expect(earned.cents == components.grossBeforeTipOutCents)
        #expect(earned.cents == 12_000 + 3_000 + (283 * 12))
        #expect(earned.dividerAbove)

        // And the collapsed lip reconciles with the hero directly above it:
        // Earned − Tipped out is exactly the hero.
        #expect(render.detail.hero.cents == components.grossBeforeTipOutCents - 2_000)
    }

    @Test("the bottom line's label is CompletenessCopy's: a period with a tip-out reads You kept")
    func totalRowTakesTheCompletenessLabel() throws {
        let render = HistoryRender(entries: tipOutEntries())
        let result = try #require(render.detail.result)
        #expect(render.detail.breakdownTotal.label == "You kept")
        #expect(render.detail.breakdownTotal.cents == result.knownComponents.earnedIncomeCents)
        #expect(render.detail.breakdownTotal.emphasized)
    }

    /// The measurement `docs/METRICS.md` [SC-02] records: the shipping hero
    /// printed "Total" over a period the engine could only partly value.
    @Test("MEASURED: a partial period said Total and now says Known so far")
    func partialPeriodNeverSaysTotal() throws {
        let render = HistoryRender(entries: c1Entries())
        let result = try #require(render.detail.result)
        #expect(result.completeness.state == .partial(missingHours: 1, missingRate: 0))

        // The superseded label, run rather than described.
        let oldLabel = result.knownComponents.tipOutCents > 0 ? "You kept" : "Total"
        #expect(oldLabel == "Total")

        #expect(render.detail.breakdownTotal.label == "Known so far")
        #expect(render.detail.breakdownTotal.label != "Total")
        #expect(render.detail.hero.mayBeCalledATotal == false)
        #expect(render.detail.hero.caption == "wages missing for 1 shift")
        // The headline is what IS known: C1's 10330 of wages.
        #expect(render.detail.hero.cents == 10_330)
    }

    @Test("wage rows appear only for a selection the ledger valued, and carry the calendar hours split")
    func wageRowsFollowTheValuation() throws {
        let render = HistoryRender(entries: h1Entries(), policies: testPolicies(rateCents: nil))
        #expect(render.detail.breakdownRows.contains { $0.label.hasPrefix("Wages") } == false)
        #expect(render.detail.breakdownRows.map(\.label) == ["Cash tips", "Credit tips"])

        let valued = HistoryRender(entries: c1Entries())
        let wageRow = try #require(valued.detail.breakdownRows.first { $0.label == "Wages" })
        // "carry the calendar hours split" is the test's name, so the hours
        // have to be asserted wherever they live -- now the caption.
        #expect(wageRow.caption?.isEmpty == false)
    }

    @Test("a wage-only period has no decomposition, so the drawer does not open")
    func wageOnlyPeriodHasNoBreakdown() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 0, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let render = HistoryRender(entries: entries)
        #expect(render.detail.hasBreakdown == false)
        #expect(try #require(render.detail.result).knownComponents.wagesCents > 0)
        #expect(render.detail.hero.cents == 283 * 8)
    }
}

// MARK: - Completeness presentation

/// Rule 4: views render `EarningsFigure`, `.partial` never renders "Total",
/// and an unavailable read renders no currency at all.
@Suite("History renders figures, and an unreadable dataset renders no money")
struct HistoryFigurePresentationTests {
    /// A RECORDED CHECK is passed in deliberately. With `paycheckRecords: []`
    /// this test could not see the defect it now pins: `PeriodCheckComparison`
    /// used to build a full comparison against a zero expectation when the
    /// result was nil, so the row printed "+$95.00" over "checked" in green
    /// beside the en-dash placeholder and the detail printed "$95.00 over."
    /// over "Logged $0.00 · check paid $95.00" — a fabricated verdict standing
    /// on no dataset, with a literal `$0.00` for a figure the engine refused.
    @Test("with no snapshot, every figure on both surfaces is unavailable and none has currency text")
    func noSnapshotRendersPlaceholders() {
        let paycheck = PaycheckRecord(
            periodStart: testPeriod.start,
            periodEnd: testPeriod.end,
            paidTipsCents: 9_500
        )
        let list = PeriodsPageFacts(
            snapshot: nil,
            paycheckRecords: [paycheck],
            schedule: testSchedule(),
            payrollTimeZone: PaydayTestZone.payroll,
            now: at(2026, 10, 3),
            calendar: payrollCalendar()
        )
        #expect(list.stamp == nil)
        #expect(list.isUnbacked)
        #expect(list.yearToDate.isUnavailable)
        #expect(list.yearToDate.text == nil)
        #expect(list.hasYearToDate == false)
        #expect(list.rows.allSatisfy { $0.earned.text == nil })
        #expect(list.rows.allSatisfy { $0.result == nil })
        // The check is matched to its period — this is not "no paycheck" —
        // and the COMPARISON still refuses, because there is no expectation
        // to compare it against.
        #expect(list.rows.contains { $0.paycheck?.id == paycheck.id })
        #expect(list.rows.allSatisfy { $0.checked == nil })

        let detail = PeriodDetailFacts(
            snapshot: nil,
            shiftDays: [],
            paycheckRecords: [paycheck],
            period: testPeriod,
            schedule: testSchedule(),
            payrollTimeZone: PaydayTestZone.payroll,
            calendar: payrollCalendar()
        )
        #expect(detail.isUnbacked)
        #expect(detail.hero.text == nil)
        #expect(detail.hero.isUnavailable)
        #expect(detail.hourlyRateCaption == nil)
        #expect(detail.breakdownRows.isEmpty)
        #expect(detail.breakdownTotal.cents == nil)
        #expect(detail.hasBreakdown == false)
        #expect(detail.chartFacts.points.isEmpty)
        #expect(detail.paycheck?.id == paycheck.id)
        #expect(detail.checked == nil)
        // No expectation can be stated either, so the caption names no money
        // — and, with a check recorded, it says which half is missing rather
        // than describing an entered check as still expected.
        #expect(detail.noPaycheckCaption.contains("$") == false)
        #expect(detail.noPaycheckCaption == "Check recorded · Payday couldn't read your shifts right now.")
        // Nothing for the sheet to audit against either, so every engine-side
        // check in it stays silent instead of reporting the stub as over zero.
        #expect(detail.expectation.grossCents == nil)
        #expect(detail.expectation.auditableTipsLineCents == nil)
        #expect(detail.expectation.gratuityFeesCents == nil)
        #expect(detail.expectation.hasAuditableWages == false)
    }

    @Test("wages off labels the figure Tips, because that is the metric it is")
    func wagesOffLabelsTips() throws {
        let render = HistoryRender(entries: h1Entries(), policies: testPolicies(rateCents: nil))
        #expect(render.detail.hero.label == "Tips")
        #expect(render.detail.hero.metric == .nonWageEarnings)
        #expect(render.detail.breakdownTotal.label == "Tips")
        #expect(try #require(render.row).earned.label == "Tips")
    }

    @Test("an estimated rate carries its caption on the year-to-date headline")
    func estimatedCarriesItsCaption() throws {
        let assumed = CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("history/rate/assumed"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 283,
                provenance: .assumedFromLegacySetting
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("history/calendar/2"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: PaydayTestZone.payroll
            )]
        )
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 5_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let render = HistoryRender(entries: entries, policies: assumed)
        #expect(render.list.yearToDate.caption == "Wages estimated from your current rate")
        #expect(render.detail.hero.caption == "Wages estimated from your current rate")
        #expect(render.list.yearToDateShiftCountText == "1 shift")
    }
}

// MARK: - The paycheck comparison

/// HP-02 through HP-04 against HP-22 through HP-24: the list row's "checked"
/// delta and period detail's verdict are the same comparison, and they used
/// to be two implementations over two bases with two different rules for
/// matching a check to a period.
@Suite("The History row's checked delta and period detail's verdict are one comparison")
struct HistoryPaycheckComparisonTests {
    @Test("both surfaces read one expected side, from the period's own result")
    func rowAndDetailAgreeOnTheCheck() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 12_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 2_000, shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let paycheck = PaycheckRecord(
            periodStart: testPeriod.start,
            periodEnd: testPeriod.end,
            paidTipsCents: 9_500
        )
        let render = HistoryRender(entries: entries, paychecks: [paycheck])
        let result = try #require(render.detail.result)
        let rowChecked = try #require(render.row?.checked)
        let detailChecked = try #require(render.detail.checked)

        #expect(rowChecked == detailChecked)
        // Credit 12000 net of the 2000 tip-out, plus no gratuity.
        #expect(detailChecked.expectedTipsAndGratuityCents == 10_000)
        #expect(detailChecked.expectedTipsAndGratuityCents
            == PredictedPaycheck.tipsAndGratuityCents(from: result.knownComponents))
        #expect(detailChecked.paidTipEarningsCents == 9_500)
        #expect(detailChecked.deltaCents == -500)
        #expect(detailChecked.isShort)
        #expect(detailChecked.usesCreditOnly)
        #expect(render.detail.paycheck?.id == render.row?.paycheck?.id)
    }

    @Test("two checks recorded for one period pick the same one on both surfaces, whatever order they arrive in")
    func duplicateChecksResolveDeterministically() throws {
        let first = PaycheckRecord(periodStart: testPeriod.start, periodEnd: testPeriod.end, paidTipsCents: 1_000)
        let second = PaycheckRecord(periodStart: testPeriod.start, periodEnd: testPeriod.end, paidTipsCents: 2_000)
        let ascending = HistoryEarnings.paycheck(for: testPeriod, in: [first, second])
        let descending = HistoryEarnings.paycheck(for: testPeriod, in: [second, first])
        #expect(ascending?.id == descending?.id)
        // The engine's own canonical order: periodEnd, periodStart, then id.
        let expected = [first, second].min { $0.id.uuidString < $1.id.uuidString }
        #expect(ascending?.id == expected?.id)
    }

    @Test("the expected whole check comes off the same components as the hero")
    func expectedCheckMatchesTheResult() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 12_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 2_000, shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let render = HistoryRender(entries: entries)
        let result = try #require(render.detail.result)
        #expect(render.detail.expectedCheckCents == 10_000 + (283 * 8))
        #expect(render.detail.expectedCheckCents == PredictedPaycheck.cents(from: result.knownComponents))
        #expect(render.detail.noPaycheckCaption.hasPrefix("Expected \(Money.string(fromCents: render.detail.expectedCheckCents))"))
    }
}

// MARK: - Period detail and the sheet it opens

/// The screen's expectation and the sheet's audit basis are ONE value.
///
/// `PaycheckEntrySheet` is group 2.5's file in wave 2, but the sheet is opened
/// by this screen and used to rebuild its own basis out of two superseded
/// rules. Migrating period detail's expectation onto the engine while leaving
/// that in place splits the paycheck comparison across the sheet boundary, so
/// wave 1 moves the BASIS and leaves 2.5 the reconciler.
@Suite("Period detail and the paycheck sheet it opens audit against one basis")
struct PaycheckAuditBasisParityTests {
    /// Both halves of the divergence in one fixture, because either alone
    /// passes on a fixture that lacks the other:
    ///
    /// - **A final-day shift.** 6h at 18:00 on 2026-10-10, the period's last
    ///   day. `PayPeriod.end` is that day's MIDNIGHT, so the sheet's old
    ///   `entry.date <= period.end` filter dropped it while the engine's
    ///   `range(_:)` over civil days includes the whole day.
    /// - **A grid weekday set against the policy.** The POLICY's workweek
    ///   starts Sunday; `PaySchedule.firstWeekday` says Monday. Five 10-hour
    ///   days from Sunday 2026-09-27 are one 50h week under the policy (10h of
    ///   overtime) and 10h + 40h under the grid (none).
    private func entries() -> [TipEntry] {
        let week: [TipEntry] = [
            (2026, 9, 27, 1), (2026, 9, 28, 2), (2026, 9, 29, 3),
            (2026, 9, 30, 4), (2026, 10, 1, 5)
        ].map { year, month, day, index in
            TipEntry(date: at(year, month, day), amountCents: 10_000, kind: .credit,
                     hoursWorked: 10, shiftID: shiftID(index))
        }
        let finalDay = TipEntry(
            date: at(2026, 10, 10, hour: 18), amountCents: 20_000, kind: .credit,
            hoursWorked: 6, shiftID: shiftID(6)
        )
        return week + [finalDay]
    }

    private func render() -> HistoryRender {
        HistoryRender(
            entries: entries(),
            policies: testPolicies(rateCents: 1_000, workweekStartWeekday: 1),
            schedule: testSchedule(firstWeekday: 2)
        )
    }

    @Test("the sheet's expected check is the screen's, to the cent, over a fixture carrying both halves of the old divergence")
    func sheetBasisEqualsTheScreensExpectation() throws {
        let render = render()
        let result = try #require(render.detail.result)
        let basis = render.detail.expectation

        // Every shift the engine selected, including the final-day one the
        // sheet's entry-date filter used to drop.
        #expect(result.shiftIDs.count == 6)

        // $700.00 of credit tips (the final-day $200.00 included) and
        // $610.00 of wages: 40h regular + 10h overtime in the policy's
        // Sunday-start week, plus 6h regular in the next one.
        #expect(basis.auditableTipsLineCents == 70_000)
        #expect(basis.gratuityFeesCents == nil)
        #expect(basis.regularWagesCents == 46_000)
        #expect(basis.overtimeWagesCents == 15_000)
        #expect(basis.wagesCents == 61_000)
        #expect(basis.overtimeMinutes == 600)
        #expect(basis.minutes == 3_360)

        // One expectation, and it is the screen's own.
        #expect(basis.grossCents == 131_000)
        #expect(basis.grossCents == render.detail.expectedCheckCents)
        #expect(basis.grossCents == PredictedPaycheck.cents(from: result.knownComponents))

        // The two superseded halves, named so a regression is legible rather
        // than a bare number mismatch. Each of these was the sheet's answer.
        #expect(basis.auditableTipsLineCents != 50_000,
                "the superseded entry.date <= period.end filter, dropping the final-day shift")
        #expect(basis.wagesCents != 50_000,
                "the superseded PaySchedule.firstWeekday allocation, losing the week's overtime")
        #expect(basis.grossCents != 100_000,
                "the superseded basis: both halves at once")
    }

    @Test("the basis follows the engine, so the pay-period grid cannot move the audit either")
    func gridWeekdayMovesNoAuditFigure() {
        let policies = testPolicies(rateCents: 1_000, workweekStartWeekday: 1)
        let monday = HistoryRender(entries: entries(), policies: policies, schedule: testSchedule(firstWeekday: 2))
        let sunday = HistoryRender(entries: entries(), policies: policies, schedule: testSchedule(firstWeekday: 1))

        #expect(monday.detail.expectation.grossCents == sunday.detail.expectation.grossCents)
        #expect(monday.detail.expectation.auditableTipsLineCents == sunday.detail.expectation.auditableTipsLineCents)
        #expect(monday.detail.expectation.wagesCents == sunday.detail.expectation.wagesCents)
        #expect(monday.detail.expectation.overtimeMinutes == sunday.detail.expectation.overtimeMinutes)
    }

    /// The gratuity half, and the silence rule on each side: a cash-only
    /// period reports no tips discrepancy, and a period with gratuity reports
    /// it as its own category.
    @Test("gratuity is its own category, and a cash-only period is not a discrepancy")
    func gratuityAndCashOnly() {
        let gratuity = HistoryRender(entries: [
            TipEntry(date: at(2026, 9, 28), amountCents: 12_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 2_000, shiftID: shiftID(1),
                     receiptMetrics: ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: 3_000))
        ])
        #expect(gratuity.detail.expectation.auditableTipsLineCents == 10_000)
        #expect(gratuity.detail.expectation.gratuityFeesCents == 3_000)

        let cashOnly = HistoryRender(entries: [
            TipEntry(date: at(2026, 9, 28), amountCents: 12_000, kind: .cash, hoursWorked: 8,
                     shiftID: shiftID(1))
        ])
        #expect(cashOnly.detail.expectation.auditableTipsLineCents == nil)
        #expect(cashOnly.detail.expectation.gratuityFeesCents == nil)
    }

    /// With no rate in effect the engine prices nothing, so there is no
    /// computed wage to audit a stub against and the wage check stays silent
    /// rather than telling the person their stub pays $X more than zero.
    @Test("no rate in effect means no wage basis, not a zero one")
    func noRateMeansNoWageBasis() {
        let render = HistoryRender(entries: h1Entries(), policies: testPolicies(rateCents: nil))
        #expect(render.detail.expectation.hasAuditableWages == false)
        #expect(render.detail.expectation.grossCents != nil)
    }
}

// MARK: - The grid weekday is not a workweek

/// The corollary wave 0 paid for, restated on the migrated screen: Payday has
/// two independent weekday controls, and only the payroll CALENDAR POLICY
/// owns overtime. Now that no money input on this screen comes from
/// `PaySchedule`, the pay-period grid cannot move a cent — and that is the
/// assertion, rather than "both halves happen to read the same scalar".
@Suite("History's money does not depend on the pay-period grid's weekday")
struct HistoryGridWeekdayCannotMoveMoneyTests {
    /// Five 10-hour days, Sunday 2026-09-27 through Thursday 2026-10-01, at
    /// $10.00/hr. Monday-start buckets them as 10h + 40h and produces no
    /// overtime ($500.00); Sunday-start makes them one 50h week and produces
    /// 10 hours of it ($550.00). A $50.00 gap, which is what makes a
    /// disagreement legible rather than a rounding cent.
    private func entries() -> [TipEntry] {
        [
            (2026, 9, 27, 1), (2026, 9, 28, 2), (2026, 9, 29, 3),
            (2026, 9, 30, 4), (2026, 10, 1, 5)
        ].map { year, month, day, index in
            TipEntry(date: at(year, month, day), amountCents: 1_000, kind: .credit,
                     hoursWorked: 10, shiftID: shiftID(index))
        }
    }

    @Test("the POLICY decides: Sunday-start bills the overtime the Monday grid would have hidden")
    func policyOwnsOvertime() throws {
        let sundayPolicy = testPolicies(rateCents: 1_000, workweekStartWeekday: 1)
        // The GRID says Monday; only the policy owns overtime.
        let render = HistoryRender(
            entries: entries(),
            policies: sundayPolicy,
            schedule: testSchedule(firstWeekday: 2)
        )
        let result = try #require(render.detail.result)
        #expect(result.knownComponents.wagesCents == 55_000)
        #expect(result.knownComponents.wagesCents != 50_000, "the superseded grid-weekday allocation")

        // The hero IS the sum of the rows, by construction: both are the same
        // valuations.
        let snapshot = try #require(render.snapshot)
        let rowWages = render.detail.shiftDays.compactMap {
            snapshot.valuation($0.shiftID)?.components.wagesCents
        }
        #expect(rowWages.count == 5)
        #expect(rowWages.reduce(0, +) == 55_000)
        #expect(render.detail.hero.cents == 5 * 1_000 + 55_000)
        #expect(try #require(render.row).earned.cents == render.detail.hero.cents)
    }

    @Test("flipping the grid's first weekday moves no figure on either surface")
    func gridWeekdayMovesNothing() throws {
        let policies = testPolicies(rateCents: 1_000, workweekStartWeekday: 1)
        let monday = HistoryRender(entries: entries(), policies: policies, schedule: testSchedule(firstWeekday: 2))
        let sunday = HistoryRender(entries: entries(), policies: policies, schedule: testSchedule(firstWeekday: 1))

        #expect(monday.detail.hero.cents == sunday.detail.hero.cents)
        #expect(monday.detail.hourlyRateCaption == sunday.detail.hourlyRateCaption)
        #expect(monday.detail.breakdownTotal.cents == sunday.detail.breakdownTotal.cents)
        #expect(monday.detail.expectedCheckCents == sunday.detail.expectedCheckCents)
        #expect(monday.list.yearToDate.cents == sunday.list.yearToDate.cents)
        #expect(monday.list.rows.compactMap(\.earned.cents) == sunday.list.rows.compactMap(\.earned.cents))
        // Same dataset behind both renders, so the comparison is honest.
        // `digest`, not the whole stamp: `computedAt` is a wall clock and
        // two builds a microsecond apart are never `==`.
        #expect(monday.detail.stamp?.digest == sunday.detail.stamp?.digest)
    }
}
