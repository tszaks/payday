import Foundation

/// How Insights gets its money, and the ONE basis decision the whole page
/// then stands on.
///
/// PR 5 groups 2.6 and 2.7, wave 2. A `DashboardEarnings`/`HistoryEarnings`
/// sibling — a snapshot plus the shift grouping whose `shiftID`s index it —
/// with one extra job those two do not have, because Insights is the only
/// screen that does not render engine totals directly.
///
/// ## The defect this file exists to close
///
/// `InsightsView` built its `StatsEngine` with no wage rate at all, so every
/// fact, chart point, typical range, trend, forecast and Move on the page was
/// `ShiftFacts.netCents` — `nonWageEarnings` — while the headlines above them
/// (and the hero on every other screen) are wage-inclusive `earnedIncome`.
/// `docs/METRICS.md` rows [IL-01] through [IL-27] all carry "basis
/// nonWageEarnings" for exactly that reason. Tyler's decision: **anything
/// labelled earnings or Total is wage-inclusive; a tips-only figure must be
/// labelled Tips.**
///
/// So the page needs two things this type supplies:
///
/// 1. **A total pricing of every shift on one basis** (`pricing(_:_:)`), fed
///    to `StatsEngine` so its own comparisons are internally consistent. The
///    engine is handed records, not policies; only a caller holding an
///    `EarningsSnapshot` can price a shift, because a shift's wage is a
///    property of its whole WORKWEEK (overtime and the ledger's cumulative
///    rounding), which is why this is passed in rather than computed there.
/// 2. **A declared basis** (`InsightsBasis`), stated on screen once, so no
///    comparison on the page is silently mixing wage-complete with
///    wage-incomplete observations.
///
/// ## Why the basis is a PAGE decision and not a per-figure one
///
/// The plan's rule is that "a comparison that would mix wage-complete with
/// wage-incomplete observations either excludes the incomplete ones or falls
/// back to `nonWageEarnings` and SAYS SO in its copy." Insights takes the
/// fall-back branch, for the whole page at once, and the reason is measurable
/// rather than aesthetic:
///
/// - **Excluding the incomplete shifts would falsify every sample size.** This
///   page's honesty device is the count under each number ("across 7 shifts",
///   "8 Fridays", "half your shifts land in these ranges"). Dropping the
///   shifts that have no logged hours changes every one of those counts and
///   can drop the page back under `StatsEngine.minimumShiftsForInsights`,
///   which would make a *missing hours entry* hide insights the person had
///   yesterday.
/// - **A per-figure decision is a hand-maintained list**, the same complaint
///   the adapter contract's rule 3 makes about `XFactsKey`. Thirty figures
///   each choosing their own basis is thirty chances to choose differently;
///   one decision, declared once, is checkable.
///
/// The fall-back is therefore all-or-nothing: **either every figure on the
/// page includes wages, or none of them do and the page says so.** A shift
/// missing from the pricing map is not "priced as tips" — it collapses the
/// whole page to tips, because a map with a hole in it is precisely the mixed
/// basis this is here to prevent.
///
/// ## Two bases that deliberately do NOT follow the page
///
/// `TIP PERCENT`, `SPEND / GUEST`, `TIPS / TABLE` and `CASH NIGHTS` stay on
/// tips: a wage is not a tip, so "tipped 16.7% of sales" and "$10.40 in tips
/// per table" would be false if a wage were folded in. Each one names its own
/// basis in its own caption ("of sales", "net tips · confirmed tables", "of
/// Friday tips are cash"), which is the same rule satisfied locally rather
/// than by the page note.
///
/// ## The same `asOf` and policy discipline as wave 1
///
/// Unclamped dataset (`asOf: .distantFuture`), the whole `CompensationPolicies`
/// value, and the grid calendar in the frozen payroll zone. Before wave 2 this
/// screen built its snapshot through `LegacySnapshotBridge.snapshot(entries:)`
/// with `asOf: now` — the convenience overload, whose `ShiftDays.groupedByShift`
/// call takes the DEFAULT `Calendar.current`. Both are defects wave 1 already
/// paid for on Dashboard (`DashboardEarnings`'s header has the measurements):
/// a device-zone grouping under a payroll-zone valuation mints different
/// `shiftID`s for a legacy nil-`shiftID` row, and a dataset-level cutoff makes
/// this screen a different DATASET from every other one, so a disagreement
/// stops being diffable.
///
/// **This is the PR 2 slice S7 swap point for group 2.6.** When something
/// finally writes `ShiftRecord` locally, `build` becomes
/// `earningsStore.snapshot` and nothing above it changes.
enum InsightsEarnings {
    // MARK: - The dataset

