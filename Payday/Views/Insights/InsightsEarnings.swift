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
    ///   - entries: every local `TipEntry`. Whole history, not a window: the
    ///     ledger allocates the overtime threshold across the complete
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
    ///   - calendar: the GRID calendar in the frozen payroll zone
    ///     (`PayrollCalendar.gridCalendar(in:)`). It groups; it prices
    ///     nothing. It must be the same calendar `StatsEngine` is built with,
    ///     or the two mint different fallback ids for a nil-`shiftID` row and
    ///     `pricing(_:_:)` comes back incomplete.
    static func build(
        entries: [TipEntry],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        calendar: Calendar
    ) -> Dataset {
        let shiftDays = ShiftDays.groupedByShift(
            entries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod,
            calendar: calendar
        )
        return Dataset(
            snapshot: LegacySnapshotBridge.snapshot(
                shifts: shiftDays,
                policies: policies,
                payrollTimeZone: payrollTimeZone,
                // Unclamped, matching Dashboard, History, Calendar and the
                // log preview, so every screen's stamp is the same stamp.
                // Insights has never applied a to-date cutoff at all — the
                // all-history chart deliberately shows future-dated rows
                // (see `EarningsChartFacts.init(wholeOf:)`) — so there is no
                // cutoff to move to a query site here, only one to stop
                // baking into the data.
                asOf: .distantFuture
            ),
            shiftDays: shiftDays
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
        /// Newest day first, lunch before dinner — `ShiftDays`' order.
        let shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])]
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
        for group in dataset.shiftDays where priced[group.shiftID] == nil {
            return nil
        }
        return priced
    }

    // MARK: - Queries

    /// The civil days `StatsEngine.insightsFacts` selects, as a range on the
    /// snapshot.
    ///
    /// The engine's own window is `records.filter { $0.date >= referenceDate -
    /// insightsRecentWindowDays }`, which is a half-open interval on instants.
    /// This is the same window expressed in the civil days the snapshot
    /// selects by, in the FROZEN payroll zone — the zone the engine already
    /// buckets in, so the two select the same shifts.
    ///
    /// It exists so the HOURLY tile can be the snapshot's own
    /// `hourlyRateCents` over the SAME scope the rest of the grid covers. A
    /// tile fed the whole-history rate under a grid whose neighbours describe
    /// the last 180 days would be a scope change wearing a basis fix.
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
