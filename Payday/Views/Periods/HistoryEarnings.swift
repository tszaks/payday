import Foundation

/// How History's two screens get their money, in one place.
///
/// PR 5 group 2.4, wave 1. `PeriodsPageFacts` and `PeriodDetailFacts` are two
/// scopes of the same question — "what did this pay period earn" — and before
/// this file they answered it through two different helper chains
/// (`TipBreakdown` + `StatsEngine.nightlyTotals` + `PeriodIncome` on the list,
/// a third composition on the detail) and matched a paycheck to a period by
/// two different rules. A row and the screen it opened could therefore
/// disagree, which is the parity invariant PR 5 exists to close:
/// **the History row equals period detail equals that period's range query.**
///
/// Everything here is selection and date math. No cents are added anywhere in
/// this file: the figures come from `EarningsSnapshot` queries, and the one
/// paycheck comparison delegates to `PredictedPaycheck`, the app's single
/// stub formula.
enum HistoryEarnings {
    // MARK: - The snapshot

    /// One snapshot over the WHOLE local history, plus the shift grouping it
    /// was built from.
    ///
    /// Whole history, not the period's rows, and that is the fix rather than
    /// an accident. `CompensationLedger` allocates the overtime threshold
    /// over a complete WORKWEEK, so handing it one pay period's shifts makes
    /// a week that straddles the period boundary lose the overtime it
    /// produced (`docs/METRICS.md` HP-01, HP-15: "wages' weekly OT sees only
    /// this period's entries so a workweek straddling the period boundary
    /// under-counts OT"). One snapshot over everything, then a `range(_:)`
    /// query per period, is also what makes the list and the detail the same
    /// engine answering at two scopes.
    ///
    /// **This is the PR 2 S7 swap point for group 2.4.** Nothing writes
    /// `ShiftRecord` on a device yet, so `earningsStore.snapshot` is empty
    /// and a screen switched onto it today would show a person with years of
    /// shifts a blank page (`LegacySnapshotBridge`'s header has the
    /// measurement). When the shift sync leg lands, this function's body
    /// becomes `earningsStore.snapshot` and nothing below it changes.
    ///
    /// - Parameters:
    ///   - policies: `PolicyStore.policies`, whole. Never a scalar rate and
    ///     never a scalar weekday: wave 0 measured $520.00/`.complete`
    ///     against the correct $440.00/`.estimated` when a scalar rate became
    ///     a `.distantPast` confirmed policy, and two screens bucketing
    ///     overtime into different weeks when one read the pay-period GRID's
    ///     weekday. The engine does the effective dating.
    ///   - calendar: the GRID calendar, for shift grouping and period
    ///     boundaries. Presentation only; it prices nothing.
    /// The shift-representation build.
    ///
    /// This is the single switch point for four consumers -- `PeriodDetailView`,
    /// `DashboardEarnings`, `InsightsEarnings` and `PeriodsView` all reach
    /// their money through `HistoryEarnings.build`. Switching HERE rather than
    /// in each view is what keeps them from disagreeing: one source decision,
    /// four screens, no possibility of a half-switched surface.
    ///
    /// It also keeps the snapshot and the rows on the SAME representation. A
    /// screen whose total came from the engine while its rows came from the
    /// legacy store would show one figure over rows summing to something else
    /// under any bug -- which is criterion 5 broken by construction, on the
    /// most scrutinised screens in the app.
    @MainActor
    static func build(
        records: [ShiftRecord],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone
    ) -> Build {
        let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
        let snapshot = try? EarningsSnapshot.build(EarningsInputs(
            shifts: adapted.inputs,
            rates: policies.rates,
            calendars: policies.calendars,
            // The same no-cutoff decision the legacy build makes below, and
            // for the same recorded reason: HP-01 and HP-05 both say History
            // applies no to-date cutoff, and saying it ONCE in the snapshot's
            // own stamp beats passing `asOf: .distantFuture` at a dozen query
            // sites.
            asOf: CivilDay(.distantFuture, in: payrollTimeZone),
            unreadableReceiptShiftIDs: adapted.unreadableReceiptShiftIDs
        ))
        return Build(snapshot: snapshot, shiftDays: [], shiftRecordDays: records)
    }

    static func build(
        entries: [TipEntry],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        calendar: Calendar = .current
    ) -> Build {
        let shiftDays = ShiftDays.groupedByShift(
            entries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod,
            calendar: calendar
        )
        return Build(
            snapshot: LegacySnapshotBridge.snapshot(
                shifts: shiftDays,
                policies: policies,
                payrollTimeZone: payrollTimeZone,
                // History has never applied a to-date cutoff — HP-01 and
                // HP-05 both record "no asOf, future-dated entries inside
                // the current period are included". Saying that ONCE, as the
                // snapshot's own cutoff, is safer than passing
                // `asOf: .distantFuture` at a dozen query sites and having
                // one of them be forgotten: a missed override there is a
                // silent clamp, not an error.
                asOf: .distantFuture
            ),
            shiftDays: shiftDays,
            shiftRecordDays: []
        )
    }

