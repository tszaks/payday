import Testing
import Foundation
@testable import Payday

// ═══════════════════════════════════════════════════════════════════════════
//  PR 5 wave 1, group 2.1 (Dashboard). The parity and presentation gates for
//  `DashboardFacts` after it moved onto `EarningsSnapshot`.
//
//  Every number in here is MEASURED against the real adapter, never against a
//  helper that restates it — the plan's completion rule 2. `DashboardFacts` is
//  internal for exactly that reason.
// ═══════════════════════════════════════════════════════════════════════════

/// The grid calendar, in the payroll zone, Monday-start.
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

/// The user's real compensation history, as `PolicyStore` would hold it: one
/// rate, one workweek, both effective from the distant past.
///
/// Never a scalar rate handed to a bridge — that re-stamps as a
/// `.distantPast` `.confirmed` policy and reprices every pre-raise shift at
/// today's rate (MEASURED $520 against the correct $440, wave 0).
private func policies(rateCents: Int?, workweekStartWeekday: Int = 2) -> CompensationPolicies {
    let calendar = PayrollCalendarPolicy(
        id: PolicyMigration.deterministicID("dash/calendar/\(workweekStartWeekday)"),
        effectiveFrom: .distantPast,
        workweekStartWeekday: workweekStartWeekday,
        payrollTimeZone: PaydayTestZone.payroll
    )
    guard let rateCents else { return CompensationPolicies(rates: [], calendars: [calendar]) }
    return CompensationPolicies(
        rates: [PayRatePolicy(
            id: PolicyMigration.deterministicID("dash/rate/\(rateCents)"),
            effectiveFrom: .distantPast,
            hourlyRateCents: rateCents,
            provenance: .confirmed
        )],
        calendars: [calendar]
    )
}

/// The dataset, exactly as `DashboardView.body` builds it: ONE grouping in
/// the frozen payroll zone and the snapshot built from that same grouping.
///
/// The view used to call `LegacySnapshotBridge.snapshot(entries:)` — whose
/// `ShiftDays.groupedByShift` takes the DEFAULT `Calendar.current` — while
/// `DashboardFacts` grouped again in the payroll zone, and this helper made
/// the same call, so the test and the bug shared the mistake. Going through
/// `DashboardEarnings.build` is what makes that unspellable in either place.
private func dashboardDataset(
    entries: [TipEntry],
    policies: CompensationPolicies,
    payrollTimeZone: TimeZone = PaydayTestZone.payroll
) -> DashboardEarnings.Dataset {
    DashboardEarnings.build(
        entries: entries,
        policies: policies,
        payrollTimeZone: payrollTimeZone,
        calendar: PayrollCalendar.gridCalendar(in: payrollTimeZone)
    )
}

/// Exactly what `DashboardView.body` does: build the dataset over the whole
/// history, then hand its snapshot AND its grouping to the adapter. Not a
/// reimplementation of any figure — the two calls the view makes, in the
/// order it makes them.
private func dashboardFacts(
    entries: [TipEntry],
    schedule: PaySchedule?,
    now: Date,
    policies: CompensationPolicies,
    payrollTimeZone: TimeZone = PaydayTestZone.payroll,
    forcedPaydayPhase: PaydayMoment.Phase? = nil,
    snapshotOverride: EarningsSnapshot?? = nil
) -> DashboardFacts {
    let dataset = dashboardDataset(
        entries: entries, policies: policies, payrollTimeZone: payrollTimeZone
    )
    return DashboardFacts(
        snapshot: snapshotOverride ?? dataset.snapshot,
        allShifts: dataset.shiftDays,
        schedule: schedule,
        now: now,
        forcedPaydayPhase: forcedPaydayPhase,
        dismissedClosedEnd: nil,
        dismissedCheckEnd: nil,
        payrollTimeZone: payrollTimeZone
    )
}

