import Testing
import Foundation
@testable import Payday

// ═══════════════════════════════════════════════════════════════════════════
//  PR 5 wave 2, groups 2.6 and 2.7 (Insights). The parity and basis gates
//  for the page after it moved onto `EarningsSnapshot`.
//
//  Every number in here is MEASURED against the real adapters —
//  `InsightsEarnings.build`, `InsightsEarnings.basis`,
//  `InsightsEarnings.pricing` and the `StatsEngine` the view constructs from
//  them — never against a helper that restates them. That is the plan's
//  completion rule 2, and it is why `InsightsEarnings` is internal.
//
//  The audit's finding this suite closes: `InsightsView` built its
//  `StatsEngine` with NO wage rate, so every fact, chart point, typical
//  range, trend, forecast and Move on the page was `nonWageEarnings` while
//  the headlines above them were wage-inclusive. `docs/METRICS.md` [IL-01]
//  through [IL-27].
// ═══════════════════════════════════════════════════════════════════════════

/// The grid calendar, in the frozen payroll zone, Monday-start — the one
/// `InsightsView.body` hands to both halves.
private func insightsCalendar() -> Calendar {
    PayrollCalendar.gridCalendar(in: PaydayTestZone.payroll)
}

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func shiftID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
}

/// The user's real compensation history, as `PolicyStore` holds it. Never a
/// scalar rate handed to the bridge: that re-stamps as a `.distantPast`
/// `.confirmed` policy and reprices every pre-raise shift at today's rate
/// (wave 0 MEASURED $520.00/`.complete` against the correct
/// $440.00/`.estimated`).
private func policies(
    rateCents: Int?,
    workweekStartWeekday: Int = 2,
    provenance: RateProvenance = .confirmed
) -> CompensationPolicies {
    let calendar = PayrollCalendarPolicy(
        id: PolicyMigration.deterministicID("ins/calendar/\(workweekStartWeekday)"),
        effectiveFrom: .distantPast,
        workweekStartWeekday: workweekStartWeekday,
        payrollTimeZone: PaydayTestZone.payroll
    )
    guard let rateCents else { return CompensationPolicies(rates: [], calendars: [calendar]) }
    return CompensationPolicies(
        rates: [PayRatePolicy(
            id: PolicyMigration.deterministicID("ins/rate/\(rateCents)/\(provenance.rawValue)"),
            effectiveFrom: .distantPast,
            hourlyRateCents: rateCents,
            provenance: provenance
        )],
        calendars: [calendar]
    )
}

/// The dataset exactly as `InsightsView.body` builds it: ONE grouping in the
/// frozen payroll zone and the snapshot built from that same grouping.
private func dataset(
    _ entries: [TipEntry],
    _ compensation: CompensationPolicies,
    payrollTimeZone: TimeZone = PaydayTestZone.payroll
) -> InsightsEarnings.Dataset {
    InsightsEarnings.build(
        entries: entries,
        policies: compensation,
        payrollTimeZone: payrollTimeZone,
        calendar: PayrollCalendar.gridCalendar(in: payrollTimeZone)
    )
}

/// `InsightsEarnings.engine` — the function `InsightsPageFacts.init` itself
/// calls — with this suite's zone and grid calendar filled in. A FORWARDER,
/// never a restatement.
///
/// Its predecessor here rebuilt the construction by hand, and so did not gate
/// the screen: with `valuedShiftCents` patched to nil in the view, reverting
/// the whole page to tips-only under wage-inclusive headers, the full app
/// suite still reported `Test run with 855 tests in 154 suites passed`. That
/// is the "a test that rebuilds this by hand is a test that can share the
/// view's mistake" warning in `InsightsEarnings.Dataset`'s own header, paid
/// for. The real gate is `InsightsPageFactsTests` below, which constructs the
/// view's facts struct itself.
private func insightsEngine(
    _ set: InsightsEarnings.Dataset,
    in payrollTimeZone: TimeZone = PaydayTestZone.payroll
) -> StatsEngine {
    InsightsEarnings.engine(
        for: set,
        payrollTimeZone: payrollTimeZone,
        calendar: PayrollCalendar.gridCalendar(in: payrollTimeZone)
    )
}

/// The page's facts exactly as `InsightsView.body` computes them: the real
/// `InsightsPageFacts`, over the real dataset, with the real grid calendar.
private func pageFacts(
    _ entries: [TipEntry],
    _ compensation: CompensationPolicies,
    now: Date,
    payrollTimeZone: TimeZone = PaydayTestZone.payroll
) -> InsightsPageFacts {
    InsightsPageFacts(
        dataset: dataset(entries, compensation, payrollTimeZone: payrollTimeZone),
        ledger: [:],
        payrollTimeZone: payrollTimeZone,
        calendar: PayrollCalendar.gridCalendar(in: payrollTimeZone),
        now: now
    )
}

/// Five wage-complete shifts in one Monday-start workweek, 38 hours, under
/// the 40-hour threshold so no overtime is involved. Tips and wages are both
/// material, and two shifts carry a tip-out, so a tips-only figure and a
/// wage-inclusive one cannot coincide.
private func wageCompleteFixture() -> [TipEntry] {
    [
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
}

/// The civil days `wageCompleteFixture` covers.
private func fixtureRange() -> DayRange {
    DayRange(
        start: CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll),
        end: CivilDay(at(2026, 10, 2), in: PaydayTestZone.payroll)
    )
}

// ═══════════════════════════════════════════════════════════════════════════

