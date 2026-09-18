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