/// Definition of Done #5, first clause: **Dashboard equals the History row
/// equals period detail.**
///
/// The three surfaces select the same pay period over the same shifts, so the
/// rule the whole goal is measured against says they must return the same
/// integer cents. Dashboard asks `snapshot.range(period, asOf:)`.
///
/// ## Why this suite asserts against the ENGINE and not against group 2.4
///
/// It used to call `PeriodsPageFacts` and `PeriodDetailFacts` directly and
/// record what they returned. Two things went wrong with that, both MEASURED
/// on the tree where group 2.4's migration and this one were merged together:
///
/// 1. **It did not compile.** Ten errors: the History worker deleted
///    `PeriodsPageFacts(allEntries:...wageCentsPerHour:...)`,
///    `PeriodDetailFacts(allEntries:...)`, `Row.breakdown`, `Row.wages` and
///    `PeriodDetailFacts.heroTotalCents`, which is every symbol this file
///    reached for. A gate that names another group's in-flight API is a gate
///    that breaks on somebody else's commit.
/// 2. **Two of its assertions asserted the bug.** They pinned History's
///    PRE-migration answers as expectations: a row of 50,000c where
///    Dashboard read 55,000c, and a 34,400c gap between the History list and
///    the detail it opens. Group 2.4 then fixed both, and the merged suite
///    failed here, in this file, pointing at their screen, because the
///    numbers this file called correct were the old wrong ones.
///
/// So the cross-surface assertion is made against the thing both surfaces
/// must equal: `snapshot.range(...)` off the SAME snapshot, with the same
/// stamp. Dashboard equals the engine, History equals the engine (pinned in
/// group 2.4's own `HistoryParityTests`), and the three-way equality follows
/// by construction rather than by two files agreeing about a literal.
///
/// **What is still owed, and where it goes:** the literal three-surface test
/// (`DashboardFacts.hero.cents == PeriodsPageFacts.row.earned.cents ==
/// PeriodDetailFacts.hero.cents`) belongs in the SHARED
/// `PaydayTests/EarningsParityTests.swift`, added once both groups have
/// merged, so neither worker's file depends on the other's API mid-flight.
/// It must use the CURRENT period, not a closed one: with a closed period
/// `now` is already past `period.end`, the to-date clamp is a no-op, and the
/// test cannot see a cutoff disagreement at all. That is exactly how the
/// Dashboard-vs-History `asOf` split (40400 against 79800) survived a suite
/// whose header claimed to prove this clause.
@Suite("Dashboard period income equals the History row and period detail")
struct DashboardPeriodParityTests {
    /// A closed biweekly period, Mon 2026-09-28 through Sun 2026-10-11, paid
    /// five days later. Five shifts inside it, all in one Monday-start
    /// workweek, none on the period's final day, 38 hours total — under the
    /// threshold, so no overtime for the three surfaces' three different
    /// workweek spellings to disagree about. Every other divergence this file
    /// measures is isolated in its own test.
    private func fixture() -> (entries: [TipEntry], schedule: PaySchedule, period: PayPeriod) {
        let entries: [TipEntry] = [
            TipEntry(date: at(2026, 9, 28), amountCents: 12_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 1_500, shiftPeriod: .dinner, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 9, 29), amountCents: 9_000, kind: .credit, hoursWorked: 7.5,
                     shiftPeriod: .dinner, shiftID: shiftID(2)),
            TipEntry(date: at(2026, 9, 30), amountCents: 7_500, kind: .cash, hoursWorked: 7,
                     shiftPeriod: .lunch, shiftID: shiftID(3)),
            TipEntry(date: at(2026, 10, 1), amountCents: 11_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 1_200, shiftPeriod: .dinner, shiftID: shiftID(4)),
            TipEntry(date: at(2026, 10, 2), amountCents: 10_500, kind: .credit, hoursWorked: 7.5,
                     shiftPeriod: .dinner, shiftID: shiftID(5))
        ]
        // The GRID weekday matches the POLICY's here on purpose. They are two
        // independent Settings controls and History's row still reads the
        // grid's; setting them apart is the subject of its own test below.
        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: at(2026, 10, 11, hour: 0),
            payDelayDays: 5,
            firstWeekday: 2
        )
        return (entries, schedule, PayPeriod(start: at(2026, 9, 28, hour: 0), end: at(2026, 10, 11, hour: 0)))
    }

    @Test("the same closed period reads the cents the engine returns for it")
    func threeSurfacesAgree() throws {
        let (entries, schedule, period) = fixture()
        // Two days after the close: the period is settled, so no surface is
        // applying a to-date cutoff and the only thing left to disagree about
        // is the arithmetic.
        let now = at(2026, 10, 13, hour: 12)
        let comp = policies(rateCents: 1_800)

        let dashboard = dashboardFacts(entries: entries, schedule: schedule, now: now, policies: comp)
        // The hero followed the closed period: the new one is empty.
        #expect(dashboard.heroPeriod == period)
        #expect(dashboard.heroLabel == "Last pay period")
        let dashboardCents = try #require(dashboard.hero.cents)

        // MEASURED: 50,000c of tips less 2,700c tipped out, plus 38h at
        // $18.00/hr = 68,400c of wages. 115,700c.
        #expect(dashboardCents == 115_700)

        // The figure is the engine's, at the pay-period scope, with nothing
        // added to it on the way to the screen. This is the cross-surface
        // assertion: every migrated surface reading this period reads THIS
        // query, so equality between them is a property of the dataset and
        // not of two files quoting the same literal.
        let dataset = dashboardDataset(entries: entries, policies: comp)
        let snapshot = try #require(dataset.snapshot)
        let periodRange = DayRange(
            start: CivilDay(period.start, in: PaydayTestZone.payroll),
            end: CivilDay(period.end, in: PaydayTestZone.payroll)
        )
        #expect(dashboardCents == snapshot.range(periodRange).knownComponents.earnedIncomeCents)
        // Same dataset, same identity: a disagreement with another screen
        // over these shifts is diffable rather than a mystery, which is the
        // property contract rule 3 buys.
        #expect(dashboard.stamp?.digest == snapshot.stamp.digest)

        // The superseded History spelling, computed here rather than read off
        // group 2.4's adapter, so this stays a regression guard and not a pin
        // on someone else's in-flight API. It happens to agree on a settled
        // period with no overtime and no future-dated shift, which is exactly
        // why a closed-period test could never see the two defects the other
        // tests in this file isolate.
        let legacyWages = try #require(PeriodIncome.wages(
            payrollTimeZone: PaydayTestZone.payroll,
            entries: entries,
            wageCentsPerHour: 1_800,
            firstWeekday: 2,
            calendar: payrollCalendar()
        ))
        #expect(TipBreakdown.total(of: entries).netTotalCents + legacyWages.totalCents == 115_700)
    }

    @Test("the drawer's rows reconcile to the bottom line it prints them under")
    func drawerRowsReconcile() throws {
        let (entries, schedule, _) = fixture()
        let now = at(2026, 10, 13, hour: 12)
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: now, policies: policies(rateCents: 1_800)
        )

        let labels = facts.heroBreakdownRows.map(\.label)
        #expect(labels == ["Cash tips", "Credit tips", "Wages", "Earned", "Tipped out"])
        #expect(facts.heroBreakdownRows.first { $0.label == "Wages" }?.caption == "38h")

        func cents(_ label: String) throws -> Int {
            try #require(facts.heroBreakdownRows.first { $0.label == label }?.cents)
        }
        #expect(try cents("Cash tips") == 7_500)
        #expect(try cents("Credit tips") == 42_500)
        #expect(try cents("Wages") == 68_400)
        // The subtotal is `EarningsComponents.grossBeforeTipOutCents`, not
        // four terms this screen adds up.
        #expect(try cents("Earned") == 118_400)
        #expect(try cents("Tipped out") == -2_700)
        // Earned - tipped out == the bottom line, which is the hero.
        #expect(try cents("Earned") + cents("Tipped out") == facts.heroBreakdownTotal.cents)
        #expect(facts.heroBreakdownTotal.cents == facts.hero.cents)
        // A tip-out was logged, so the bottom line is "You kept" and never
        // "Total" — and the words come from `CompletenessCopy`.
        #expect(facts.heroBreakdownTotal.label == "You kept")
    }

    /// The pay-period grid's weekday and the payroll workweek's are two
    /// independent Settings controls that never write each other (PR 3 severed
    /// them). Dashboard reads the POLICY — through the snapshot, which is the
    /// only thing it reads money from — so setting the grid against it cannot
    /// move a Dashboard figure.
    @Test("MEASURED: the grid weekday cannot move a Dashboard figure; History's row still follows it")
    func gridWeekdayDoesNotMoveTheHero() throws {
        // Five 10-hour days, Sun 2026-09-27 through Thu 2026-10-01, at
        // $10.00/hr. Sunday-start: one 50h week, so 10h pay 1.5x -> $550.00.
        // Monday-start: 10h in one week and 40h in the next -> $500.00.
        let entries = [(2026, 9, 27, 1), (2026, 9, 28, 2), (2026, 9, 29, 3),
                       (2026, 9, 30, 4), (2026, 10, 1, 5)].map { year, month, day, index in
            TipEntry(date: at(year, month, day), amountCents: 0, kind: .credit,
                     hoursWorked: 10, shiftID: shiftID(index))
        }
        let period = PayPeriod(start: at(2026, 9, 27, hour: 0), end: at(2026, 10, 10, hour: 0))
        let now = at(2026, 10, 12, hour: 12)
        // POLICY says Sunday. GRID says Monday. Only the policy owns overtime.
        let comp = policies(rateCents: 1_000, workweekStartWeekday: 1)
        let schedule = PaySchedule(
            frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 10, hour: 0),
            payDelayDays: 5, firstWeekday: 2
        )

        let facts = dashboardFacts(entries: entries, schedule: schedule, now: now, policies: comp)
        #expect(facts.heroPeriod == period)
        #expect(facts.hero.cents == 55_000)
        #expect(facts.hero.cents != 50_000, "the superseded grid-weekday allocation")

        // Every shift row is a slice of the same allocation, so the hero
        // period's rows sum to the hero to the cent. (`facts.shiftDays` is
        // the CURRENT period's list, which is empty here — the hero is
        // leading with the closed period and the Shifts section below it
        // shows "No shifts this period." for the new one.)
        let snapshot = try #require(facts.snapshot)
        #expect(facts.shiftDays.isEmpty)
        let rowTotal = (1...5).reduce(0) {
            $0 + (snapshot.valuation(shiftID($1))?.components.earnedIncomeCents ?? 0)
        }
        #expect(rowTotal == 55_000)
        #expect(rowTotal == facts.hero.cents)

        // The superseded spelling itself: `PeriodIncome.wages` handed the
        // pay-period GRID's weekday, which is what every pre-migration
        // surface passed it. It allocates 10h into one Monday-start week and
        // 40h into the next and returns $500.00 over the same five shifts.
        //
        // Asserted here as the number the engine does NOT return, not as any
        // screen's output: a test that pins another group's current answer
        // pins whatever bug that answer still has, and group 2.4's row
        // reads 55,000c through the policy since its migration.
        let gridAllocation = try #require(PeriodIncome.wages(
            payrollTimeZone: PaydayTestZone.payroll,
            entries: entries,
            wageCentsPerHour: 1_000,
            firstWeekday: 2,
            calendar: payrollCalendar()
        ))
        #expect(gridAllocation.totalCents == 50_000, "the grid weekday's allocation")
        #expect(gridAllocation.totalCents != facts.hero.cents)
        // And the policy's own allocation, which is what the hero read.
        let policyAllocation = try #require(PeriodIncome.wages(
            payrollTimeZone: PaydayTestZone.payroll,
            entries: entries,
            wageCentsPerHour: 1_000,
            firstWeekday: 1,
            calendar: payrollCalendar()
        ))
        #expect(policyAllocation.totalCents == 55_000)
        #expect(policyAllocation.totalCents == facts.hero.cents)
    }
}