/// **The parity invariant for this screen: an Insights figure over a date
/// range equals the same range queried on the snapshot.**
///
/// Insights renders no range total directly, so the figure that carries the
/// invariant is the one every other figure on the page is built out of —
/// `StatsEngine`'s per-day totals, which feed the chart, the pace, the work
/// rhythm, the weekday Moves, `typicalRanges`, `earningTrend`,
/// `forecastAccuracy` and `planForward`. If those equal the engine's own
/// range answer, every derivation above them is on the engine's basis.
@Suite("Insights snapshot parity")
struct InsightsSnapshotParityTests {
    /// MEASURED on `wageCompleteFixture` at $20.00/hr, 38 hours:
    ///
    /// - tips only: 47,300c (50,000 gross − 2,700 tipped out)
    /// - wages: 76,000c (38 hours, no overtime)
    /// - earned income: 123,300c
    ///
    /// The page used to print the first number under headers that say
    /// "earnings"; it now prints the third, and the snapshot agrees to the
    /// cent.
    @Test("day totals over a range equal the same range queried on the snapshot")
    func dayTotalsEqualTheRangeQuery() throws {
        let set = dataset(wageCompleteFixture(), policies(rateCents: 2_000))
        let snapshot = try #require(set.snapshot)
        let range = fixtureRange()

        let engineTotal = insightsEngine(set).nightlyTotals()
            .filter { range.contains(CivilDay($0.date, in: PaydayTestZone.payroll)) }
            .reduce(0) { $0 + $1.cents }
        let queried = snapshot.range(range, asOf: CivilDay.distantFuture)

        #expect(engineTotal == queried.knownComponents.earnedIncomeCents)
        #expect(engineTotal == 123_300)

        // The disagreeing case, without which the equality above could hold
        // by coincidence: the pre-wave-2 page summed the SAME days to a
        // different number, and had no way to say which one it was showing.
        #expect(queried.knownComponents.nonWageEarningsCents == 47_300)
        #expect(engineTotal != queried.knownComponents.nonWageEarningsCents)
        let unpriced = StatsEngine(
            payrollTimeZone: PaydayTestZone.payroll,
            records: set.tipRecords,
            calendar: insightsCalendar()
        )
        #expect(unpriced.nightlyTotals().reduce(0) { $0 + $1.cents } == 47_300)
    }

    /// A wage-complete dataset declares `earnedIncome` and says so on screen.
    @Test("a fully priced dataset puts the page on earned income and declares it")
    func wageCompleteDeclaresEarnedIncome() throws {
        let set = dataset(wageCompleteFixture(), policies(rateCents: 2_000))
        let basis = InsightsEarnings.basis(for: set.snapshot)

        #expect(basis == .earnedIncome(assumed: false))
        #expect(basis.isWageInclusive)
        #expect(basis.metric == .earnedIncome)
        #expect(basis.note == "Every figure below includes your hourly wages.")
        #expect(InsightsEarnings.pricing(basis, set)?.count == 5)
    }

    /// `.estimated` reaches this page with its caption, rather than being
    /// unreachable. Wave 0 measured a scalar rate making `.estimated`
    /// impossible on every migrated surface, which turned
    /// `CompletenessCopy.caption(.estimated)` into dead code in production
    /// even though Settings ships the control that writes that history.
    @Test("an assumed rate carries its caption into the page's own note")
    func assumedRateCarriesItsCaption() throws {
        let set = dataset(
            wageCompleteFixture(),
            policies(rateCents: 2_000, provenance: .assumedFromLegacySetting)
        )
        let basis = InsightsEarnings.basis(for: set.snapshot)

        #expect(basis == .earnedIncome(assumed: true))
        #expect(basis.isWageInclusive)
        #expect(basis.note == "Every figure below includes your hourly wages. Wages estimated from your current rate.")
    }

    /// **No Insights comparison mixes bases.**
    ///
    /// One shift in the same five has no logged hours, so the ledger cannot
    /// price it. A wage-inclusive page would then compare that shift's
    /// tips-only take against four shifts carrying $150.00 to $160.00 of
    /// wages each — the audit's mixed-basis comparison, inside a typical
    /// range, a trend, and every weekday Move at once.
    ///
    /// The whole page falls back instead, and the copy says which shifts and
    /// why. MEASURED: basis `.nonWageEarnings(.incomplete(missingHours: 1,
    /// missingRate: 0))`, no pricing map at all, and the engine's day totals
    /// equal the snapshot's `nonWageEarnings` for the same days — 47,300c,
    /// not the 109,300c a half-priced page would have produced.
    @Test("one unpriceable shift falls the whole page back to tips, and says so")
    func oneUnpriceableShiftFallsTheWholePageBack() throws {
        var entries = wageCompleteFixture()
        entries[2] = TipEntry(
            date: at(2026, 9, 30), amountCents: 7_500, kind: .cash,
            hoursWorked: nil, shiftPeriod: .lunch, shiftID: shiftID(3)
        )
        let set = dataset(entries, policies(rateCents: 2_000))
        let snapshot = try #require(set.snapshot)
        let basis = InsightsEarnings.basis(for: set.snapshot)

        #expect(basis == .nonWageEarnings(.incomplete(missingHours: 1, missingRate: 0)))
        #expect(!basis.isWageInclusive)
        #expect(basis.metric == .nonWageEarnings)
        #expect(basis.note == "Every figure below is tips only. 1 shift have no hours logged.")
        #expect(InsightsEarnings.pricing(basis, set) == nil)

        let range = fixtureRange()
        let engineTotal = insightsEngine(set).nightlyTotals()
            .filter { range.contains(CivilDay($0.date, in: PaydayTestZone.payroll)) }
            .reduce(0) { $0 + $1.cents }
        let queried = snapshot.range(range, asOf: CivilDay.distantFuture)

        #expect(engineTotal == queried.knownComponents.nonWageEarningsCents)
        #expect(engineTotal == 47_300)
        // What a half-priced page would have shown: the four priced shifts'
        // wages folded in and the fifth silently short. The fall-back is what
        // keeps this number off the screen.
        #expect(queried.knownComponents.earnedIncomeCents == 109_300)
        #expect(engineTotal != queried.knownComponents.earnedIncomeCents)
    }

    /// Wages off is tips only BY NAME, not by accident. `earnedIncome` and
    /// `nonWageEarnings` are the same cents here, and only the second is an
    /// honest name for them — the widget's "TIPS" bug in the other direction.
    @Test("with no rate policy on file the page is tips only, named as tips")
    func noRatePolicyIsTipsOnly() throws {
        let set = dataset(wageCompleteFixture(), policies(rateCents: nil))
        let basis = InsightsEarnings.basis(for: set.snapshot)

        #expect(basis.metric == .nonWageEarnings)
        #expect(!basis.isWageInclusive)
        #expect(InsightsEarnings.pricing(basis, set) == nil)
        #expect(basis.note?.hasPrefix("Every figure below is tips only") == true)
    }

    /// An empty dataset states no basis and renders no figure.
    @Test("no snapshot and no shifts both refuse rather than declaring a basis")
    func unbackedRefuses() {
        #expect(InsightsEarnings.basis(for: nil) == .unavailable)
        #expect(InsightsEarnings.basis(for: nil).note == nil)
        #expect(InsightsEarnings.basis(for: nil).metric == nil)

        let empty = dataset([], policies(rateCents: 2_000))
        #expect(InsightsEarnings.basis(for: empty.snapshot) == .unavailable)
        #expect(InsightsEarnings.pricing(.unavailable, empty) == nil)
    }
}

