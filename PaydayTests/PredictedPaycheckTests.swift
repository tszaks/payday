import Testing
import Foundation
@testable import Payday

/// The formula behind every "what should my check say" surface in the app:
/// the dashboard's payday moment, the period-detail caption, the payday push,
/// the periods-list "checked" badge, and the paycheck audit's ground truth.
/// Locked down here because a cent of drift in it accuses payroll of a
/// shortfall that never happened.
@Suite("Predicted paycheck")
struct PredictedPaycheckTests {
    private func breakdown(cash: Int = 0, credit: Int = 0, tipOut: Int = 0) -> TipBreakdown {
        TipBreakdown(cashCents: cash, creditCents: credit, tipOutCents: tipOut)
    }

    // MARK: The stub's tips line

    @Test("tips line is credit tips net of tip-out")
    func tipsLineNetsTipOut() {
        // Tyler's own period, 2026-08-03: $2,960.28 credit, $473.65 tipped out.
        let result = PredictedPaycheck.tipsLineCents(from: breakdown(cash: 42700, credit: 296028, tipOut: 47365))
        #expect(result == 248663)
    }

    @Test("cash never reaches the tips line")
    func cashExcluded() {
        let withCash = PredictedPaycheck.tipsLineCents(from: breakdown(cash: 50000, credit: 10000))
        let withoutCash = PredictedPaycheck.tipsLineCents(from: breakdown(credit: 10000))
        #expect(withCash == withoutCash)
    }

    @Test("no tip-out logged leaves credit tips untouched")
    func noTipOutIsGrossCredit() {
        #expect(PredictedPaycheck.tipsLineCents(from: breakdown(cash: 4000, credit: 15000)) == 15000)
    }

    @Test("a cash-only period falls back to total tips, still net of tip-out")
    func cashOnlyFallback() {
        #expect(PredictedPaycheck.tipsLineCents(from: breakdown(cash: 20000, tipOut: 3000)) == 17000)
        #expect(PredictedPaycheck.hasCreditTips(breakdown(cash: 20000)) == false)
    }

    @Test("tip-out larger than the tips it came from floors at zero, never negative")
    func neverNegative() {
        #expect(PredictedPaycheck.tipsLineCents(from: breakdown(credit: 5000, tipOut: 9000)) == 0)
    }

    // MARK: The whole pre-tax check

    @Test("check is the tips line plus wages, in one number")
    func checkAddsWages() {
        // Tyler's period again: $2,486.63 tips line + $206.21 wages = $2,692.84,
        // the figure he arrived at himself before the app could.
        let result = PredictedPaycheck.cents(from: breakdown(cash: 42700, credit: 296028, tipOut: 47365), wagesCents: 20621)
        #expect(result == 269284)
    }

    @Test("no wage rate set leaves the check at the tips line")
    func noWagesIsTipsLine() {
        let bd = breakdown(credit: 296028, tipOut: 47365)
        #expect(PredictedPaycheck.cents(from: bd, wagesCents: 0) == PredictedPaycheck.tipsLineCents(from: bd))
    }

    /// The bug this formula replaced: gross credit tips, tip-out silently left
    /// in, wages bolted on in a second sentence. On Tyler's period that read
    /// $2,960.28 "plus $206.21 in wages" — $473.65 above what payroll would
    /// actually print, which the audit then reported as a shortfall.
    @Test("the old gross-credit answer is exactly one tip-out too high")
    func regressionAgainstGrossCredit() {
        let bd = breakdown(cash: 42700, credit: 296028, tipOut: 47365)
        #expect(bd.creditCents - PredictedPaycheck.tipsLineCents(from: bd) == bd.tipOutCents)
    }
}