/// `PayPeriodCalculator.period(containing:)` returns `end` as the START of the
/// period's last day. Dashboard used to select its shifts with
/// `allEntries.filter { $0.date >= period.start && $0.date <= period.end }`,
/// so every shift logged at a real hour on that last day fell outside the
/// filter — while `StatsEngine.periodToDateTotal`, which compares civil days,
/// counted it. The Shifts list and the shift count lost a shift the hero's
/// money did not.
///
/// Both halves now select through `DayRange`, the engine's own membership
/// rule, and the whole last day is inside it.
@Suite("A shift on the final day of the pay period")
struct DashboardFinalDayMembershipTests {
    private func fixture() -> (entries: [TipEntry], schedule: PaySchedule, period: PayPeriod) {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 10_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(1)),
            // 5pm on the period's last day.
            TipEntry(date: at(2026, 10, 11), amountCents: 20_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let schedule = PaySchedule(
            frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0),
            payDelayDays: 5, firstWeekday: 2
        )
        return (entries, schedule, PayPeriod(start: at(2026, 9, 28, hour: 0), end: at(2026, 10, 11, hour: 0)))
    }

    @Test("the final day's shift is in the list, in the count, and in the hero")
    func finalDayShiftIsCounted() throws {
        let (entries, schedule, period) = fixture()
        // 8pm on the period's last day: the period is still the current one,
        // so the Shifts list under the hero is this period's list.
        let now = at(2026, 10, 11, hour: 20)
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: now, policies: policies(rateCents: 1_800)
        )

        #expect(facts.heroPeriod == period)
        #expect(facts.shiftCount == 2)
        #expect(facts.shiftDays.map(\.shiftID).contains(shiftID(2)))
        // 30,000c of tips plus 16h at $18.00/hr.
        #expect(facts.hero.cents == 30_000 + 28_800)

        // The superseded selection, spelled out so the regression is legible:
        // the old entry-date filter dropped the 2026-10-11 shift entirely.
        let oldSelection = entries.filter { $0.date >= period.start && $0.date <= period.end }
        #expect(oldSelection.count == 1)
        #expect(oldSelection.map(\.shiftID) == [shiftID(1)])
    }

    /// The same shift, through the ENGINE.
    ///
    /// This test used to call `PeriodsPageFacts` and `PeriodDetailFacts` and
    /// assert the 34,400c gap BETWEEN them, on the reasoning that Dashboard's
    /// migration is what made the divergence visible. That was the wrong
    /// place for it twice over: the assertion pinned another group's bug as
    /// an expectation, and group 2.4's migration then closed the gap to zero
    /// and failed this file. Its own `HistoryParityTests` owns the History
    /// side now.
    ///
    /// What belongs here is the membership rule Dashboard adopted, measured
    /// against the selection it replaced. The engine's civil-day range keeps
    /// the final day's shift; the superseded `period.start...period.end`
    /// entry-date filter drops it, because `end` is the START of the last
    /// day.
    @Test("MEASURED: the engine's range keeps the final day's shift the entry-date filter dropped")
    func theFinalDayIsInTheEnginesRange() throws {
        let (entries, schedule, period) = fixture()
        let comp = policies(rateCents: 1_800)
        _ = schedule

        let dataset = dashboardDataset(entries: entries, policies: comp)
        let snapshot = try #require(dataset.snapshot)
        let periodRange = DayRange(
            start: CivilDay(period.start, in: PaydayTestZone.payroll),
            end: CivilDay(period.end, in: PaydayTestZone.payroll)
        )
        let whole = snapshot.range(periodRange)
        // Both shifts: 30,000c of tips and 16h at $18.00/hr.
        #expect(whole.shiftIDs.count == 2)
        #expect(whole.knownComponents.earnedIncomeCents == 58_800)

        // The superseded selection, spelled out. It keeps one shift and
        // 24,400c, which is the figure every surface on the entry-date filter
        // printed for this period.
        let oldFilter = entries.filter { $0.date >= period.start && $0.date <= period.end }
        #expect(oldFilter.count == 1)
        let oldShifts = ShiftDays.groupedByShift(
            oldFilter, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod,
            calendar: payrollCalendar()
        )
        let oldCents = oldShifts.reduce(0) {
            $0 + (snapshot.valuation($1.shiftID)?.components.earnedIncomeCents ?? 0)
        }
        #expect(oldCents == 24_400)
        #expect(oldCents != whole.knownComponents.earnedIncomeCents)
        #expect(whole.knownComponents.earnedIncomeCents - oldCents == 34_400)
    }
}

/// The drawer's tip-out is READ from the ledger now, not reconstructed as
/// `max(0, cash + credit + gratuity - net)`.
///
/// The back-derivation only equalled the real tip-out while the gross and the
/// net came from the same selection, and they did not: the gross was
/// `TipBreakdown.total` over the WHOLE period and the net was
/// `StatsEngine.periodToDateTotal` clamped to today (`docs/METRICS.md`
/// [DB-21]). A future-dated shift inside the current period therefore sat in
/// the gross and not in the net, and its whole net earnings showed up as
/// "Tipped out".
@Suite("The hero's tip-out is the ledger's, not a residual")
struct DashboardTipOutIsReadTests {
    @Test("MEASURED: a future-dated shift in the period made the old residual invent $250.00 of tip-out")
    func futureShiftDoesNotInventTipOut() throws {
        let now = at(2026, 10, 7, hour: 12)
        let entries = [
            TipEntry(date: at(2026, 10, 5), amountCents: 30_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 4_000, shiftPeriod: .dinner, shiftID: shiftID(1)),
            // Two days out, still inside the current period — a shift someone
            // logged ahead, which fixture S2 is the engine's version of.
            TipEntry(date: at(2026, 10, 9), amountCents: 25_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let schedule = PaySchedule(
            frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0),
            payDelayDays: 5, firstWeekday: 2
        )
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: now, policies: policies(rateCents: nil)
        )

        // The hero is clamped to today, so it holds the 10-05 shift only.
        #expect(facts.hero.cents == 30_000 - 4_000)
        let tippedOut = try #require(
            facts.heroBreakdownRows.first { $0.label == "Tipped out" }?.cents
        )
        #expect(tippedOut == -4_000, "the ledger's own tipOutCents for the clamped selection")

        // The superseded residual, computed the way the screen used to: gross
        // over the whole period (both shifts) minus the clamped net (one).
        let wholePeriodGross = 30_000 + 25_000
        let clampedNet = 30_000 - 4_000
        #expect(max(0, wholePeriodGross - clampedNet) == 29_000)
        #expect(tippedOut != -29_000, "the phantom tip-out the residual produced")
        // And the drawer still adds up, which the old pair could not:
        // $290.00 of "Tipped out" under a $260.00 bottom line.
        let earned = try #require(facts.heroBreakdownRows.first { $0.label == "Earned" }?.cents)
        #expect(earned == 30_000)
        #expect(earned + tippedOut == facts.heroBreakdownTotal.cents)
    }
}