/// The pricing map has to be TOTAL over the engine's own shifts, because a
/// map with a hole in it is the mixed basis the fall-back exists to prevent.
@Suite("Insights pricing totality")
struct InsightsPricingTotalityTests {
    /// The measured trap this guards, from `DashboardEarnings`' header: a
    /// legacy `TipEntry` with `shiftID == nil` takes
    /// `ShiftDays.deterministicShiftID(for:calendar:)`, which is
    /// `calendar.startOfDay(...)`-derived. Group in the DEVICE's zone and
    /// value in the PAYROLL zone and the two mint different ids for one
    /// shift, so `snapshot.valuation(id)` misses outright — on Dashboard that
    /// printed a hero over an unavailable row; here it would leave one shift
    /// priced on tips inside a wage-inclusive comparison.
    ///
    /// Both halves go through the same `PayrollCalendar.gridCalendar(in:)`
    /// now, so the ids agree in any zone. Checked in two, one of them a zone
    /// where the shift's civil day differs from the device's.
    @Test("every shift is priced, including a legacy row with no shiftID of its own")
    func everyShiftIsPricedInEveryZone() throws {
        for zone in [PaydayTestZone.payroll, TimeZone(identifier: "Pacific/Pago_Pago")!] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let day = { (d: Int, h: Int) in
                calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))!
            }
            var entries = [
                TipEntry(date: day(5, 17), amountCents: 10_000, kind: .credit,
                         hoursWorked: 8, shiftPeriod: .dinner, shiftID: shiftID(1)),
                TipEntry(date: day(6, 17), amountCents: 9_000, kind: .credit,
                         hoursWorked: 8, shiftPeriod: .dinner, shiftID: shiftID(2))
            ]
            // The legacy row: no shiftID at all, and logged at 02:00 so its
            // civil day differs between a device zone and this payroll zone.
            let legacy = TipEntry(date: day(7, 2), amountCents: 8_000, kind: .cash, hoursWorked: 8)
            legacy.shiftID = nil
            entries.append(legacy)

            let set = dataset(entries, policies(rateCents: 2_000), payrollTimeZone: zone)
            let basis = InsightsEarnings.basis(for: set.snapshot)
            let pricing = try #require(
                InsightsEarnings.pricing(basis, set),
                "the page fell back to tips in \(zone.identifier), so an id did not match"
            )

            #expect(set.shiftIDs.count == 3)
            for shiftID in set.shiftIDs {
                #expect(pricing[shiftID] != nil, "unpriced shift in \(zone.identifier)")
            }
            // And the prices are the ledger's own, not a repricing.
            let snapshot = try #require(set.snapshot)
            for valuation in snapshot.shifts {
                #expect(pricing[valuation.id] == valuation.components.earnedIncomeCents)
            }
        }
    }
}

/// [IL-13] and [IL-14]: the HOURLY tile.
@Suite("Insights hourly rate")
struct InsightsHourlyRateTests {
    /// The tile IS `EarningsResult.hourlyRateCents` over the same recent
    /// window the rest of the grid covers, not a number that agrees with it.
    ///
    /// MEASURED on `wageCompleteFixture` at $20.00/hr: 123,300c of earned
    /// income over 2,280 minutes is $32.45/hr, printed as "$32/hr" with
    /// "across 5 shifts".
    @Test("the hourly tile is the engine's own rate over the page's own window")
    func theHourlyTileIsTheEnginesOwnRate() throws {
        let now = at(2026, 10, 3, hour: 9)
        let set = dataset(wageCompleteFixture(), policies(rateCents: 2_000))
        let snapshot = try #require(set.snapshot)

        let hourly = try #require(
            InsightsEarnings.hourlyRate(snapshot, referenceDate: now, in: PaydayTestZone.payroll)
        )
        let window = InsightsEarnings.recentRange(referenceDate: now, in: PaydayTestZone.payroll)
        let queried = snapshot.range(window, asOf: CivilDay.distantFuture)

        #expect(hourly.rateCents == queried.hourlyRateCents)
        #expect(hourly.rateCents == 3_245)
        #expect(hourly.coveredShiftCount == 5)
        #expect(hourly.totalShiftCount == 5)
        #expect(hourly.coverage == "across 5 shifts")

        let tile = try #require(
            InsightsNumbersGrid.rows(for: InsightsFacts(shiftCount: 5, lunchDinner: nil, doublesSolo: nil), hourly: hourly)
                .first?.first
        )
        #expect(tile.id == "hourly")
        #expect(tile.value == "$32/hr")
        #expect(tile.context == "across 5 shifts")
    }

    /// **The denominator fix, MEASURED.** A shift with tips and no hours used
    /// to inflate the rate without appearing in it: the old tile's value was
    /// a mean of per-shift rates and its caption's count was
    /// `nightsWithHours`, so the shift was in neither the value nor the
    /// honesty signal. `hourlyRateCents` is `coveredComponents / minutes`,
    /// both over covered shifts only, and the coverage clause names the
    /// shortfall.
    @Test("a shift with no hours is excluded from both sides of the rate, and disclosed")
    func anHoursLessShiftIsExcludedFromBothSides() throws {
        let now = at(2026, 10, 3, hour: 9)
        var entries = wageCompleteFixture()
        entries.append(
            TipEntry(date: at(2026, 10, 3, hour: 12), amountCents: 40_000, kind: .credit,
                     hoursWorked: nil, shiftPeriod: .lunch, shiftID: shiftID(6))
        )
        let set = dataset(entries, policies(rateCents: 2_000))
        let snapshot = try #require(set.snapshot)

        let hourly = try #require(
            InsightsEarnings.hourlyRate(snapshot, referenceDate: now, in: PaydayTestZone.payroll)
        )
        // The $400 hours-less shift moves neither the numerator nor the
        // denominator: same 2,280 covered minutes, same covered components.
        #expect(hourly.rateCents == 3_245)
        #expect(hourly.coveredShiftCount == 5)
        #expect(hourly.totalShiftCount == 6)
        #expect(hourly.coverage == "across 5 of 6 shifts")

        // What a naive whole-period numerator over only the logged hours
        // would have produced, for contrast: it is higher by the whole $400.
        let queried = snapshot.range(
            InsightsEarnings.recentRange(referenceDate: now, in: PaydayTestZone.payroll),
            asOf: CivilDay.distantFuture
        )
        let inflated = IntegerRounding.divideHalfUp(
            queried.knownComponents.earnedIncomeCents * 60, by: queried.minutes
        )
        #expect(inflated == 4_297)
        #expect(hourly.rateCents != inflated)
    }
}

