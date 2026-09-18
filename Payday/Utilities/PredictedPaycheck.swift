import Foundation

/// The app-side façade over `PaycheckReconciler`'s expected side.
///
/// **There is no formula in this file any more.** Every function below
/// forwards to `PaydayCore.PaycheckReconciler`, which is where PR 5 group 2.5
/// moved the stub rule, the whole-check rule and the reconciliation delta.
/// What is left here is the call-site vocabulary five surfaces already use —
/// the Dashboard's payday moment, period detail, the periods list, the payday
/// push notification and the paycheck audit — so those did not all have to be
/// rewritten in one change, and the two remaining `TipBreakdown` entry points,
/// which the pre-engine surfaces (the notification) still need.
///
/// The formulas themselves, and the reasons behind them, are documented on
/// `PaycheckReconciler`: cash never runs through payroll, tip-out is withheld
/// from declared tips and paid to whoever was tipped out (Tyler, 2026-08-03),
/// mandatory gratuity is its own non-tip wage line, and nothing here accounts
/// for withholding — every caller says "before taxes" out loud.
///
/// PR 8 deletes this type. Until then, do not add a formula to it: add it to
/// `PaycheckReconciler` and forward.
enum PredictedPaycheck {
    // MARK: - The engine's basis

    /// `MetricID.expectedPaycheckTipsLine`.
    static func tipsLineCents(from components: EarningsComponents) -> Int {
        PaycheckReconciler.tipsLineCents(from: components)
    }

    /// The stub's Tips line plus its Gratuity line.
    static func tipsAndGratuityCents(from components: EarningsComponents) -> Int {
        PaycheckReconciler.tipsAndGratuityCents(from: components)
    }

    /// `MetricID.expectedPaycheckGross`.
    static func cents(from components: EarningsComponents) -> Int {
        PaycheckReconciler.grossCents(from: components)
    }

    /// `MetricID.reconciliationDelta`, for one component.
    static func reconciliationDeltaCents(
        observedTipEarningsCents: Int,
        expectedTipsAndGratuityCents: Int
    ) -> Int {
        PaycheckReconciler.deltaCents(
            observed: observedTipEarningsCents,
            expected: expectedTipsAndGratuityCents
        )
    }

    // MARK: - The legacy basis

    /// The stub's tips line for a surface that still holds a `TipBreakdown`
    /// rather than an `EarningsResult` — today only `PaydayPushScheduler`
    /// (group 2.12). Field for field, no arithmetic: `TipBreakdown` IS four
    /// of the six components, so this is a rename and the two bases cannot
    /// drift into two answers.
    static func tipsLineCents(from breakdown: TipBreakdown) -> Int {
        PaycheckReconciler.tipsLineCents(from: components(of: breakdown))
    }

    /// The whole pre-tax check on the legacy basis.
    static func cents(from breakdown: TipBreakdown, wagesCents: Int) -> Int {
        PaycheckReconciler.tipsAndGratuityCents(from: components(of: breakdown)) + wagesCents
    }

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
        PaycheckReconciler.Observation(
            paidTipsCents: tipsCents,
            gratuityCents: gratuityCents
        ).paidTipEarningsCents ?? tipsCents
    }
}

// MARK: - The figure a view renders

extension PredictedPaycheck {
    /// `MetricID.expectedPaycheckGross` as an `EarningsFigure`.
    ///
    /// Forwards to `PaycheckReconciler.Expectation.grossFigure`, which is the
    /// same value `PaycheckEntrySheet` renders and period detail's expected
    /// caption reads, so the Dashboard's payday moment, the period and the
    /// sheet are one answer rather than three that agree.
    ///
    /// A nil `result` is a failed read, not a zero check, so it renders no
    /// currency at all (PR 5 adapter contract, rule 4). A period whose wages
    /// are `.partial` or `.estimated` carries the matching caption.
    ///
    /// The label is the registry's ("Expected"). The card's own sentence —
    /// "Your check should show" / "Today's check should show" — is
    /// presentation the screen owns; see `docs/METRICS.md` [DB-22].
    static func figure(from result: EarningsResult?) -> EarningsFigure {
        PaycheckReconciler.Expectation(result: result, stamp: nil).grossFigure
    }
}