/// Adapter contract rule 4, on this screen: `.partial` never renders "Total",
/// and a failed read renders no currency at all.
@Suite("Dashboard completeness presentation")
struct DashboardCompletenessTests {
    private let schedule = PaySchedule(
        frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0),
        payDelayDays: 5, firstWeekday: 2
    )

    @Test("a period with one unpriced shift reads 'Known so far' and names what is missing")
    func partialNeverSaysTotal() {
        let now = at(2026, 10, 7, hour: 12)
        let entries = [
            TipEntry(date: at(2026, 10, 5), amountCents: 10_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(1)),
            // Hours never logged, so the ledger cannot price it.
            TipEntry(date: at(2026, 10, 6), amountCents: 12_000, kind: .credit,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: now, policies: policies(rateCents: 1_800)
        )

        #expect(facts.hero.completeness.state == .partial(missingHours: 1, missingRate: 0))
        #expect(facts.hero.label == "Known so far")
        #expect(facts.hero.mayBeCalledATotal == false)
        #expect(facts.hero.caption == "wages missing for 1 shift")
        #expect(facts.heroBreakdownTotal.label == "Known so far")
        #expect(facts.heroBreakdownTotal.label != "Total")
        // 22,000c of tips plus the 8h it could price.
        #expect(facts.hero.cents == 22_000 + 14_400)
    }

    @Test("an assumed legacy rate reaches the hero as a caption, not as a bare number")
    func estimatedCarriesItsCaption() {
        let now = at(2026, 10, 7, hour: 12)
        let entries = [
            TipEntry(date: at(2026, 10, 5), amountCents: 10_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let assumed = CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("dash/rate/assumed"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 1_800,
                provenance: .assumedFromLegacySetting
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("dash/calendar/2"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: PaydayTestZone.payroll
            )]
        )
        let facts = dashboardFacts(entries: entries, schedule: schedule, now: now, policies: assumed)

        #expect(facts.hero.completeness.state == .estimated)
        #expect(facts.hero.caption == "Wages estimated from your current rate")
        #expect(facts.hero.cents == 10_000 + 14_400)
    }

    @Test("no snapshot renders no currency anywhere, and never relabels the hero")
    func unavailableRendersNoCurrency() {
        let now = at(2026, 10, 7, hour: 12)
        let entries = [
            TipEntry(date: at(2026, 10, 5), amountCents: 10_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        // `LegacySnapshotBridge` returns nil when the inputs cannot be
        // canonically fingerprinted. `.some(nil)` is that refusal.
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: now,
            policies: policies(rateCents: 1_800), snapshotOverride: .some(nil)
        )

        #expect(facts.isUnbacked)
        #expect(facts.stamp == nil)
        #expect(facts.hero.isUnavailable)
        #expect(facts.hero.text == nil)
        #expect(facts.hero.cents == nil)
        #expect(facts.predictedPaycheck.text == nil)
        #expect(facts.paydayCash.text == nil)
        #expect(facts.heroBreakdownTotal.cents == nil)
        #expect(BreakdownRow.amountText(facts.heroBreakdownTotal.cents) == ShiftDayRow.unavailablePlaceholder)
        #expect(facts.heroHasBreakdown == false)
        // The hero stays on the period the person is in: a nil read is not
        // evidence that this period is empty.
        #expect(facts.heroIsCurrent)
        #expect(facts.heroLabel == "This pay period")
    }

    /// Design 2 says `.noShifts` "renders no currency figure"; `CompletenessCopy`
    /// deferred the decision to the hero that owns it, which is this group.
    ///
    /// The decision: an empty pay period keeps `$0.00`. It is not a
    /// placeholder standing in for an unknown — a period with no shifts
    /// genuinely earned nothing, and the screen already says "No shifts this
    /// period." directly underneath. Replacing a true zero with an en dash
    /// would make the one honest number on the screen look like a failed read.
    @Test("an empty pay period keeps $0.00 under 'Total', and says why underneath")
    func noShiftsKeepsItsZero() {
        let now = at(2026, 10, 7, hour: 12)
        let facts = dashboardFacts(
            entries: [], schedule: schedule, now: now, policies: policies(rateCents: 1_800)
        )
        #expect(facts.hero.completeness.state == .noShifts)
        #expect(facts.hero.cents == 0)
        #expect(facts.hero.text == "$0.00")
        #expect(facts.hero.label == "Total")
        #expect(facts.hero.caption == nil)
        #expect(facts.periodEntries.isEmpty)
        #expect(!facts.hasShiftsThisPeriod, "which is what draws 'No shifts this period.'")
        #expect(facts.heroDeferredShiftCount == 0, "nothing is being left out; the period is empty")
    }

    /// Tyler's phone, the first time an account flipped: a correct, non-zero
    /// hero with "No shifts this period." underneath it.
    ///
    /// `DashboardEarnings.build`'s record arm returns `shiftDays: []` by
    /// construction -- the Dataset carries exactly one representation and
    /// never merges them -- so `periodEntries`, which is
    /// `periodShifts.flatMap(\.items)` over the LEGACY arm, is empty for
    /// every flipped account no matter how many shifts it has. The screen
    /// branched on exactly that.
    ///
    /// Everything else here was already right, which is what made it
    /// invisible: `shiftsSection` renders both arms and `shiftCount` sums
    /// both. Only the gate asked one.
    ///
    /// The legacy half of this coupling was asserted above and the record
    /// half was not, so the suite stayed green through it. This is that half.
    @Test("a flipped account with shifts does not draw the empty state")
    func recordArmPeriodIsNotEmpty() {
        let now = at(2026, 10, 7, hour: 12)
        let record = ShiftRecord(
            workDate: at(2026, 10, 5, hour: 12),
            shiftPeriod: .dinner,
            creditTipsCents: 12_000,
            hoursWorked: 5
        )
        let facts = DashboardFacts(
            snapshot: nil,
            allShifts: [],
            allShiftRecords: [record],
            schedule: schedule,
            now: now,
            forcedPaydayPhase: nil,
            dismissedClosedEnd: nil,
            dismissedCheckEnd: nil,
            payrollTimeZone: PaydayTestZone.payroll
        )
        // The legacy arm IS empty on a flipped account. That is correct and
        // is precisely why it must not be the thing the screen branches on.
        #expect(facts.periodEntries.isEmpty)
        #expect(facts.shiftRecordDays.count == 1)
        #expect(facts.shiftCount == 1)
        #expect(facts.hasShiftsThisPeriod, "the Shifts section must draw, not the empty state")
    }

    /// The defect the deferral above did not cover, and the reason
    /// `heroDeferredShiftCount` exists.
    ///
    /// A pay period whose ONLY shift is dated ahead of today is not an empty
    /// period, so "No shifts this period." is not drawn: the Shifts section
    /// renders, with that shift's own row in it, because
    /// `snapshot.valuation(_:)` is deliberately unclamped. The hero's query
    /// IS clamped, so it selected nothing.
    ///
    /// MEASURED before the fix, on exactly this fixture: heroText "$0.00",
    /// label "Total", caption nil, state `.noShifts`, with the single row
    /// under it reading $394.00 and no empty-state sentence anywhere on
    /// screen. It was also a regression, not just an inherited gap: the
    /// superseded hero (clamped tips plus WHOLE-period wages) printed
    /// 14,400c for the same input.
    ///
    /// The cents are unchanged, because $0.00 earned so far is true. What the
    /// hero may not do is call that figure a "Total" while a shift it
    /// excluded is drawn directly underneath it.
    @Test("a period whose only shift is dated ahead says so instead of calling $0.00 a Total")
    func futureOnlyPeriodDeclaresWhatItLeftOut() throws {
        let now = at(2026, 10, 7, hour: 12)
        let entries = [
            TipEntry(date: at(2026, 10, 9), amountCents: 25_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: now, policies: policies(rateCents: 1_800)
        )

        // The period is NOT empty, so the explanatory sentence the $0.00
        // deferral leans on is not on screen.
        #expect(facts.heroIsCurrent)
        #expect(facts.heroLabel == "This pay period")
        #expect(facts.shiftCount == 1)
        #expect(facts.periodEntries.isEmpty == false, "so emptyState(_:) does not render")

        // The hero still reports the clamped truth.
        #expect(facts.hero.cents == 0)
        #expect(facts.hero.text == "$0.00")
        // And it no longer claims to be the whole story.
        #expect(facts.heroDeferredShiftCount == 1)
        #expect(facts.hero.label == "Known so far")
        #expect(facts.hero.mayBeCalledATotal == false)
        #expect(facts.hero.caption == "1 shift dated later this period")
        #expect(facts.heroBreakdownTotal.label == "Known so far")

        // The row's own figure, which is what made the bare $0.00 a
        // contradiction: $250.00 of tips and 8h at $18.00/hr.
        let row = ShiftDayRowFacts(
            snapshot: facts.snapshot,
            shiftID: shiftID(1),
            day: at(2026, 10, 9, hour: 0),
            period: .dinner,
            dayHasMultipleShifts: false
        )
        #expect(row.amount.cents == 25_000 + 14_400)
        #expect(row.amount.text == "$394.00")
        #expect(row.amount.cents != facts.hero.cents)

        // The superseded hero, spelled out: clamped tips (0) plus
        // WHOLE-period wages (14,400c). A wrong non-zero number, which is
        // what makes the $0.00 a regression rather than a new honesty.
        let supersededWages = try #require(PeriodIncome.wages(
            payrollTimeZone: PaydayTestZone.payroll,
            entries: entries,
            wageCentsPerHour: 1_800,
            firstWeekday: 2,
            calendar: payrollCalendar()
        ))
        #expect(supersededWages.totalCents == 14_400)
        #expect(supersededWages.totalCents != facts.hero.cents)
    }

    /// The same rule mid-period, where the hero is NOT zero: a clamped hero
    /// over a period that also holds a future-dated shift is still not the
    /// whole period, and it says so rather than printing "You kept" over a
    /// list whose rows sum to more.
    @Test("a mid-period hero with a shift dated ahead names it too")
    func partiallyClampedPeriodDeclaresWhatItLeftOut() throws {
        let now = at(2026, 10, 7, hour: 12)
        let entries = [
            TipEntry(date: at(2026, 10, 5), amountCents: 30_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 4_000, shiftPeriod: .dinner, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 10, 9), amountCents: 25_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: now, policies: policies(rateCents: 1_800)
        )

        // 30,000c less 4,000c tipped out, plus 8h at $18.00/hr.
        #expect(facts.hero.cents == 30_000 - 4_000 + 14_400)
        #expect(facts.heroDeferredShiftCount == 1)
        #expect(facts.hero.label == "Known so far")
        #expect(facts.hero.label != "You kept", "the label a tip-out would otherwise earn")
        #expect(facts.hero.caption == "1 shift dated later this period")

        // The rows under it sum past the hero, which is the fact the caption
        // exists to explain.
        let snapshot = try #require(facts.snapshot)
        let rowTotal = facts.shiftDays.reduce(0) {
            $0 + (snapshot.valuation($1.shiftID)?.components.earnedIncomeCents ?? 0)
        }
        #expect(rowTotal == 30_000 - 4_000 + 14_400 + 25_000 + 14_400)
        #expect(rowTotal > (facts.hero.cents ?? 0))
    }

    /// A completeness caption and a deferral caption are both true at once,
    /// so both are said.
    @Test("a partial period with a shift dated ahead keeps both captions")
    func bothCaptionsSurvive() {
        let now = at(2026, 10, 7, hour: 12)
        let entries = [
            // Hours never logged, so the ledger cannot price it: `.partial`.
            TipEntry(date: at(2026, 10, 5), amountCents: 10_000, kind: .credit,
                     shiftPeriod: .dinner, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 10, 9), amountCents: 25_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: now, policies: policies(rateCents: 1_800)
        )
        #expect(facts.hero.completeness.state == .partial(missingHours: 1, missingRate: 0))
        #expect(facts.heroDeferredShiftCount == 1)
        #expect(facts.hero.caption == "wages missing for 1 shift · 1 shift dated later this period")
        #expect(facts.hero.label == "Known so far")
    }
}

/// The payday card's check figure and the hero above it now come out of one
/// query for one period, so the "$X kept, $Y check, difference is the cash"
/// identity holds by construction.
@Suite("Dashboard payday card")
struct DashboardPaydayCardTests {
    private let schedule = PaySchedule(
        frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0),
        payDelayDays: 5, firstWeekday: 2
    )

    @Test("the check is the tips line plus gratuity plus wages, and the gap from the hero is exactly the cash")
    func checkReconcilesAgainstTheHero() throws {
        let entries = [
            TipEntry(date: at(2026, 10, 5), amountCents: 20_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 3_000, shiftPeriod: .dinner, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 10, 5, hour: 18), amountCents: 6_000, kind: .cash,
                     shiftPeriod: .dinner, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 10, 6), amountCents: 15_000, kind: .credit, hoursWorked: 7,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        // Pinned to the current period by the screenshot hook, which is the
        // one path that shows the card over a period still in progress.
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: at(2026, 10, 7, hour: 12),
            policies: policies(rateCents: 1_800), forcedPaydayPhase: .periodClosed
        )

        #expect(facts.isPaydayMoment)
        // Tips line: credit 35,000 less 3,000 tipped out. Wages: 15h at $18.
        #expect(facts.predictedPaycheck.cents == 32_000 + 27_000)
        #expect(facts.predictedPaycheck.label == "Expected")
        #expect(facts.predictedPaycheck.metric == .expectedPaycheckGross)
        #expect(facts.paydayCash.cents == 6_000)
        // The identity the card's caption promises: kept - check == cash.
        let kept = try #require(facts.hero.cents)
        let check = try #require(facts.predictedPaycheck.cents)
        #expect(kept - check == 6_000)
        #expect(kept - check == facts.paydayCash.cents)
    }

    /// Fixture Z1: a period worked for wages that was tipped nothing. The old
    /// gate was `StatsEngine.periodToDateTotal > 0`, tips-only, so it
    /// suppressed the "Your check should show" card even though the check was
    /// real money ([DB-03]).
    @Test("Z1: a wage-only period still gets its payday card")
    func wageOnlyPeriodGetsItsCard() {
        let entries = [
            TipEntry(date: at(2026, 10, 5), amountCents: 0, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let now = at(2026, 10, 7, hour: 12)
        let comp = policies(rateCents: 1_800)

        // The superseded gate: tips-net through the period is zero.
        let statsEngine = StatsEngine(
            payrollTimeZone: PaydayTestZone.payroll,
            records: entries.map(TipRecord.init),
            calendar: payrollCalendar()
        )
        let period = PayPeriodCalculator(
            payrollTimeZone: PaydayTestZone.payroll, schedule: schedule, calendar: payrollCalendar()
        ).period(containing: now)
        #expect(statsEngine.periodToDateTotal(period: period, asOf: now) == 0)

        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: now,
            policies: comp, forcedPaydayPhase: .periodClosed
        )
        #expect(facts.isPaydayMoment, "the gate is earnedIncome now, and 8h at $18.00 is earnings")
        #expect(facts.predictedPaycheck.cents == 14_400)
        #expect(facts.hero.cents == 14_400)
    }

    @Test("no payday moment means no check figure at all, never a $0.00 one")
    func noMomentRendersNoCheck() {
        let entries = [
            TipEntry(date: at(2026, 10, 5), amountCents: 10_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(1))
        ]
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: at(2026, 10, 7, hour: 12),
            policies: policies(rateCents: 1_800)
        )
        #expect(facts.isPaydayMoment == false)
        #expect(facts.predictedPaycheck.isUnavailable)
        #expect(facts.predictedPaycheck.text == nil)
        #expect(facts.paydayCash.text == nil)
    }
}

