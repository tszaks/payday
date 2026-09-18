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
            shiftDays: shiftDays
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

/// What `PaycheckEntrySheet` audits a real pay stub against: the period's own
/// `EarningsResult`, handed down by the screen that opened the sheet.
///
/// **Why this exists, MEASURED.** Period detail's expectation
/// (`PeriodDetailFacts.expectedCheckCents`) moved onto the engine in wave 1
/// while the sheet that screen opens kept building its own basis out of
/// `allEntries.filter { $0.date >= period.start && $0.date <= period.end }`
/// plus `PeriodIncome.wages(firstWeekday: scheduleStore.schedule?.firstWeekday)`.
/// Two independent defects in one basis:
///
/// 1. `PayPeriod.end` is the START of the period's final day, so the entry-date
///    filter dropped every shift logged at a real hour on that day.
/// 2. `schedule?.firstWeekday` is the pay-period GRID's weekday, which PR 3
///    severed from the workweek — so overtime was allocated across different
///    weeks from the ones the screen behind the sheet used.
///
/// MEASURED on the fixture in `PaycheckAuditBasisParityTests`: five 10h days at
/// $10/hr with the POLICY workweek starting Sunday and the GRID set to Monday,
/// plus a 6h/$200 shift at 18:00 on the period's final day. The screen expected
/// $1,310.00; the sheet audited against $1,000.00 — tips $700.00 against
/// $500.00 (the final-day shift dropped) and wages $610.00 against $500.00 (the
/// grid weekday losing $110.00 of overtime). `PaycheckAudit` then told the
/// person their real check was $310.00 off against a number the screen behind
/// the sheet does not use.
///
/// The fix is structural rather than a second correct computation: the sheet is
/// HANDED this basis, so there is one expectation per period and the sheet
/// cannot hold a different one. `PaycheckAuditBasisParityTests` pins it.
///
/// Group 2.5 owns `PaycheckEntrySheet` and `PaycheckAudit` in wave 2; this is
/// only the basis, moved onto the engine so History's own migration does not
/// ship a screen whose sheet contradicts it.
struct PaycheckAuditBasis {
    /// The period's own known components — the SAME ones the hero, the
    /// drawer rows and `expectedCheckCents` read. Nil when no dataset stands
    /// behind them, and then every figure below refuses rather than reading
    /// zero.
    let components: EarningsComponents?

    /// The ledger's regular/overtime split for the same period.
    ///
    /// `PeriodIncome.Wages` is used as a plain four-field value here, not as
    /// a computation: it is the shape `PaycheckAudit`'s copy is written
    /// against ("Payday computes $X regular and $Y overtime"), and nothing
    /// pre-policy runs to produce it. PR 8 deletes the type and this
    /// construction with it.
    let wages: PeriodIncome.Wages?

    /// No dataset, so no expectation. Every audit check that needs one stays
    /// silent; the stub-internal ones (gross vs. its own lines, net vs. gross
    /// minus taxes) still run, because they need nothing from the engine.
    static let unbacked = PaycheckAuditBasis(result: nil)

    init(result: EarningsResult?) {
        guard let result else {
            components = nil
            wages = nil
            return
        }
        let known = result.knownComponents
        components = known
        // Nil under the same rule `PeriodIncome.wages` used, restated on the
        // engine's own completeness: with wages off, or with no shift priced,
        // there is no computed wage to audit a stub against, and the audit
        // says nothing rather than reporting a stub as $X over zero.
        if result.completeness.state == .off || result.completeness.shiftsWageValued == 0 {
            wages = nil
        } else {
            wages = PeriodIncome.Wages(
                regularCents: known.regularWagesCents,
                overtimeCents: known.overtimeWagesCents,
                hours: WorkedMinutes.hours(fromMinutes: result.minutes),
                overtimeHours: WorkedMinutes.hours(fromMinutes: result.overtimeMinutes)
            )
        }
    }

    /// The stub's TIPS line as the engine expects it. Nil when no credit tips
    /// were logged at all — a cash-only period is not a discrepancy, same
    /// silence-over-nagging rule the sheet has always used.
    var loggedCreditTipsCents: Int? {
        guard let components, components.voluntaryCreditCents > 0 else { return nil }
        return PredictedPaycheck.tipsLineCents(from: components)
    }

    /// The stub's GRATUITY line. Its own payroll category, compared
    /// independently so an overage in one cannot hide a shortage in the other.
    var loggedGratuityCents: Int? {
        guard let components, components.gratuityFeesCents > 0 else { return nil }
        return components.gratuityFeesCents
    }

    /// `MetricID.expectedPaycheckGross`. The same expression
    /// `PeriodDetailFacts.expectedCheckCents` is, over the same components, so
    /// the sheet and the screen behind it are one figure by construction and
    /// not two that agree. Nil when no dataset stands behind it.
    var expectedCheckCents: Int? {
        guard let components else { return nil }
        return PredictedPaycheck.cents(from: components)
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
/// **What is still owed, and by whom.** `MetricID.reconciliationDelta` says
/// the comparison belongs per COMPONENT ("observed - expected, per component,
/// for one pay period"), and `MetricID.observedPaidTips` says the ±100c
/// correction must be a proposal rather than a silent rewrite — today
/// `PaycheckRecord.reconciledPaidTipsCents` still substitutes it (fixture
/// P1). Both are group 2.5's `PaycheckReconciler`, wave 2. Wave 1 moved the
/// EXPECTED side onto the engine and unified the two implementations; it did
/// not invent 2.5's API.
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
        let components = result.knownComponents
        expectedTipsAndGratuityCents = PredictedPaycheck.tipsAndGratuityCents(from: components)
        paidTipEarningsCents = PredictedPaycheck.paidTipEarningsCents(
            tipsCents: paycheck.reconciledPaidTipsCents,
            gratuityCents: paycheck.gratuityCents
        )
        deltaCents = PredictedPaycheck.reconciliationDeltaCents(
            observedTipEarningsCents: paidTipEarningsCents,
            expectedTipsAndGratuityCents: expectedTipsAndGratuityCents
        )
        usesCreditOnly = components.voluntaryCreditCents > 0
    }
}