/// The two tiles that were on a THIRD basis, next to each other on one grid.
@Suite("Insights tile basis agreement")
struct InsightsTileBasisTests {
    /// MEASURED before wave 2, on one lunch and one dinner each carrying a
    /// $15.00 tip-out and 8 logged hours at $20.00/hr:
    ///
    /// - LUNCH / DINNER read `ShiftFacts.grossCents` — voluntary tips BEFORE
    ///   the tip-out and EXCLUDING gratuity
    /// - DOUBLES / SOLO, the row directly beneath them, read `netCents` —
    ///   after the tip-out and including gratuity
    ///
    /// So two adjacent rows of one grid, under one page, described the same
    /// shifts on two different bases, and neither label said which. Both now
    /// read `cents(of:)`, the page's declared basis, so LUNCH plus the wage
    /// equals what that shift's own row shows anywhere else in the app.
    @Test("lunch and dinner are on the page basis, not voluntary tips before tip-out")
    func lunchAndDinnerAreOnThePageBasis() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28, hour: 11), amountCents: 10_000, kind: .credit,
                     hoursWorked: 8, tipOutCents: 1_500, shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: at(2026, 9, 29), amountCents: 20_000, kind: .credit,
                     hoursWorked: 8, tipOutCents: 1_500, shiftPeriod: .dinner, shiftID: shiftID(2)),
            TipEntry(date: at(2026, 9, 30, hour: 11), amountCents: 10_000, kind: .credit,
                     hoursWorked: 8, shiftPeriod: .lunch, shiftID: shiftID(3)),
            TipEntry(date: at(2026, 10, 1), amountCents: 20_000, kind: .credit,
                     hoursWorked: 8, shiftPeriod: .dinner, shiftID: shiftID(4)),
            TipEntry(date: at(2026, 10, 2), amountCents: 20_000, kind: .credit,
                     hoursWorked: 8, shiftPeriod: .dinner, shiftID: shiftID(5))
        ]
        let set = dataset(entries, policies(rateCents: 2_000))
        let snapshot = try #require(set.snapshot)
        let facts = try #require(
            insightsEngine(set).insightsFacts(referenceDate: at(2026, 10, 3, hour: 9))
        )
        let lunch = try #require(facts.lunchDinner)

        // Each lunch: tips, less its tip-out, plus 8h at $20.00.
        let lunchOne = try #require(snapshot.valuation(shiftID(1)))
        let lunchTwo = try #require(snapshot.valuation(shiftID(3)))
        #expect(lunchOne.components.earnedIncomeCents == 24_500)
        #expect(lunchTwo.components.earnedIncomeCents == 26_000)
        #expect(lunch.lunchShiftCount == 2)
        #expect(lunch.lunchCents == 50_500)
        #expect(lunch.lunchCents == lunchOne.components.earnedIncomeCents
                + lunchTwo.components.earnedIncomeCents)

        // The old basis, for contrast: gross voluntary tips, tip-out never
        // taken out — 20,000c across the same two lunches.
        #expect(lunch.lunchCents != 20_000)

        // And the row below is on the same basis, so the two can be read
        // against each other: three dinners at 8h.
        let doubles = insightsEngine(set).insightsFacts(referenceDate: at(2026, 10, 3, hour: 9))?.doublesSolo
        #expect(lunch.dinnerCents == 34_500 + 36_000 + 36_000)
        #expect(doubles == nil, "no double day in this fixture, so nothing to compare against")
    }
}

/// Every derivation on the page, not just the day totals it is built from.
///
/// The plan's rule is that "every comparison declares its basis". The page
/// declares ONE basis, so the check is that each comparison actually ON the
/// page uses it — a per-figure opt-out would be invisible otherwise, because
/// nothing in the copy would change.
@Suite("Insights derivations on one basis")
struct InsightsDerivationBasisTests {
    /// Six weeks of Fridays and Saturdays, all wage-complete, priced so the
    /// wage is a large fraction of the take. Every figure below therefore
    /// moves a lot between the two bases, which is what makes "it is on the
    /// declared basis" a testable claim rather than a coincidence.
    private func rhythm() -> [TipEntry] {
        var entries: [TipEntry] = []
        var index = 0
        // Fridays and Saturdays, 2 Oct 2026 through 7 Nov 2026.
        for week in 0..<6 {
            for (offset, period) in [(0, ShiftPeriod.dinner), (1, ShiftPeriod.dinner)] {
                index += 1
                entries.append(
                    TipEntry(
                        date: at(2026, 10, 2 + week * 7 + offset),
                        amountCents: 10_000,
                        kind: .credit,
                        hoursWorked: 8,
                        shiftPeriod: period,
                        shiftID: shiftID(index)
                    )
                )
            }
        }
        return entries
    }

    /// The typical range IS the per-shift earned income, so the low and high
    /// ends of "what a shift usually pays" ([IL-01], [IL-02]) are the same
    /// cents that shift's own row shows anywhere else in the app.
    ///
    /// MEASURED: $100.00 of tips plus 8 hours at $20.00 is $260.00 a shift on
    /// the declared basis; the unpriced engine puts the same shifts at
    /// $100.00, which is the figure that used to sit under the header.
    @Test("the typical range is on the page basis, not tips")
    func typicalRangeIsOnThePageBasis() throws {
        let set = dataset(rhythm(), policies(rateCents: 2_000))
        let now = at(2026, 11, 9, hour: 9)

        let priced = try #require(insightsEngine(set).typicalRanges(referenceDate: now)?.overall)
        #expect(priced.lowCents == 26_000)
        #expect(priced.highCents == 26_000)

        let unpriced = StatsEngine(
            payrollTimeZone: PaydayTestZone.payroll,
            records: set.tipRecords,
            calendar: insightsCalendar()
        )
        let tipsOnly = try #require(unpriced.typicalRanges(referenceDate: now)?.overall)
        #expect(tipsOnly.lowCents == 10_000)
        #expect(priced.lowCents != tipsOnly.lowCents)
    }

    /// THE WEEK AHEAD ([IL-24], [IL-25]) projects per-weekday averages, so it
    /// moves onto the declared basis with everything else. A forecast in tips
    /// under a page that includes wages is the same defect as a total in tips
    /// under a header that says earnings, one week later.
    @Test("the week-ahead forecast is on the page basis, not tips")
    func planForwardIsOnThePageBasis() throws {
        let set = dataset(rhythm(), policies(rateCents: 2_000))
        let now = at(2026, 11, 9, hour: 9)

        let priced = try #require(insightsEngine(set).planForward(referenceDate: now))
        let unpriced = try #require(
            StatsEngine(
                payrollTimeZone: PaydayTestZone.payroll,
                records: set.tipRecords,
                calendar: insightsCalendar()
            ).planForward(referenceDate: now)
        )