/// The snapshot spans the WHOLE history, not the current period's slice.
///
/// The ledger allocates the overtime threshold across the complete workweek
/// of the shifts it is handed, so a snapshot built over fourteen days cannot
/// price the forty-first hour of a week that began before day one. Wave 0
/// named this gap on row [SC-01] and left it open; this closes it.
@Suite("A workweek straddling the pay-period edge keeps its overtime")
struct DashboardStraddlingWorkweekTests {
    @Test("MEASURED: the period-scoped snapshot lost $50.00 of overtime the whole-history one keeps")
    func straddlingWeekCarriesItsOvertime() throws {
        // Mon 2026-10-05 through Fri 2026-10-09, ten hours a day at $10.00/hr:
        // one Monday-start workweek of 50 hours, 40 regular and 10 at 1.5x.
        // The pay period starts on Thursday 10-08, so 30 of those hours were
        // worked in the period before it and the threshold is crossed on the
        // Thursday — which means the two in-period shifts carry ten of the
        // week's regular hours and the whole overtime tail.
        let entries = (0..<5).map { index in
            TipEntry(date: at(2026, 10, 5 + index), amountCents: 0, kind: .credit,
                     hoursWorked: 10, shiftID: shiftID(index + 1))
        }
        let schedule = PaySchedule(
            frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 21, hour: 0),
            payDelayDays: 5, firstWeekday: 5
        )
        let now = at(2026, 10, 12, hour: 12)
        let comp = policies(rateCents: 1_000, workweekStartWeekday: 2)