    /// A snapshot and the grouping whose `shiftID`s index it.
    struct Build {
        /// Nil only when the inputs could not be canonically fingerprinted,
        /// which is a refusal and renders as unavailable, never as `$0.00`.
        let snapshot: EarningsSnapshot?
        /// Newest day first, lunch before dinner — `ShiftDays`' order, kept
        /// because it is what the rows render in.
        let shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])]
        /// The same rows in the shift representation. Exactly one of the two
        /// is ever populated, because `build` chooses a source rather than
        /// merging -- a converted shift exists in BOTH representations at
        /// once, so reading the union would count it twice.
        let shiftRecordDays: [ShiftRecord]
    }

    // MARK: - Queries

    /// A pay period's civil days, in the FROZEN payroll zone.
    ///
    /// `PayPeriodCalculator` already laid the boundaries out as midnights in
    /// that zone, so this is a re-reading of the same two days and not a
    /// second date rule.
    static func range(of period: PayPeriod, in payrollTimeZone: TimeZone) -> DayRange {
        DayRange(
            start: CivilDay(period.start, in: payrollTimeZone),
            end: CivilDay(period.end, in: payrollTimeZone)
        )
    }

    /// What a pay period earned, composed from `range(_:)`.
    ///
    /// **Composed, because the bridge's snapshot cannot attest a pay period.**
    /// `LegacySnapshotBridge` supplies no `EarningsInputs.schedule`, so
    /// `stamp.manifest` carries no schedule digest and nothing in the
    /// snapshot can tell a consumer that the pay-period GRID moved
    /// underneath it. `snapshot.payPeriod(_:)` would still return these exact
    /// cents — MEASURED: it and `range(_:)` are the same `ranged(...)` call
    /// with a different `EarningsScope` label — so the choice here is about
    /// honesty of scope, not arithmetic: this result says `.range`, which is
    /// all the dataset behind it can support. When PR 2 S7 lands and
    /// `EarningsStore` supplies the schedule, this becomes
    /// `snapshot.payPeriod(_:)` and the cents do not move.
    static func earnings(
        _ snapshot: EarningsSnapshot?,
        for period: PayPeriod,
        in payrollTimeZone: TimeZone
    ) -> EarningsResult? {
        guard let snapshot else { return nil }
        return snapshot.range(range(of: period, in: payrollTimeZone))
    }

    /// The `MetricID.hourlyRate` caption: "Averaging $2.83/hr · 4 of 5
    /// shifts".
    ///
    /// The whole point of routing this through `EarningsResult` is the
    /// DENOMINATOR. Period detail used to divide the period's entire
    /// wage-inclusive total by only the hours that were logged, so a shift
    /// with tips and no hours inflated the rate without appearing in it:
    /// fixture H1's two shifts read $40.00/hr instead of $20.00/hr.
    /// `result.hourlyRateCents` is `coveredComponents` over `minutes`, both
    /// taken over the covered shifts only, and `coveredShiftCount` is what
    /// lets the caption admit how much of the period it speaks for.
    ///
    /// Nil when the engine cannot answer (no covered minutes), which is the
    /// registry's "nil without coverage" — never a fabricated `$0/hr`.
    ///
    /// The coverage clause appears only when there is coverage to disclose.
    /// `docs/METRICS.md`, presentation rules: `.partial` "makes $/hr show
    /// 'N of M shifts'". With every shift covered, "5 of 5 shifts" is a
    /// sentence that adds no fact.
    static func hourlyRateCaption(_ result: EarningsResult?) -> String? {
        guard let result, let rateCents = result.hourlyRateCents else { return nil }
        let rate = "Averaging \(Money.string(fromCents: rateCents))/hr"
        let covered = result.coveredShiftCount
        let total = result.completeness.totalShifts
        guard covered < total else { return rate }
        return "\(rate) · \(covered) of \(total) shifts"
    }

    // MARK: - Paychecks

    /// The ONE rule matching a recorded paycheck to a pay period.
    ///
    /// The two History surfaces used two: the list bucketed by
    /// `calculator.period(containing: paycheck.periodEnd)` and took whichever
    /// record `@Query` happened to return first, while period detail took the
    /// first record whose `periodEnd` fell inside `[period.start,
    /// period.end]`. The two predicates agree — the calculator's periods
    /// partition the timeline — but "whichever came first" does not, because
    /// neither `@Query` declares a sort. So a period with two recorded checks
    /// could show one row's delta in the list and a different verdict on the
    /// screen that row opens.
    ///
    /// Ties break in `EarningsSnapshot`'s own canonical paycheck order
    /// (`periodEnd`, then `periodStart`, then id), so this picks the same row
    /// the engine's `paycheck(periodEnd:)` will pick once the bridge carries
    /// paychecks.
    static func paycheck(for period: PayPeriod, in records: [PaycheckRecord]) -> PaycheckRecord? {
        records
            .filter { $0.periodEnd >= period.start && $0.periodEnd <= period.end }
            .min {
                ($0.periodEnd, $0.periodStart, $0.id.uuidString)
                    < ($1.periodEnd, $1.periodStart, $1.id.uuidString)
            }
    }
}

