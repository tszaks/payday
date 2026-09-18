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

/// The engine exactly as `InsightsPageFacts.init` builds it: the same records
/// the snapshot saw, the same grid calendar, and the pricing the page's own
/// basis decision produced.
private func pageEngine(
    _ set: InsightsEarnings.Dataset,
    payrollTimeZone: TimeZone = PaydayTestZone.payroll
) -> StatsEngine {
    StatsEngine(
        payrollTimeZone: payrollTimeZone,
        records: set.shiftDays.flatMap(\.items).map(TipRecord.init),
        calendar: PayrollCalendar.gridCalendar(in: payrollTimeZone),
        valuedShiftCents: InsightsEarnings.pricing(
            InsightsEarnings.basis(for: set.snapshot), set
        )
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

        let engineTotal = pageEngine(set).nightlyTotals()
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
            records: set.shiftDays.flatMap(\.items).map(TipRecord.init),
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
        let engineTotal = pageEngine(set).nightlyTotals()
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

            #expect(set.shiftDays.count == 3)
            for group in set.shiftDays {
                #expect(pricing[group.shiftID] != nil, "unpriced shift in \(zone.identifier)")
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
            pageEngine(set).insightsFacts(referenceDate: at(2026, 10, 3, hour: 9))
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
        let doubles = pageEngine(set).insightsFacts(referenceDate: at(2026, 10, 3, hour: 9))?.doublesSolo
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

        let priced = try #require(pageEngine(set).typicalRanges(referenceDate: now)?.overall)
        #expect(priced.lowCents == 26_000)
        #expect(priced.highCents == 26_000)

        let unpriced = StatsEngine(
            payrollTimeZone: PaydayTestZone.payroll,
            records: set.shiftDays.flatMap(\.items).map(TipRecord.init),
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

        let priced = try #require(pageEngine(set).planForward(referenceDate: now))
        let unpriced = try #require(
            StatsEngine(
                payrollTimeZone: PaydayTestZone.payroll,
                records: set.shiftDays.flatMap(\.items).map(TipRecord.init),
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

        let priced = try #require(pageEngine(set).insightsFacts(referenceDate: now)?.sales)
        let unpriced = try #require(
            StatsEngine(
                payrollTimeZone: PaydayTestZone.payroll,
                records: set.shiftDays.flatMap(\.items).map(TipRecord.init),
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
