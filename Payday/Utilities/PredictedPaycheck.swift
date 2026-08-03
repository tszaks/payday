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
/// - `cents(from:wagesCents:)` is the whole pre-tax check: that tips line plus
///   base and overtime wages. One number, so no surface has to say "$X, plus
///   $Y in wages" and leave the person adding it up themselves.
///
/// Neither figure accounts for tax withholding; every caller says "before
/// taxes" out loud.
enum PredictedPaycheck {
    /// The stub's tips line: credit tips net of tip-out.
    static func tipsLineCents(from breakdown: TipBreakdown) -> Int {
        let base = breakdown.creditCents > 0 ? breakdown.creditCents : breakdown.grossTotalCents
        return max(0, base - breakdown.tipOutCents)
    }

    /// The whole pre-tax check: the stub's tips line plus wages.
    static func cents(from breakdown: TipBreakdown, wagesCents: Int) -> Int {
        tipsLineCents(from: breakdown) + wagesCents
    }

    static func hasCreditTips(_ breakdown: TipBreakdown) -> Bool {
        breakdown.creditCents > 0
    }
}