    /// - Parameters:
    ///   - records: every local `ShiftRecord`. Whole history, not a window:
    ///     the ledger allocates the overtime threshold across the complete
    ///     workweek of the shifts it is handed, so a windowed slice cannot
    ///     price the forty-first hour of a week that began before the window.
    ///     The recent-window scoping Insights applies is a QUERY argument
    ///     (`recentRange(...)`), never a property of the dataset.
    ///   - policies: `PolicyStore.policies`, whole. Never a scalar rate and
    ///     never a scalar weekday — wave 0 measured $520.00/`.complete`
    ///     against the correct $440.00/`.estimated` when a scalar rate became
    ///     a `.distantPast` confirmed policy, and this screen was one of the
    ///     two that read `latestCalendarPolicy` (which is `calendars.last`,
    ///     a QUEUED FUTURE policy) while Period detail read the pay-period
    ///     GRID's weekday, so the two allocated overtime into different weeks
    ///     over the same days.
    /// **The one entry point.** `ShiftRecord`s — the only stored shape since
    /// the flip — in, one dataset out. `StatsEngine` still wants rows, so
    /// `StatsRecordAdapter` shapes one record into the one or two rows it
    /// came from while the snapshot is built from the records directly
    /// through `ShiftInputAdapter` — the same adapter every other screen
    /// uses, so Insights and Dashboard cannot price the same shift
    /// differently.
    ///
    /// `shiftIDs` comes from the records rather than from the snapshot, on
    /// purpose. `pricing` asks "is every shift the ENGINE holds priced by
    /// the snapshot", so the question has to be asked of the engine's own
    /// set; reading the ids back off the snapshot would make the check
    /// tautological and it would pass while the page mixed bases, which is
    /// the one thing it exists to catch.
    @MainActor
    static func build(
        records: [ShiftRecord],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone
    ) -> Dataset {
        let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
        let snapshot = try? EarningsSnapshot.build(EarningsInputs(
            shifts: adapted.inputs,
            rates: policies.rates,
            calendars: policies.calendars,
            // Unclamped, for the reason the legacy build above records: this
            // page has never applied a to-date cutoff, and saying so once in
            // the stamp beats passing it at every query site.
            asOf: CivilDay(.distantFuture, in: payrollTimeZone),
            unreadableReceiptShiftIDs: adapted.unreadableReceiptShiftIDs
        ))
        return Dataset(
            snapshot: snapshot,
            tipRecords: StatsRecordAdapter.tipRecords(from: records),
            shiftIDs: records.map(\.id)
        )
    }

    /// A snapshot and the grouping whose `shiftID`s index it.
    ///
    /// Internal rather than private for the reason `DashboardEarnings.Dataset`
    /// is: the plan's completion rule 2 is "its parity test passes against the
    /// real adapter, not a helper", and a test that rebuilds this by hand is a
    /// test that can share the view's mistake.
    struct Dataset {
        /// Nil only when the inputs could not be canonically fingerprinted,
        /// which is a refusal and renders as unavailable, never as `$0.00`.
        let snapshot: EarningsSnapshot?
        /// The rows `StatsEngine` analyses, already flattened out of
        /// whichever representation built this dataset.
        ///
        /// Rows rather than the raw grouping, and `TipRecord` rather than
        /// `TipEntry`, so that **no consumer can tell which representation
        /// is underneath**. That is the whole point: this page reads the
        /// legacy side before the server converts an account and the new
        /// side after, and a consumer that could see the difference is a
        /// consumer that could be switched half-way. The measured cost of
        /// letting a caller reach past the builder is on the record — the
        /// direct `entries:` call this type used to expose is exactly how
        /// `PeriodsView` and this screen stayed unswitched while every
        /// parity gate passed.
        let tipRecords: [TipRecord]
        /// Every shift id in the grouping the snapshot was built from, for
        /// `pricing`'s totality check. Order is the grouping's: newest day
        /// first, lunch before dinner.
        let shiftIDs: [UUID]
    }