        let facts = dashboardFacts(entries: entries, schedule: schedule, now: now, policies: comp)
        // The period holds Thu 10-08 and Fri 10-09.
        #expect(facts.shiftCount == 2)

        let snapshot = try #require(facts.snapshot)
        let inPeriod = facts.shiftDays.compactMap { snapshot.valuation($0.shiftID) }
        // Thursday's ten hours are the week's last regular ones; Friday's ten
        // are all overtime, 10h x $10.00 x 1.5.
        #expect(inPeriod.reduce(0) { $0 + $1.components.regularWagesCents } == 10_000)
        #expect(inPeriod.reduce(0) { $0 + $1.components.overtimeWagesCents } == 15_000)
        #expect(facts.hero.cents == 10_000 + 15_000)
        // And the rows sum to the hero, overtime and all.
        #expect(inPeriod.reduce(0) { $0 + $1.components.earnedIncomeCents } == facts.hero.cents)

        // Wave 0's spelling, for the number it lost: the same bridge over the
        // PERIOD's shifts only sees 30 hours and prices every one at 1x.
        let periodShifts = ShiftDays.groupedByShift(
            entries.filter { $0.date >= at(2026, 10, 8, hour: 0) },
            shiftID: \.shiftID, date: \.date, period: \.shiftPeriod,
            calendar: payrollCalendar()
        )
        let periodScoped = try #require(LegacySnapshotBridge.snapshot(
            shifts: periodShifts, policies: comp,
            payrollTimeZone: PaydayTestZone.payroll, asOf: now
        ))
        let scopedTotal = periodShifts.reduce(0) {
            $0 + (periodScoped.valuation($1.shiftID)?.components.earnedIncomeCents ?? 0)
        }
        #expect(scopedTotal == 20_000, "twenty hours priced at 1x, the forty-first hour of the week unseen")
        #expect(try #require(facts.hero.cents) - scopedTotal == 5_000)
    }
}

/// "The echo and the row must reconcile on sight" (Tyler, 2026-07-27) is only
/// true if both come out of one allocation.
///
/// The echo's headline was `TipBreakdown.netTotalCents + wagesByShiftID[id]`
/// while `StatsEngine`'s record/average/slowest comparisons priced every prior
/// shift with `WageEstimate.cents(wageCentsPerHour:hours:)` — an independent
/// per-shift rounding that knows nothing about the workweek. So the figure
/// shown and the figures it was compared against were two derivations
/// ([DB-25]: "inputs should be earnedIncome per shift").
@Suite("Tonight's echo is the same number the shift's own row prints")
struct DashboardTonightEchoTests {
    @Test("the echo's cents equal the row's valuation, and the naive per-shift rounding differs")
    func echoEqualsTheRow() throws {
        let today = Date.now
        let calendar = payrollCalendar()
        let todayNoon = calendar.startOfDay(for: today).addingTimeInterval(12 * 3600)
        // W1's pair, on today so the echo fires: 4.25h then 5.5h at $2.83/hr.
        // The ledger allocates 1203 and 1556 (summing to the week's 2759);
        // independent rounding gives 1203 and 1557.
        let entries = [
            TipEntry(date: todayNoon, amountCents: 5_000, kind: .credit, recordedAt: todayNoon,
                     hoursWorked: 4.25, shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: todayNoon.addingTimeInterval(3_600), amountCents: 6_000, kind: .credit,
                     recordedAt: todayNoon.addingTimeInterval(3_600), hoursWorked: 5.5,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: today))!,
            firstWeekday: 2
        )
        let facts = dashboardFacts(
            entries: entries, schedule: schedule, now: todayNoon.addingTimeInterval(7_200),
            policies: policies(rateCents: 283)
        )

        let snapshot = try #require(facts.snapshot)
        // The dinner shift is the most recently logged, so it is the echo's.
        let dinner = try #require(snapshot.valuation(shiftID(2)))
        #expect(dinner.components.wagesCents == 1_556)
        #expect(WageEstimate.cents(wageCentsPerHour: 283, hours: 5.5) == 1_557)
        #expect(dinner.components.wagesCents != 1_557, "the superseded per-shift rounding")