/// A recorded paycheck next to what the engine expected for the same period.
///
/// One type for both History surfaces. The list row's "checked" delta
/// (HP-02..HP-04) and period detail's PAYCHECK verdict (HP-22..HP-24) are the
/// same comparison rendered with different chrome, and they were two
/// independently written implementations over two different bases — the row
/// summed `PredictedPaycheck.tipsLineCents(from: TipBreakdown)` while the
/// detail's `PaycheckComparisonView` recomputed its own from a breakdown the
/// view was handed. Both now read ONE `EarningsResult`.
///
/// **Closed by group 2.5, wave 2.** `MetricID.reconciliationDelta` asks for
/// the comparison per COMPONENT and `MetricID.observedPaidTips` asks for the
/// ±100c correction to be a proposal rather than a silent rewrite. Both now
/// live on `PaycheckReconciler`: this type's observed side is
/// `paycheck.paidTipsCents` verbatim, and the per-component deltas are on
/// `PaycheckReconciler.Reconciliation`. The whole-check figure below stays,
/// because it is the comparison these two surfaces render.
struct PeriodCheckComparison: Equatable {
    /// What this period's own `EarningsResult` says the stub's Tips and
    /// Gratuity lines should total.
    let expectedTipsAndGratuityCents: Int
    /// What the recorded check paid in tips and gratuity, as entered.
    let paidTipEarningsCents: Int
    /// Observed minus expected. Negative reads short, and in red.
    let deltaCents: Int
    /// Whether any credit tips were logged. With none, the period is almost
    /// certainly pre-cash/credit legacy data, so the comparison names the
    /// total rather than claiming a full card-tip overpay.
    let usesCreditOnly: Bool

    var isShort: Bool { deltaCents < 0 }

    /// Nil when no check has been recorded for the period, **and nil when no
    /// dataset stands behind the expectation.**
    ///
    /// Both guards, and the second one is rule 4. This used to read
    /// `result?.knownComponents ?? .zero`, so a nil snapshot still produced a
    /// full comparison against a ZERO expectation: MEASURED with one check
    /// paying 9500c and no snapshot, both surfaces returned
    /// `expectedTipsAndGratuityCents: 0, deltaCents: 9500, isShort: false`
    /// while every other figure on the same facts correctly refused. The
    /// History row printed "+$95.00" over "checked" in green beside an en-dash
    /// placeholder, and period detail printed "$95.00 over." over "Logged
    /// $0.00 · check paid $95.00" — a fabricated money verdict standing on no
    /// dataset, next to a literal `$0.00` for a figure the engine could not
    /// answer.
    ///
    /// Narrow today (a nil snapshot needs an `InputManifest.ValidationError`)
    /// and ordinary after the PR 2 S7 swap, where `EarningsStore` is
    /// `.loading` before its first build and `.unavailable` on a failed
    /// fetch: the green verdict would have rendered on the first frame of
    /// every cold launch.
    init?(result: EarningsResult?, paycheck: PaycheckRecord?) {
        guard let result, let paycheck else { return nil }
        // ONE expectation, built by the reconciler from this period's own
        // result. The sheet this period opens holds the same value, so the
        // expected side a person sees on the period and the expected side
        // the sheet audits against are one answer and not two that agree
        // (`PaycheckEntryFacts.expectedGross` reads the same property).
        let expectation = PaycheckReconciler.Expectation(result: result, stamp: nil)
        let components = result.knownComponents
        guard let expectedTipsAndGratuity = expectation.tipsAndGratuityCents else { return nil }
        expectedTipsAndGratuityCents = expectedTipsAndGratuity
        // `MetricID.observedPaidTips`: the stub field EXACTLY as stored.
        // This read was `paycheck.reconciledPaidTipsCents` until group 2.5,
        // which substituted the ±100c gross-equation inference — fixture P1
        // lists `periodsListPaidTipEarningsCents: 10050` and
        // `periodDetailCheckPaidCents: 10050` as wrong answers against a
        // stub that says 10000, and names 10000 as
        // `reconciliationObservedTipsSideCents`. The inference is now a
        // proposal the sheet offers (`PaycheckReconciler.Proposal`), so this
        // comparison reports the person's own figure.
        paidTipEarningsCents = PredictedPaycheck.paidTipEarningsCents(
            tipsCents: paycheck.paidTipsCents,
            gratuityCents: paycheck.gratuityCents
        )
        // `MetricID.reconciliationDelta`, the tips-and-gratuity component,
        // off the same reconciliation the sheet holds rather than a second
        // subtraction here.
        let reconciliation = PaycheckReconciler.Reconciliation(
            expectation: expectation,
            observation: PaycheckReconciler.Observation(
                paidTipsCents: paycheck.paidTipsCents,
                gratuityCents: paycheck.gratuityCents
            )
        )
        guard let delta = reconciliation.tipEarningsDeltaCents else { return nil }
        deltaCents = delta
        usesCreditOnly = components.voluntaryCreditCents > 0
    }
}