    // MARK: - The basis

    /// The page's one basis decision, derived from the dataset's own
    /// `Completeness` and nothing else.
    ///
    /// - nil snapshot → `.unavailable`: no dataset stands behind the page, so
    ///   every figure renders as unavailable rather than as zero (contract
    ///   rule 4).
    /// - `.noShifts` → `.unavailable` for the same reason: there is nothing to
    ///   state a basis about, and the pre-unlock empty state is what renders.
    /// - `.off` → tips only, because with wages off `earnedIncome` and
    ///   `nonWageEarnings` are the same cents and only the second one is an
    ///   honest NAME for them.
    /// - `.complete` / `.estimated` → wage-inclusive, `.estimated` carrying
    ///   `CompletenessCopy.caption`.
    /// - `.partial` → tips only, and the note says how many shifts are
    ///   missing what. This is the fall-back branch; see the type header for
    ///   why it is the whole page rather than the offending comparisons.
    static func basis(for snapshot: EarningsSnapshot?) -> InsightsBasis {
        guard let snapshot else { return .unavailable }
        switch snapshot.completeness.state {
        case .noShifts:
            return .unavailable
        case .off:
            return .nonWageEarnings(.wagesOff)
        case .complete:
            return .earnedIncome(assumed: false)
        case .estimated:
            return .earnedIncome(assumed: true)
        case .partial(let missingHours, let missingRate):
            return .nonWageEarnings(
                .incomplete(missingHours: missingHours, missingRate: missingRate)
            )
        }
    }

    /// The ledger's `earnedIncome` for every shift in the dataset, or nil.
    ///
    /// Nil means "price on tips", which is `StatsEngine`'s own default and
    /// therefore byte-identical to what this page showed before wave 2. It is
    /// returned in three cases, all of them the same rule: there is no honest
    /// wage-inclusive basis to be on.
    ///
    /// 1. The basis is not wage-inclusive (`.off`, `.partial`, `.unavailable`).
    /// 2. There is no snapshot.
    /// 3. **The map would not be total over the grouping.** Every group in
    ///    `dataset.shiftDays` is a shift `StatsEngine` will hold and price, so
    ///    every one of them has to be in the map. A valuation missing for any
    ///    one of them would leave the engine pricing that shift on tips and
    ///    its neighbours on earned income, which is exactly the mixed basis
    ///    this file exists to prevent — so the page collapses to tips rather
    ///    than half-pricing itself.
    ///
    ///    That is a reachable state and not just a paranoid guard:
    ///    `LegacySnapshotBridge.snapshot(shifts:)` **`compactMap`s** its
    ///    groups through `LegacyLedgerBridge.shiftInput`, so a group that
    ///    cannot produce a `ShiftInput` is silently absent from the snapshot
    ///    while remaining present in the engine's records.
    ///
    ///    The other half of totality is that the two sides agree on a shift's
    ///    ID at all. They do only because the view builds `StatsEngine` with
    ///    the same grid calendar `build` grouped with: a legacy `TipEntry`
    ///    with `shiftID == nil` takes a `ShiftDays.deterministicShiftID`
    ///    derived from `calendar.startOfDay(...)`, so a device-zone grouping
    ///    under a payroll-zone engine mints two different ids for one shift.
    ///    `InsightsPricingTotalityTests` pins that agreement on a nil-`shiftID`
    ///    row across two zones.
    ///
    ///    This is where the guarantee has to live: `StatsEngine.cents(of:)`
    ///    sees one shift at a time and has no second basis to fall the whole
    ///    engine back to, so a partial map there is a silently mixed
    ///    comparison.
    static func pricing(_ basis: InsightsBasis, _ dataset: Dataset) -> [UUID: Int]? {
        guard basis.isWageInclusive, let snapshot = dataset.snapshot else { return nil }
        var priced: [UUID: Int] = [:]
        priced.reserveCapacity(snapshot.shifts.count)
        for valuation in snapshot.shifts {
            priced[valuation.id] = valuation.components.earnedIncomeCents
        }
        for shiftID in dataset.shiftIDs where priced[shiftID] == nil {
            return nil
        }
        return priced
    }