        // The row and the echo print the same string, so they reconcile on
        // sight rather than by a cent of luck.
        let rowFacts = ShiftDayRowFacts(
            snapshot: snapshot, shiftID: shiftID(2), day: calendar.startOfDay(for: todayNoon),
            period: .dinner, dayHasMultipleShifts: true
        )
        let rowText = try #require(rowFacts.amount.text)
        let line = try #require(facts.tonightLine)
        #expect(rowText == "$75.56")
        #expect(line.hasPrefix("$75.56 this shift."))
    }

    /// The comparison half of the line, which is what `valuedShiftCents`
    /// exists for: the record it claims to beat is priced by the ledger too.
    @Test("the previous record the echo names is the ledger's figure, not WageEstimate's")
    func comparisonUsesTheLedgersFigures() throws {
        let calendar = payrollCalendar()
        let today = calendar.startOfDay(for: Date.now)
        let todayNoon = today.addingTimeInterval(12 * 3600)
        // A prior shift a week back, alone in its own workweek: 5.5h at
        // $2.83/hr is 1557c on its own, and the ledger agrees at that scope.
        // Today's lunch/dinner pair splits a shared week, which is where the
        // two derivations come apart.
        let priorDay = calendar.date(byAdding: .day, value: -14, to: today)!.addingTimeInterval(12 * 3600)
        let entries = [
            TipEntry(date: priorDay, amountCents: 7_400, kind: .credit, recordedAt: priorDay,
                     hoursWorked: 5.5, shiftPeriod: .dinner, shiftID: shiftID(9)),
            TipEntry(date: todayNoon, amountCents: 5_000, kind: .credit, recordedAt: todayNoon,
                     hoursWorked: 4.25, shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: todayNoon.addingTimeInterval(3_600), amountCents: 7_400, kind: .credit,
                     recordedAt: todayNoon.addingTimeInterval(3_600), hoursWorked: 5.5,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: calendar.date(byAdding: .day, value: 3, to: today)!,
            firstWeekday: 2
        )
        let comp = policies(rateCents: 283)
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            entries: entries, policies: comp,
            payrollTimeZone: PaydayTestZone.payroll, asOf: todayNoon.addingTimeInterval(7_200)
        ))

        // The prior shift: 8957c through the ledger, and 8957c through
        // WageEstimate too — it is alone in its week. Today's dinner shift is
        // 8956c through the ledger (its week's cumulative rounding) and 8957c
        // through WageEstimate. One cent, and it decides whether the echo
        // claims a record.
        #expect(snapshot.valuation(shiftID(9))?.components.earnedIncomeCents == 8_957)
        #expect(snapshot.valuation(shiftID(2))?.components.earnedIncomeCents == 8_956)

        let valued: [UUID: Int] = Dictionary(
            snapshot.shifts.map { ($0.id, $0.components.earnedIncomeCents) },
            uniquingKeysWith: { (first: Int, _: Int) in first }
        )
        let period = PayPeriodCalculator(
            payrollTimeZone: PaydayTestZone.payroll, schedule: schedule, calendar: payrollCalendar()
        ).period(containing: todayNoon)

        // Fed the ledger's figures, the engine compares 8956 against 8957 and
        // does NOT claim a record.
        let ledgerFed = StatsEngine(
            payrollTimeZone: PaydayTestZone.payroll, records: entries.map(TipRecord.init),
            calendar: calendar, valuedShiftCents: valued
        )
        let ledgerResult = ledgerFed.reveal(
            forNightAt: today, cents: 8_956, period: period, shiftID: shiftID(2)
        )
        #expect(ledgerResult.isRecord == false)

        // The superseded spelling: handed a scalar rate, the engine prices the
        // prior shift at WageEstimate's 8957 too, so the answer happens to
        // match here — but the figure the headline SHOWS is the ledger's
        // 8956, which is a different basis from the one it was ranked on.
        // That mismatch is the defect, and it is now unspellable: the engine
        // reads the same dictionary the row does.
        let scalarFed = StatsEngine(
            payrollTimeZone: PaydayTestZone.payroll, records: entries.map(TipRecord.init),
            calendar: calendar, wageCentsPerHour: 283
        )
        #expect(scalarFed.reveal(forNightAt: today, cents: 8_957, period: period, shiftID: shiftID(2)).isRecord == false)
        // Handed the ledger's 8956 while ranking on WageEstimate's numbers,
        // the two bases are 1c apart on the same shift.
        #expect(valued[shiftID(2)] != WageEstimate.cents(wageCentsPerHour: 283, hours: 5.5).map { $0 + 7_400 })
    }
}

/// The payroll zone is FROZEN and it is not the device's.
///
/// Every other suite in this file runs in `PaydayTestZone.payroll`, which is
/// `TimeZone.current` — so none of them can see a defect that only exists
/// when the two differ, and one did.
///
/// MEASURED before the fix (payroll zone `Pacific/Honolulu`, one
/// nil-`shiftID` entry at 2026-10-05 06:00 UTC, $123.45 credit, 8h at
/// $18/hr): `DashboardView.body` built the snapshot through
/// `LegacySnapshotBridge.snapshot(entries:)`, whose grouping takes the
/// DEFAULT `Calendar.current`, while `DashboardFacts` grouped in the payroll
/// zone. The nil-`shiftID` row therefore got two different
/// `ShiftDays.deterministicShiftID` values, `snapshot.valuation(payrollID)`
/// returned nil, the row rendered `isUnavailable == true` with no text, and
/// the hero above it read 26,745c. A right hero over a blank row.
///
/// There is ONE grouping now (`DashboardEarnings.build`) and both the
/// snapshot and the adapter are built from it, so the two cannot be keyed
/// differently. The blast radius was bounded to rows
/// `MigrationRunner.backfillShiftIDs` had not reached, but `runPending` is
/// gated by a durable `localMigrationVersion` flag, so a nil-`shiftID` row
/// arriving later (a sync from a pre-grouping client) stays nil forever.
@Suite("Dashboard in a payroll zone that is not the device's")
struct DashboardPayrollZoneTests {
    /// A zone that cannot equal `TimeZone.current` on any machine this runs
    /// on — chosen so the test is a real measurement and not a coin flip.
    private var payrollZone: TimeZone {
        PaydayTestZone.payroll.identifier == PaydayTestZone.honolulu.identifier
            ? PaydayTestZone.tokyo
            : PaydayTestZone.honolulu
    }

    @Test("a legacy row with no shiftID is keyed the same way by the snapshot and by the rows")
    func nilShiftIDIsKeyedOnce() throws {
        // 06:00 UTC on 2026-10-05: the previous civil day in Honolulu
        // (20:00 on the 4th) and already the 5th in most of the world, so
        // the device grouping and the payroll grouping land on different
        // days whichever way the runner's zone falls.
        let at0600UTC = Date(timeIntervalSince1970: 1_791_180_000)
        let entries = [
            TipEntry(date: at0600UTC, amountCents: 12_345, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: nil)
        ]
        let comp = CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("dash/zone/rate"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 1_800,
                provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("dash/zone/calendar"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: payrollZone
            )]
        )

        let payrollCalendarInZone = PayrollCalendar.gridCalendar(in: payrollZone)
        let payrollID = ShiftDays.deterministicShiftID(for: at0600UTC, calendar: payrollCalendarInZone)
        let deviceID = ShiftDays.deterministicShiftID(for: at0600UTC, calendar: .current)
        #expect(payrollID != deviceID, "the two calendars disagree, which is the premise")

        let dataset = DashboardEarnings.build(
            entries: entries,
            policies: comp,
            payrollTimeZone: payrollZone,
            calendar: payrollCalendarInZone
        )
        let snapshot = try #require(dataset.snapshot)

        // ONE id: the grouping's, the snapshot's and the row's.
        #expect(dataset.shiftDays.count == 1)
        #expect(dataset.shiftDays.first?.shiftID == payrollID)
        #expect(snapshot.valuation(payrollID) != nil)
        #expect(snapshot.valuation(deviceID) == nil, "nothing is keyed by the device's zone any more")

        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: payrollCalendarInZone.startOfDay(for: at0600UTC.addingTimeInterval(6 * 86_400)),
            payDelayDays: 5,
            firstWeekday: 2
        )
        let facts = DashboardFacts(
            snapshot: snapshot,
            allShifts: dataset.shiftDays,
            schedule: schedule,
            now: at0600UTC.addingTimeInterval(2 * 86_400),
            forcedPaydayPhase: nil,
            dismissedClosedEnd: nil,
            dismissedCheckEnd: nil,
            payrollTimeZone: payrollZone
        )
        let group = try #require(facts.shiftDays.first)
        #expect(group.shiftID == payrollID)

        // The row renders its money, which is the assertion that failed
        // before: $123.45 of tips plus 8h at $18.00/hr.
        let row = ShiftDayRowFacts(
            snapshot: facts.snapshot,
            shiftID: group.shiftID,
            day: group.day,
            period: .dinner,
            dayHasMultipleShifts: false
        )
        #expect(row.amount.isUnavailable == false)
        #expect(row.amount.cents == 12_345 + 14_400)
        #expect(row.amount.text == "$267.45")
        #expect(facts.hero.cents == 12_345 + 14_400)
        #expect(row.amount.cents == facts.hero.cents, "one shift, so the row IS the hero")
    }
}