        #expect(priced.projectedTotalCents > unpriced.projectedTotalCents)
        #expect(priced.nights.allSatisfy { $0.averageNetCents == 26_000 })
        #expect(unpriced.nights.allSatisfy { $0.averageNetCents == 10_000 })
        // And the headline reads the already-computed integer, adding nothing.
        #expect(PlanForwardCopy.headline(for: priced)
                == "Next week: about \(Money.wholeDollarString(fromCents: priced.projectedTotalCents)).")
    }

    /// The tiles that are deliberately NOT on the page basis do not move with
    /// it, because a wage is not a tip: "tipped 16.7% of sales" and "$10.40 in
    /// tips per table" would be false with a wage folded in. Each declares its
    /// own basis in its own caption instead.
    @Test("the tips-only tiles are identical on either page basis")
    func tipsOnlyTilesDoNotFollowThePageBasis() throws {
        let entries = wageCompleteFixture().map { entry -> TipEntry in
            entry.salesCents = 50_000
            return entry
        }
        let set = dataset(entries, policies(rateCents: 2_000))
        let now = at(2026, 10, 3, hour: 9)

        let priced = try #require(insightsEngine(set).insightsFacts(referenceDate: now)?.sales)
        let unpriced = try #require(
            StatsEngine(
                payrollTimeZone: PaydayTestZone.payroll,
                records: set.tipRecords,
                calendar: insightsCalendar()
            ).insightsFacts(referenceDate: now)?.sales
        )
        #expect(priced == unpriced)
        #expect(priced.nightsWithSales == 5)
    }
}

/// The basis sentence itself — the only place the page says which metric its
/// numbers are.
@Suite("Insights basis copy")
struct InsightsBasisCopyTests {
    @Test("a missing rate is named separately from missing hours")
    func missingRateIsNamedSeparately() {
        #expect(
            InsightsBasis.nonWageEarnings(.incomplete(missingHours: 0, missingRate: 2)).note
                == "Every figure below is tips only. 2 shifts have no rate set."
        )
        #expect(
            InsightsBasis.nonWageEarnings(.incomplete(missingHours: 3, missingRate: 2)).note
                == "Every figure below is tips only. 3 shifts have no hours logged and 2 shifts have no rate set."
        )
    }

    /// A tips-only page must never call its figures earnings. This is Tyler's
    /// decision stated as an assertion: anything labelled earnings or Total is
    /// wage-inclusive, and a tips-only figure is labelled Tips.
    @Test("a tips-only basis never says earnings, and a wage-inclusive one says wages")
    func theNoteNamesTheRightMetric() {
        let tipsOnly: [InsightsBasis] = [
            .nonWageEarnings(.wagesOff),
            .nonWageEarnings(.incomplete(missingHours: 1, missingRate: 0))
        ]
        for basis in tipsOnly {
            let note = basis.note ?? ""
            #expect(note.contains("tips only"))
            #expect(!note.lowercased().contains("earnings"))
            #expect(!note.contains("Total"))
            #expect(basis.metric == .nonWageEarnings)
        }
        for basis in [InsightsBasis.earnedIncome(assumed: false), .earnedIncome(assumed: true)] {
            #expect(basis.note?.contains("includes your hourly wages") == true)
            #expect(basis.metric == .earnedIncome)
        }
    }

    /// Coverage is a fraction only when there is a shortfall, and its plural
    /// comes from `CompletenessCopy.shiftCount` so this page counts shifts in
    /// the same words every other screen does.
    @Test("hourly coverage reads singular, plural, and fractional correctly")
    func coverageWording() {
        #expect(
            InsightsEarnings.HourlyRate(rateCents: 100, coveredShiftCount: 1, totalShiftCount: 1)
                .coverage == "across 1 shift"
        )
        #expect(
            InsightsEarnings.HourlyRate(rateCents: 100, coveredShiftCount: 1, totalShiftCount: 2)
                .coverage == "across 1 of 2 shifts"
        )
        #expect(
            InsightsEarnings.HourlyRate(rateCents: 100, coveredShiftCount: 9, totalShiftCount: 9)
                .coverage == "across 9 shifts"
        )
    }
}

/// The wave-1 `asOf` discipline, applied to this screen.
///
/// Dashboard and History baked different cutoffs into their datasets and read
/// two figures under one label — 40,400c against 79,800c on the same period,
/// with DIFFERENT stamp digests, so the disagreement was not even diffable.
/// Insights' dataset is unclamped like theirs, and unlike the pre-wave-2
/// version, which passed `asOf: now`.
@Suite("Insights asOf discipline")
struct InsightsAsOfTests {
    @Test("the dataset is unclamped, so a future-dated shift is still in it")
    func theDatasetIsUnclamped() throws {
        var entries = wageCompleteFixture()
        entries.append(
            TipEntry(date: at(2027, 1, 15), amountCents: 5_000, kind: .credit,
                     hoursWorked: 4, shiftPeriod: .dinner, shiftID: shiftID(9))
        )
        let snapshot = try #require(dataset(entries, policies(rateCents: 2_000)).snapshot)

        // `CivilDay(Date.distantFuture, in:)` lands on 4000-12-31, not
        // `CivilDay.distantFuture` (9999-12-31) — the bridge takes a `Date`
        // and `Calendar` caps there. What matters is that it is far beyond
        // every shift, which is what "no cutoff" means.
        #expect(snapshot.stamp.asOf == CivilDay(Date.distantFuture, in: PaydayTestZone.payroll))
        #expect((snapshot.stamp.asOf?.year ?? 0) >= 4000)
        #expect(snapshot.shifts.count == 6)
        #expect(snapshot.valuation(shiftID(9)) != nil)
    }