    // MARK: - The engine

    /// **The page's `StatsEngine`, built in ONE place.**
    ///
    /// The same records the snapshot saw (flattened out of the same grouping,
    /// so the engine and the snapshot cannot be looking at two different sets
    /// of rows), the same grid calendar, and the pricing this dataset's own
    /// basis produced.
    ///
    /// It is a function rather than a construction inlined in
    /// `InsightsPageFacts.init` because of a measured gate failure. The parity
    /// suite used to rebuild this wiring in a private `pageEngine(_:)` helper
    /// of its own — "a test that rebuilds this by hand is a test that can
    /// share the view's mistake", which `Dataset`'s header already says — and
    /// with `valuedShiftCents` patched to nil in the VIEW, reverting the whole
    /// page to tips-only under wage-inclusive headers, the full app suite
    /// still reported `Test run with 855 tests in 154 suites passed`. Nothing
    /// in 855 tests noticed the screen had stopped reading the snapshot.
    /// Both the view and the suite call this now, so that patch fails.
    ///
    /// The basis is computed HERE from the dataset rather than passed in. A
    /// `basis:` parameter would let a caller hand the engine one basis while
    /// the page declared another, which is the mixed basis this whole file
    /// exists to prevent; `basis(for:)` is pure, so computing it twice (here,
    /// and once more for the note) cannot produce two answers.
    static func engine(
        for dataset: Dataset,
        payrollTimeZone: TimeZone,
        calendar: Calendar
    ) -> StatsEngine {
        StatsEngine(
            payrollTimeZone: payrollTimeZone,
            records: dataset.tipRecords,
            calendar: calendar,
            // The ledger's `earnedIncome` per shift, or nil to leave every
            // figure on tips. Never a scalar `wageCentsPerHour`: that prices
            // a shift in isolation, so it rounds per shift and carries no
            // workweek overtime. This one argument is the whole of group
            // 2.6's fix — every fact, range, trend, forecast and Move below
            // moves onto the same basis as the chart above them.
            valuedShiftCents: pricing(basis(for: dataset.snapshot), dataset)
        )
    }

    // MARK: - Queries

    /// The civil days `StatsEngine.insightsFacts` selects, as a range on the
    /// snapshot.
    ///
    /// The engine's own window is `StatsEngine.recentWindow(referenceDate:)`,
    /// a half-open interval of INSTANTS: `[startOfDay(reference) - 180 days,
    /// startOfDay(reference) + 1 day)`. This is the same 181 civil days
    /// expressed as the `DayRange` the snapshot selects by, in the FROZEN
    /// payroll zone — the zone the engine already buckets in — so the two
    /// select the same shifts.
    ///
    /// It exists so the HOURLY tile can be the snapshot's own
    /// `hourlyRateCents` over the SAME scope the rest of the grid covers. A
    /// tile fed the whole-history rate under a grid whose neighbours describe
    /// the last 180 days would be a scope change wearing a basis fix.
    ///
    /// **Both bounds are load-bearing, and both were once wrong.** Before
    /// this was pinned, `insightsFacts` filtered `$0.date >= referenceDate -
    /// 180 days` with no upper bound at all and no `startOfDay`, so two edges
    /// disagreed with this range and the HOURLY tile's denominator described a
    /// different set of shifts from the counts printed beside it:
    ///
    /// - a shift dated 2027-01-15 was inside the engine's window and outside
    ///   this one, so the engine held 6 shifts where the tile held 5;
    /// - with `referenceDate` at 2026-10-03 09:00, a shift on 2026-04-06 at
    ///   08:00 — the 180-day boundary DAY, earlier in the clock than the
    ///   reference instant — was inside this range and outside the engine's.
    ///
    /// The HOURLY caption is precisely a coverage claim ("across 5 of 6
    /// shifts"), so a denominator over a different window from the counts next
    /// to it is two answers to one question.
    /// `InsightsWindowAgreementTests` measures both edges.
    static func recentRange(
        referenceDate: Date,
        in payrollTimeZone: TimeZone,
        windowDays: Int = StatsEngine.insightsRecentWindowDays
    ) -> DayRange {
        let today = CivilDay(referenceDate, in: payrollTimeZone)
        return DayRange(start: today.adding(days: -windowDays), end: today)
    }

