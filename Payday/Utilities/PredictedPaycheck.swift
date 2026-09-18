import Foundation

/// The single formula for "what the check for this period should read" —
/// shared by the Dashboard's payday moment, the period detail screen, the
/// payday push notification, the periods list, and the paycheck audit, so the
/// number on a lock-screen banner and the number in the app can never quietly
/// drift apart.
///
/// Two facts, deliberately separate:
///
/// - `tipsLineCents` is the TIPS line printed on the stub. Credit tips minus
///   tip-out: cash never runs through payroll, and tip-out is withheld from
///   declared tips and paid out to whoever was tipped out (Tyler, 2026-08-03 —
///   "I never see tip out, it goes straight into the paychecks of whoever is
///   getting tipped out"). This is the number the audit compares a real stub
///   against, so it has to be what payroll actually prints, not what the
///   server earned. Falls back to net of ALL tips when no credit was logged at
///   all, so a cash-only period still gets a number to check against.
///
/// - `cents(from:wagesCents:)` is the whole pre-tax check: that tips line,
///   Toast mandatory gratuity/fees, and base/overtime wages. Mandatory
///   gratuity is a separate non-tip wage line even though it is earned during
///   the shift. One number, so no surface leaves the person adding it up.
///
/// Neither figure accounts for tax withholding; every caller says "before
/// taxes" out loud.
enum PredictedPaycheck {
    // MARK: - The engine's basis (PR 5)
    //
    // `EarningsComponents` is the same six integers on the engine's side of
    // the migration, so these are the SAME formulas over the ledger's
    // components rather than over `TipBreakdown`'s. The legacy entry points
    // below now delegate to them, so there is one implementation of the stub
    // rule and not two that have to be kept in step.
    //
    // MetricIDs: `expectedPaycheckTipsLine` (whose registry definition names
    // `tipsLineCents` as the implementation), `expectedPaycheckGross`, and
    // `reconciliationDelta`. The registry wants the delta compared PER
    // COMPONENT; that, and the ±100c proposal, are group 2.5's
    // `PaycheckReconciler` in PR 5 wave 2. These four functions are the
    // summed form today's screens already render, moved onto the engine.

    /// `MetricID.expectedPaycheckTipsLine`: credit tips net of tip-out, or
    /// all voluntary tips net of tip-out when no credit was logged at all.
    static func tipsLineCents(from components: EarningsComponents) -> Int {
        let base = components.voluntaryCreditCents > 0
            ? components.voluntaryCreditCents
            : components.voluntaryTipsCents
        return max(0, base - components.tipOutCents)
    }

    /// The stub's Tips line plus its Gratuity line — the "Logged $X" half of
    /// a paycheck comparison. A composite of two registry rows, kept in one
    /// function because both History surfaces render exactly this sum today.
    static func tipsAndGratuityCents(from components: EarningsComponents) -> Int {
        tipsLineCents(from: components) + components.gratuityFeesCents
    }

    /// `MetricID.expectedPaycheckGross`: the whole pre-tax check. Wages come
    /// from the components, so a period whose wages are `.unavailable`
    /// contributes zero for them and the caller's `Completeness` says so.
    static func cents(from components: EarningsComponents) -> Int {
        tipsAndGratuityCents(from: components) + components.wagesCents
    }

    /// `MetricID.reconciliationDelta`, summed: observed minus expected.
    /// Negative means the check came up short.
    static func reconciliationDeltaCents(
        observedTipEarningsCents: Int,
        expectedTipsAndGratuityCents: Int
    ) -> Int {
        observedTipEarningsCents - expectedTipsAndGratuityCents
    }

    // MARK: - The legacy basis

    /// The stub's tips line: credit tips net of tip-out.
    static func tipsLineCents(from breakdown: TipBreakdown) -> Int {
        tipsLineCents(from: components(of: breakdown))
    }

    /// The whole pre-tax check: tips owed + mandatory gratuity + wages.
    static func cents(from breakdown: TipBreakdown, wagesCents: Int) -> Int {
        tipsAndGratuityCents(from: components(of: breakdown)) + wagesCents
    }

    /// A `TipBreakdown` as the four non-wage components it already is. Field
    /// for field, no arithmetic: this is a rename, so the two bases cannot
    /// drift into two answers.
    private static func components(of breakdown: TipBreakdown) -> EarningsComponents {
        EarningsComponents(
            voluntaryCashCents: breakdown.cashCents,
            voluntaryCreditCents: breakdown.creditCents,
            gratuityFeesCents: breakdown.gratuityFeesCents,
            tipOutCents: breakdown.tipOutCents
        )
    }

    static func hasCreditTips(_ breakdown: TipBreakdown) -> Bool {
        breakdown.creditCents > 0
    }

    /// Combined tip and mandatory-gratuity earnings represented by a stub.
    /// Keep this combination only for whole-check math; audits compare the
    /// two categories independently so one cannot hide a shortage in another.
    static func paidTipEarningsCents(tipsCents: Int, gratuityCents: Int?) -> Int {
        tipsCents + (gratuityCents ?? 0)
    }
}

// MARK: - The figure a view renders

/// `MetricID.expectedPaycheckGross` as an `EarningsFigure`.
///
/// Deliberately a SEPARATE extension at the end of the file, and the only
/// thing group 2.1 (Dashboard) adds here. The engine-basis functions above
/// are group 2.4's (History), written once, in their shape, byte for byte:
/// both groups needed the same four formulas and the plan's rule is that a
/// shared change "does not get made twice". MEASURED why it matters: two
/// independent additions of `tipsLineCents(from: EarningsComponents)` in
/// different parts of this file merge with `git apply --3way` reporting
/// "applied cleanly" and no conflict markers, and the duplicate declarations
/// only surface as `error: ambiguous use of 'cents(from:)'` in
/// `PeriodDetailView.swift` — a file neither worker touched. Identical text
/// in the identical place merges to one copy; an append below it stays an
/// append.
extension PredictedPaycheck {
    /// A nil `result` is a failed read, not a zero check, so it renders no
    /// currency at all (PR 5 adapter contract, rule 4). A period whose wages
    /// are `.partial` or `.estimated` carries the matching caption, because a
    /// check figure that silently omits an unpriced shift is exactly the
    /// audit's headline defect wearing a different label.
    ///
    /// The label is the registry's ("Expected", `MetricID
    /// .expectedPaycheckGross.allowedLabels`). The card's own sentence —
    /// "Your check should show" / "Today's check should show" — is
    /// presentation the screen owns, and the registry has no row for it; see
    /// `docs/METRICS.md` [DB-22].
    static func figure(from result: EarningsResult?) -> EarningsFigure {
        guard let result else {
            return EarningsFigure(
                metric: .expectedPaycheckGross,
                amount: .unavailable,
                label: "Expected",
                caption: nil,
                completeness: .empty
            )
        }
        return EarningsFigure(
            metric: .expectedPaycheckGross,
            amount: .cents(cents(from: result.knownComponents)),
            label: "Expected",
            caption: CompletenessCopy.caption(result.completeness.state),
            completeness: result.completeness
        )
    }
}