    /// And the narrower scope is a QUERY argument. The HOURLY tile's 180-day
    /// window is a `DayRange` asked for at the call site, so the future-dated
    /// shift above is outside it while remaining inside the dataset both this
    /// screen and every other one share.
    @Test("the recent window is a query argument, inclusive of both ends")
    func theRecentWindowIsAQueryArgument() {
        let now = at(2026, 10, 3, hour: 9)
        let window = InsightsEarnings.recentRange(referenceDate: now, in: PaydayTestZone.payroll)

        #expect(window.end == CivilDay(now, in: PaydayTestZone.payroll))
        #expect(window.count == StatsEngine.insightsRecentWindowDays + 1)
        #expect(!window.contains(CivilDay(at(2027, 1, 15), in: PaydayTestZone.payroll)))
        #expect(window.contains(CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll)))
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  The gates below construct the REAL `InsightsPageFacts` — the struct
//  `InsightsView.body` renders from — rather than any restatement of its
//  wiring. That distinction is not academic. While `InsightsPageFacts` was
//  private, this file rebuilt the construction in a helper of its own, and
//  the suite therefore did not gate the screen: in a scratch copy with
//  `valuedShiftCents: InsightsEarnings.pricing(basis, dataset)` replaced by
//  `valuedShiftCents: nil` — the single line that reverts the whole page to
//  tips-only under wage-inclusive headers — the full app suite still
//  reported `Test run with 855 tests in 154 suites passed`, `** TEST
//  SUCCEEDED **`, zero failures. Nothing in 855 tests noticed.
// ═══════════════════════════════════════════════════════════════════════════

/// **The page, as the view computes it.** Every money surface on
/// `InsightsPageFacts` has to be on the ONE basis the same struct declares.
@Suite("Insights page facts")
struct InsightsPageFactsTests {
    /// The wage-inclusive page: the note says wages, and the tiles, the
    /// chart and the HOURLY tile all carry them.
    ///
    /// MEASURED on `wageCompleteFixture` at $20.00/hr: LUNCH 21,500c (one
    /// $75.00 cash lunch plus 7h), DINNER 101,800c, together 123,300c — the
    /// same cents `snapshot.range(fixtureRange)` answers, and the same total
    /// the five chart bars sum to.
    @Test("a wage-complete page puts the tiles, the chart and HOURLY on wages")
    func aWageCompletePageIsWageInclusiveThroughout() throws {
        let now = at(2026, 10, 3, hour: 9)
        let facts = pageFacts(wageCompleteFixture(), policies(rateCents: 2_000), now: now)
        let snapshot = try #require(dataset(wageCompleteFixture(), policies(rateCents: 2_000)).snapshot)
        let queried = snapshot.range(fixtureRange(), asOf: CivilDay.distantFuture)

        #expect(facts.basis == .earnedIncome(assumed: false))
        #expect(facts.basis.note == "Every figure below includes your hourly wages.")

        // The tiles. This is the assertion that fails if the view ever stops
        // handing the engine the ledger's pricing: an unpriced page reads
        // 7,500c and 39,800c over the same two rows.
        let lunchDinner = try #require(facts.facts?.lunchDinner)
        #expect(lunchDinner.lunchCents == 21_500)
        #expect(lunchDinner.dinnerCents == 101_800)
        #expect(lunchDinner.lunchCents + lunchDinner.dinnerCents
                == queried.knownComponents.earnedIncomeCents)
        #expect(lunchDinner.lunchCents != 7_500, "an unpriced page's LUNCH tile")

        // The chart, on the same metric and summing to the same total.
        #expect(facts.chartFacts.metric == .earnedIncome)
        #expect(facts.chartFacts.points.map(\.cents) == [26_500, 24_000, 21_500, 25_800, 25_500])
        #expect(facts.chartFacts.points.reduce(0) { $0 + $1.cents } == 123_300)
        #expect(facts.chartFacts.points.allSatisfy { $0.figure.metric == .earnedIncome })

        // And the HOURLY tile, which a wage-inclusive page may ask for.
        let hourly = try #require(facts.hourly)
        #expect(hourly.rateCents == 3_245)
        #expect(hourly.rateCents == queried.hourlyRateCents)
    }

    /// **The fall-back, applied to every surface and not just the engine.**
    ///
    /// One of the same five shifts has no logged hours — the ordinary case,
    /// since `BackfillSheet.performSave` writes no `hoursWorked` at all, so
    /// every shift added through "Add Past Shifts" (the button on Insights'
    /// own empty state) is hours-less. The page falls back to tips and says
    /// so, and then the chart and the HOURLY tile have to obey that sentence.
    ///
    /// MEASURED before the fix: the note read "Every figure below is tips
    /// only. 1 shift have no hours logged." while the chart directly beneath
    /// it drew [26500, 24000, 7500, 25800, 25500] with scrub readouts
    /// "$265.00" … "$255.00" and bar labels "You kept" / "Total" / "Known so
    /// far", over the same five days every other figure on the page read
    /// [10500, 9000, 7500, 9800, 10500].
    @Test("a tips-only page's chart and HOURLY tile obey the note above them")
    func aTipsOnlyPageIsTipsOnlyThroughout() throws {
        let now = at(2026, 10, 3, hour: 9)
        var entries = wageCompleteFixture()
        entries[2] = TipEntry(
            date: at(2026, 9, 30), amountCents: 7_500, kind: .cash,
            hoursWorked: nil, shiftPeriod: .lunch, shiftID: shiftID(3)
        )
        let facts = pageFacts(entries, policies(rateCents: 2_000), now: now)
        let snapshot = try #require(dataset(entries, policies(rateCents: 2_000)).snapshot)
        let range = fixtureRange()
        let queried = snapshot.range(range, asOf: CivilDay.distantFuture)

        #expect(facts.basis == .nonWageEarnings(.incomplete(missingHours: 1, missingRate: 0)))
        #expect(facts.basis.note == "Every figure below is tips only. 1 shift have no hours logged.")

        // THE CHART. Bar for bar, the same cents the snapshot answers for
        // the metric the note named.
        #expect(facts.chartFacts.metric == .nonWageEarnings)
        let barCents = facts.chartFacts.points.map(\.cents)
        #expect(barCents == snapshot.days(in: range, asOf: CivilDay.distantFuture)
                .map(\.knownComponents.nonWageEarningsCents))
        #expect(barCents == [10_500, 9_000, 7_500, 9_800, 10_500])
        #expect(barCents.reduce(0, +) == queried.knownComponents.nonWageEarningsCents)
        #expect(barCents.reduce(0, +) == 47_300)

        // The disagreeing case, asserted as what must NOT appear: the
        // wage-inclusive numbers for the very same days.
        let wageInclusive = snapshot.days(in: range, asOf: CivilDay.distantFuture)
            .map(\.knownComponents.earnedIncomeCents)
        #expect(wageInclusive == [26_500, 24_000, 7_500, 25_800, 25_500])
        #expect(barCents != wageInclusive)
        #expect(!barCents.contains(26_500))
        #expect(barCents.reduce(0, +) != 109_300)

        // And a tips bar never wears an earned-income noun. "Total" is the
        // one Tyler's rule reserves for wage-inclusive figures.
        #expect(facts.chartFacts.points.allSatisfy { $0.figure.metric == .nonWageEarnings })
        #expect(facts.chartFacts.points.allSatisfy { $0.figure.label == "Tips" })
        #expect(facts.chartFacts.points.allSatisfy { !$0.figure.mayBeCalledATotal })
        // A tips figure has nothing missing from it, so no bar claims to be
        // a partial reading of one.
        #expect(facts.chartFacts.points.allSatisfy { !$0.isPartial })

        // THE HOURLY TILE. `hourlyRateCents` divides
        // `coveredComponents.earnedIncomeCents`, so on a tips-only page the
        // page cannot honestly ask for it — and the engine would have
        // answered if asked, which is what makes the suppression the fix
        // rather than a coincidence.
        #expect(facts.hourly == nil)
        #expect(
            InsightsEarnings.hourlyRate(snapshot, referenceDate: now, in: PaydayTestZone.payroll) != nil,
            "the engine can still answer; it is the PAGE that must not ask"
        )
        #expect(InsightsNumbersGrid.rows(for: try #require(facts.facts), hourly: facts.hourly)
                .flatMap { $0 }.allSatisfy { $0.id != "hourly" })

        // The tiles are on tips too, which is what wave 2 already fixed and
        // what the chart now joins.
        let lunchDinner = try #require(facts.facts?.lunchDinner)
        #expect(lunchDinner.lunchCents == 7_500)
        #expect(lunchDinner.dinnerCents == 39_800)
        #expect(lunchDinner.lunchCents + lunchDinner.dinnerCents == 47_300)
    }

    /// With no rate policy on file the page is `.off`: the same cents either
    /// way, and only "tips" is an honest name for them. The chart follows,
    /// and its labels come out the same on both paths — `.off` is the one
    /// state `EarningsFigure.earnedIncome` already collapsed.
    @Test("a wages-off page charts tips, and no bar says Total")
    func aWagesOffPageChartsTips() throws {
        let now = at(2026, 10, 3, hour: 9)
        let facts = pageFacts(wageCompleteFixture(), policies(rateCents: nil), now: now)

        #expect(facts.basis == .nonWageEarnings(.wagesOff))
        #expect(facts.chartFacts.metric == .nonWageEarnings)
        #expect(facts.chartFacts.points.map(\.cents) == [10_500, 9_000, 7_500, 9_800, 10_500])
        #expect(facts.chartFacts.points.allSatisfy { !$0.figure.mayBeCalledATotal })
        #expect(facts.hourly == nil)
    }

    /// No dataset: no basis, no bars, no rate, and nothing that could render
    /// `$0.00` (contract rule 4).
    @Test("an unbacked page states no basis and draws no bar")
    func anUnbackedPageRefuses() {
        let facts = pageFacts([], policies(rateCents: 2_000), now: at(2026, 10, 3, hour: 9))

        #expect(facts.basis == .unavailable)
        #expect(facts.basis.note == nil)
        #expect(facts.facts == nil)
        #expect(facts.hourly == nil)
        #expect(facts.chartFacts.points.isEmpty)
    }
}