    /// `MetricID.hourlyRate` for the page's recent window: the engine's own
    /// rate, with the coverage it can honestly claim.
    ///
    /// Nil when the engine cannot answer (no covered minutes) or there is no
    /// snapshot — never a fabricated `$0/hr`, which is the registry's "nil
    /// without coverage".
    ///
    /// **Why this replaces `RateFacts.overallDollarsPerHour` on the tile.**
    /// [IL-13] records the old tile as "nonWage/hour" against a registry
    /// `hourlyRate` that is `earnedIncome`-based, and the old denominator was
    /// `nightsWithHours` — a COUNT of shifts, used only to hedge the caption,
    /// while the rate itself was a per-shift average of per-shift rates. The
    /// engine's `hourlyRateCents` is `coveredComponents` over `minutes`, both
    /// taken over the covered shifts only, so a shift with tips and no hours
    /// is excluded from BOTH sides instead of inflating the numerator. That is
    /// the same fix History's `$/hr` caption got in wave 1, and the caption
    /// formatter is shared with it rather than written a second time.
    static func hourlyRate(
        _ snapshot: EarningsSnapshot?,
        referenceDate: Date,
        in payrollTimeZone: TimeZone
    ) -> HourlyRate? {
        guard let snapshot else { return nil }
        let result = snapshot.range(
            recentRange(referenceDate: referenceDate, in: payrollTimeZone),
            asOf: CivilDay.distantFuture
        )
        guard let rateCents = result.hourlyRateCents else { return nil }
        return HourlyRate(
            rateCents: rateCents,
            coveredShiftCount: result.coveredShiftCount,
            totalShiftCount: result.completeness.totalShifts
        )
    }

    /// The HOURLY tile's value and its coverage, from one `EarningsResult`.
    struct HourlyRate: Equatable {
        let rateCents: Int
        /// Shifts with hours logged — the rate's actual denominator.
        let coveredShiftCount: Int
        /// Shifts in the window, covered or not.
        let totalShiftCount: Int

        /// "across 4 of 5 shifts", or "across 5 shifts" when the rate speaks
        /// for all of them.
        ///
        /// `docs/METRICS.md`'s presentation rules say `.partial` "makes $/hr
        /// show 'N of M shifts'". With full coverage, "5 of 5 shifts" is a
        /// sentence that adds no fact, so the fraction appears only when there
        /// is a shortfall to disclose — the same rule
        /// `HistoryEarnings.hourlyRateCaption` applies to the same metric.
        var coverage: String {
            guard coveredShiftCount < totalShiftCount else {
                return "across \(CompletenessCopy.shiftCount(coveredShiftCount))"
            }
            return "across \(coveredShiftCount) of \(CompletenessCopy.shiftCount(totalShiftCount))"
        }
    }
}

/// What basis every money figure on Insights is on, stated once.
///
/// Not an `EarningsFigure`: almost nothing on Insights is a range query. A
/// typical range is a percentile, a trend is a difference of two windows' per
/// shift means, a Move is a two-sided comparison, the plan is a forecast.
/// `EarningsFigure` deliberately refuses to be constructed from a bare `Int`
/// precisely so a screen cannot launder its own arithmetic into one, and an
/// analytic derivation is not something the engine answered — so the figures
/// that ARE engine answers on this page render as `EarningsFigure` (every
/// chart bar, via `EarningsChartPoint.figure`) and the derivations carry this
/// instead: the name of the metric they are derived FROM, and the sentence
/// that says so on screen.
enum InsightsBasis: Equatable {
    /// No dataset. Every figure refuses; the page renders its empty state.
    case unavailable
    /// Wage-inclusive. `assumed` when some shift's rate rests on the legacy
    /// setting rather than a confirmed policy.
    case earnedIncome(assumed: Bool)
    case nonWageEarnings(Reason)