/// ONE dataset, ONE stamp, and the to-date cutoff as an argument.
///
/// MEASURED before the fix: Dashboard built its snapshot with `asOf: now`
/// while `HistoryEarnings.build` builds its with `asOf: .distantFuture`
/// ("History has never applied a to-date cutoff"). On the current period,
/// with one past shift and one future-dated one, Dashboard read 40400 and the
/// History row and period detail both read 79800, all three labelled "You
/// kept" — and the two stamp digests DIFFERED (06e8b97a against 5e86e528), so
/// they were provably two datasets and a reviewer could not even diff them.
/// Tapping "See all" walked the person from $404.00 to $798.00.
///
/// The dataset is unclamped now, so the digest is the same digest History
/// computes over the same rows and policies, and Dashboard's narrower scope
/// is an `asOf:` argument on one query that the hero also declares on screen.
///
/// The fixture is the CURRENT period on purpose. A closed period cannot see
/// any of this: `now` is past `period.end`, so the clamp is a no-op and both
/// cutoffs return the same cents.
@Suite("Dashboard's cutoff is a query argument, not a second dataset")
struct DashboardCutoffTests {
    @Test("MEASURED: one snapshot answers both scopes, and its stamp is the unclamped one")
    func oneDatasetTwoScopes() throws {
        let schedule = PaySchedule(
            frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0),
            payDelayDays: 5, firstWeekday: 2
        )
        let now = at(2026, 10, 7, hour: 12)
        let entries = [
            TipEntry(date: at(2026, 10, 5), amountCents: 30_000, kind: .credit, hoursWorked: 8,
                     tipOutCents: 4_000, shiftPeriod: .dinner, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 10, 9), amountCents: 25_000, kind: .credit, hoursWorked: 8,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let comp = policies(rateCents: 1_800)
        let facts = dashboardFacts(entries: entries, schedule: schedule, now: now, policies: comp)

        let dataset = dashboardDataset(entries: entries, policies: comp)
        let snapshot = try #require(dataset.snapshot)
        let currentRange = DayRange(
            start: CivilDay(at(2026, 9, 28, hour: 0), in: PaydayTestZone.payroll),
            end: CivilDay(at(2026, 10, 11, hour: 0), in: PaydayTestZone.payroll)
        )

        // The SAME dataset, asked two questions.
        let toDate = snapshot.range(currentRange, asOf: CivilDay(now, in: PaydayTestZone.payroll))
        let whole = snapshot.range(currentRange)
        #expect(toDate.knownComponents.earnedIncomeCents == 40_400)
        #expect(whole.knownComponents.earnedIncomeCents == 79_800)
        #expect(toDate.manifestDigest == whole.manifestDigest, "one dataset, two scopes")

        // Dashboard's hero is the to-date one, off that identical dataset.
        #expect(facts.hero.cents == 40_400)
        #expect(facts.stamp?.digest == snapshot.stamp.digest)

        // And the stamp is the UNCLAMPED one, which is the digest a surface
        // with no cutoff (History, Calendar, the log preview) computes over
        // the same rows. MEASURED: a snapshot built with `asOf: now` has a
        // different digest, which is what made the two screens two datasets.
        let historyShapedSnapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: dataset.shiftDays,
            policies: comp,
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: .distantFuture
        ))
        #expect(facts.stamp?.digest == historyShapedSnapshot.stamp.digest)
        let nowClampedSnapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: dataset.shiftDays,
            policies: comp,
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: now
        ))
        #expect(facts.stamp?.digest != nowClampedSnapshot.stamp.digest, "the superseded dataset-level clamp")

        // The scope the hero does not cover is the scope it names.
        #expect(facts.heroDeferredShiftCount == 1)
        #expect(facts.hero.caption == "1 shift dated later this period")
        #expect(facts.hero.label == "Known so far")
    }
}

/// The render budget. `DashboardFacts` is built from an already-built
/// snapshot, which is what `DashboardRenderCache` holds across a `@State`
/// change; this measures both halves separately so a regression in either is
/// legible.
@Suite("Dashboard render facts performance")
struct DashboardRenderFactsPerformanceTests {
    @Test("a 10,000-row history builds its snapshot once and its facts cheaply")
    func factsStayFastForLargeHistory() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PaydayTestZone.payroll
        let historyStart = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))!
        // The last day of a period that sits wholly inside the history, so the
        // facts have a real fourteen shifts to reduce rather than an empty
        // period past the end of the data.
        let now = calendar.date(from: DateComponents(year: 2027, month: 5, day: 15, hour: 12))!
        let entries = (0..<10_000).map { index in
            TipEntry(
                date: calendar.date(byAdding: .day, value: index, to: historyStart)!,
                amountCents: 100,
                kind: .credit,
                recordedAt: historyStart,
                hoursWorked: 5,
                shiftID: shiftID(index + 1)
            )
        }
        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: calendar.date(from: DateComponents(year: 2027, month: 5, day: 15))!,
            payDelayDays: 5,
            firstWeekday: 2
        )
        let comp = policies(rateCents: 1_800)

        // The grouping is inside the budget now, because it is inside the
        // dataset: the view groups once, caches the pair, and rebuilds both
        // on the same `LegacySnapshotRevision` signal.
        let snapshotStartedAt = Date.timeIntervalSinceReferenceDate
        let dataset = DashboardEarnings.build(
            entries: entries,
            policies: comp,
            payrollTimeZone: PaydayTestZone.payroll,
            calendar: PayrollCalendar.gridCalendar(in: PaydayTestZone.payroll)
        )
        let snapshot = try #require(dataset.snapshot)
        let snapshotElapsed = Date.timeIntervalSinceReferenceDate - snapshotStartedAt

        let factsStartedAt = Date.timeIntervalSinceReferenceDate
        let facts = DashboardFacts(
            snapshot: snapshot,
            allShifts: dataset.shiftDays,
            schedule: schedule,
            now: now,
            forcedPaydayPhase: nil,
            dismissedClosedEnd: nil,
            dismissedCheckEnd: nil,
            payrollTimeZone: PaydayTestZone.payroll
        )
        let factsElapsed = Date.timeIntervalSinceReferenceDate - factsStartedAt

        // Fourteen shifts of 5h at $18.00/hr — 35h a week, under the overtime
        // threshold, so the budget measures the reduction and not an
        // allocation edge case.
        #expect(facts.shiftCount == 14)
        #expect(facts.hero.cents == 14 * 100 + 14 * 9_000)
        // Both budgets scale on CI exactly as `RenderFactsPerformanceTests`
        // does, and for the same reason: these measure the machine as much as
        // the code, and a real algorithmic regression is an order of
        // magnitude rather than 20%.
        #expect(
            snapshotElapsed < RenderFactsPerformanceTests.budget(1.0),
            "Legacy snapshot over 10,000 shifts took \(snapshotElapsed)s against a 1.0s budget scaled x\(RenderFactsPerformanceTests.budgetScale)"
        )
        #expect(
            factsElapsed < RenderFactsPerformanceTests.budget(1.0),
            "Dashboard facts took \(factsElapsed)s against a 1.0s budget scaled x\(RenderFactsPerformanceTests.budgetScale)"
        )
    }
}