/// **One window, read by both sides of the HOURLY tile's own caption.**
///
/// The caption is a coverage claim ("across 5 of 6 shifts") sitting next to
/// tiles whose sample counts come from `StatsEngine.insightsFacts`. If the
/// tile's denominator and its neighbours' counts are computed over different
/// windows, the grid is two answers to one question.
@Suite("Insights window agreement")
struct InsightsWindowAgreementTests {
    private func hoursShift(_ date: Date, _ index: Int) -> TipEntry {
        TipEntry(date: date, amountCents: 5_000, kind: .credit, hoursWorked: 4,
                 shiftPeriod: .dinner, shiftID: shiftID(index))
    }

    /// The reference instant both windows are measured back from, at 09:00 —
    /// deliberately not midnight, because the two bounds that disagreed only
    /// disagree when the reference has a time of day.
    private let now = at(2026, 10, 3, hour: 9)

    /// **The upper edge.** `insightsFacts` had no upper bound at all, so a
    /// future-dated shift was in the engine's sample and outside the tile's
    /// range: the engine held 6 shifts where `hourly.totalShiftCount` held 5.
    @Test("a future-dated shift is outside both windows, not just the tile's")
    func theUpperEdgeAgrees() throws {
        var entries = wageCompleteFixture()
        entries.append(hoursShift(at(2027, 1, 15), 9))
        let set = dataset(entries, policies(rateCents: 2_000))
        let facts = pageFacts(entries, policies(rateCents: 2_000), now: now)

        let range = InsightsEarnings.recentRange(referenceDate: now, in: PaydayTestZone.payroll)
        let window = insightsEngine(set).recentWindow(referenceDate: now)
        #expect(!range.contains(CivilDay(at(2027, 1, 15), in: PaydayTestZone.payroll)))
        #expect(!window.contains(at(2027, 1, 15)))

        // Still in the DATASET — the cutoff is a query argument, never a
        // property of the data (`InsightsAsOfTests`).
        #expect(try #require(set.snapshot).shifts.count == 6)

        let engineShiftCount = try #require(facts.facts?.shiftCount)
        let hourly = try #require(facts.hourly)
        #expect(engineShiftCount == hourly.totalShiftCount)
        #expect(engineShiftCount == 5)
        #expect(hourly.coverage == "across 5 shifts")
    }

    /// **The lower edge.** `insightsFacts` cut at `referenceDate - 180 days`
    /// as an INSTANT, with no `startOfDay`, so a shift on the boundary day
    /// but earlier in the clock than the reference was inside the tile's
    /// range and outside the engine's: the engine held 5 where the tile
    /// held 6. 2026-04-06 is exactly 180 civil days before 2026-10-03.
    @Test("a shift on the boundary day before the reference hour is inside both windows")
    func theLowerEdgeAgrees() throws {
        var entries = wageCompleteFixture()
        entries.append(hoursShift(at(2026, 4, 6, hour: 8), 9))
        let set = dataset(entries, policies(rateCents: 2_000))
        let facts = pageFacts(entries, policies(rateCents: 2_000), now: now)

        let range = InsightsEarnings.recentRange(referenceDate: now, in: PaydayTestZone.payroll)
        let window = insightsEngine(set).recentWindow(referenceDate: now)
        #expect(range.start == CivilDay(at(2026, 4, 6), in: PaydayTestZone.payroll))
        #expect(range.contains(CivilDay(at(2026, 4, 6), in: PaydayTestZone.payroll)))
        #expect(window.contains(at(2026, 4, 6, hour: 8)))
        #expect(window.lowerBound == at(2026, 4, 6, hour: 0))

        let engineShiftCount = try #require(facts.facts?.shiftCount)
        let hourly = try #require(facts.hourly)
        #expect(engineShiftCount == hourly.totalShiftCount)
        #expect(engineShiftCount == 6)
    }