    enum Reason: Equatable {
        /// The wage feature is off, so there are no wages to include.
        case wagesOff
        /// Some shift could not be priced, so including wages would compare a
        /// wage-complete shift against a wage-incomplete one.
        case incomplete(missingHours: Int, missingRate: Int)
    }

    var isWageInclusive: Bool {
        if case .earnedIncome = self { return true }
        return false
    }

    /// The chart's basis, which is the PAGE's.
    ///
    /// The chart is the one surface on Insights that renders engine answers
    /// directly rather than a derivation of them, so it takes the basis as an
    /// `EarningsChartMetric` instead of as a sentence. Wave 2 shipped without
    /// this and measured the consequence: `EarningsChartPoint` was
    /// `EarningsFigure.earnedIncome` unconditionally, so on a `.partial`
    /// dataset the bars read 26,500c / 24,000c / 7,500c / 25,800c / 25,500c
    /// over the same five days every other figure on the page read 10,500c /
    /// 9,000c / 7,500c / 9,800c / 10,500c — under a note reading "Every
    /// figure below is tips only" and bar labels reading "Total".
    ///
    /// `.unavailable` maps to `.nonWageEarnings` and it does not matter which
    /// it maps to: with no dataset the chart yields no points at all.
    var chartMetric: EarningsChartMetric {
        isWageInclusive ? EarningsChartMetric.earnedIncome : EarningsChartMetric.nonWageEarnings
    }

    /// Which registry metric the page's figures are derived from, so a copy
    /// test can assert the note and the numbers name the same one.
    var metric: MetricID? {
        switch self {
        case .unavailable: return nil
        case .earnedIncome: return .earnedIncome
        case .nonWageEarnings: return .nonWageEarnings
        }
    }

    /// The one sentence the page prints above its money, or nil when there is
    /// no money to qualify.
    ///
    /// Said once rather than thirty times, the same call `InsightsView` already
    /// makes for the interquartile qualifier: "Said once here instead of five
    /// times below. " Five near-identical hedges read as a form letter and ate
    /// the whole first screen.
    var note: String? {
        switch self {
        case .unavailable:
            return nil
        case .earnedIncome(let assumed):
            let base = "Every figure below includes your hourly wages."
            guard assumed, let caption = CompletenessCopy.caption(.estimated) else { return base }
            return "\(base) \(caption)."
        case .nonWageEarnings(.wagesOff):
            return "Every figure below is tips only."
        case .nonWageEarnings(.incomplete(let missingHours, let missingRate)):
            // Names what is missing and for how many shifts, because that is
            // a fact someone can act on: logging the hours is what puts the
            // page back on wages. Hours first, for the same reason
            // `CompletenessCopy.caption(.partial)` puts them first — it is the
            // one the person can fix in the app. The plural spelling is that
            // file's `shiftCount`, so this page and every other one count
            // shifts in one vocabulary.
            let hours = CompletenessCopy.shiftCount(missingHours)
            let rate = CompletenessCopy.shiftCount(missingRate)
            let cause: String
            if missingHours > 0, missingRate > 0 {
                cause = "\(hours) have no hours logged and \(rate) have no rate set."
            } else if missingHours > 0 {
                cause = "\(hours) have no hours logged."
            } else if missingRate > 0 {
                cause = "\(rate) have no rate set."
            } else {
                // `.partial` with neither cause is unreachable from
                // `Completeness.state`, which derives both counts from the
                // same three tallies. Say something true rather than nothing.
                cause = "Some shifts could not be priced."
            }
            return "Every figure below is tips only. \(cause)"
        }
    }
}