    /// Both edges at once — the shape a real history has. The two errors used
    /// to cancel in the COUNT here (6 against 6 for different reasons), which
    /// is exactly why each edge gets its own test above.
    @Test("with both edges present the engine and the tile select the same shifts")
    func bothEdgesAgree() throws {
        var entries = wageCompleteFixture()
        entries.append(hoursShift(at(2027, 1, 15), 9))
        entries.append(hoursShift(at(2026, 4, 6, hour: 8), 10))
        let set = dataset(entries, policies(rateCents: 2_000))
        let facts = pageFacts(entries, policies(rateCents: 2_000), now: now)

        #expect(try #require(set.snapshot).shifts.count == 7)
        let engineShiftCount = try #require(facts.facts?.shiftCount)
        let hourly = try #require(facts.hourly)
        #expect(engineShiftCount == hourly.totalShiftCount)
        #expect(engineShiftCount == 6)
    }

    /// The window's upper bound is the end of TODAY, not the reference
    /// instant: a shift logged at 11pm must not drop out of the sample
    /// because the page happened to be rendered at 9am.
    @Test("a shift later today is in the window the page was rendered at 9am with")
    func todayIsWholeInTheWindow() throws {
        var entries = wageCompleteFixture()
        entries.append(hoursShift(at(2026, 10, 3, hour: 23), 9))
        let set = dataset(entries, policies(rateCents: 2_000))
        let facts = pageFacts(entries, policies(rateCents: 2_000), now: now)

        let window = insightsEngine(set).recentWindow(referenceDate: now)
        #expect(window.contains(at(2026, 10, 3, hour: 23)))
        #expect(window.upperBound == at(2026, 10, 4, hour: 0))

        let engineShiftCount = try #require(facts.facts?.shiftCount)
        let hourly = try #require(facts.hourly)
        #expect(engineShiftCount == hourly.totalShiftCount)
        #expect(engineShiftCount == 6)
    }
}


/// The second "overall $/hr" that survived the migration, and what its copy
/// now says about its own scope.
///
/// `rateLeaderMove` compares one weekday's blended $/hr against the blended
/// $/hr of ALL history — every Move in `StatsEngine` is all-history by
/// design, and both sides of that one sentence are — while the HOURLY tile
/// beside it is `EarningsResult.hourlyRateCents` over the 180-day
/// `InsightsEarnings.recentRange`.
/// `InsightsPresentation.redundantMetricIDs(for:)` only ever excludes the
/// `startTimes` tile, so for anyone with more than 180 days of history the
/// Move and the tile render together and differ, both naming an hourly rate.
/// The Move names its scope, which makes them two answers to two questions
/// instead of two answers to one.
@Suite("Insights rate scope copy")
struct InsightsRateScopeTests {
    /// The lopsided-hours shape `StatsEngineTests.rateLeaderFires` uses: a
    /// wide $/hr gap with a narrow $/night gap, so this fixture isolates
    /// `rateLeader` rather than collapsing into `weekdaySwap`. Tuesday leads,
    /// which is the expected-rank inversion the obviousness law allows.
    private func rateLeaderFixture() -> [TipEntry] {
        var entries: [TipEntry] = []
        var index = 0
        for week in 0..<3 {
            index += 1
            entries.append(
                TipEntry(date: at(2026, 9, 1 + week * 7), amountCents: 10_000, kind: .credit,
                         hoursWorked: 2, shiftPeriod: .dinner, shiftID: shiftID(index))
            )
            index += 1
            entries.append(
                TipEntry(date: at(2026, 9, 5 + week * 7), amountCents: 9_500, kind: .credit,
                         hoursWorked: 5, shiftPeriod: .dinner, shiftID: shiftID(index))
            )
        }
        return entries
    }

    @Test("the rateLeader Move names the scope its overall rate is measured over")
    func theMoveNamesItsScope() throws {
        let now = at(2026, 9, 25, hour: 9)
        let entries = rateLeaderFixture()
        let facts = pageFacts(entries, policies(rateCents: 2_000), now: now)
        let move = try #require(
            facts.moves.first { $0.id == "rateLeader" },
            "the fixture stopped producing the Move this test is about"
        )

        #expect(move.body.contains("/hr across all your history."))
        #expect(!move.body.contains("/hr overall."))
        // The figure itself is unchanged — this is a scope DISCLOSURE, not a
        // recomputation. Both sides of the Move's comparison stay
        // all-history, because moving one of them would put a scope seam
        // inside a single sentence.
        let overall = try #require(
            insightsEngine(dataset(entries, policies(rateCents: 2_000))).averageDollarsPerHour()
        )
        let token = Money.wholeDollarString(fromCents: Int((overall * 100).rounded()))
        #expect(move.body.contains("\(token)/hr across all your history."))
    }

    /// **Why the disclosure is needed:** the two rates really are different
    /// numbers, so an unqualified "overall" on one of them was a second
    /// answer to the tile's question.
    ///
    /// MEASURED on a history split across the 180-day boundary, at
    /// $20.00/hr: the recent half runs $70.00/hr and the older half
    /// $39.00/hr, so the tile's 180-day rate and the Move's all-history rate
    /// cannot coincide.
    @Test("the Move's all-history rate and the HOURLY tile's window rate differ")
    func theTwoScopesDiffer() throws {
        let now = at(2026, 9, 25, hour: 9)
        var entries = rateLeaderFixture()
        // Older than `recentRange`, which starts 2026-03-29 for this `now`.
        for week in 0..<3 {
            entries.append(
                TipEntry(date: at(2025, 11, 4 + week * 7), amountCents: 9_500, kind: .credit,
                         hoursWorked: 5, shiftPeriod: .dinner, shiftID: shiftID(20 + week))
            )
        }
        let set = dataset(entries, policies(rateCents: 2_000))
        let snapshot = try #require(set.snapshot)
        let facts = pageFacts(entries, policies(rateCents: 2_000), now: now)

        let range = InsightsEarnings.recentRange(referenceDate: now, in: PaydayTestZone.payroll)
        #expect(!range.contains(CivilDay(at(2025, 11, 4), in: PaydayTestZone.payroll)))

        let tileRateCents = try #require(facts.hourly).rateCents
        #expect(tileRateCents == snapshot.range(range, asOf: CivilDay.distantFuture).hourlyRateCents)

        let allHistory = try #require(insightsEngine(set).averageDollarsPerHour())
        let allHistoryCents = Int((allHistory * 100).rounded())
        #expect(tileRateCents != allHistoryCents,
                "if the two scopes ever coincide this fixture stopped testing anything")
    }
}
