import Foundation
import Testing
@testable import Payday
import PaydayCore

/// **One fact, one definition.**
///
/// `nonWageEarnings` -- what a shift earned before wages -- was written out
/// independently in five places: `EarningsComponents` (PaydayCore, the
/// canonical one), `ShiftRecord`, `TipBreakdown`, `LegacyShiftRow` and
/// `StatsEngine`. Identical arithmetic in all five, which is exactly the
/// hazard rather than a comfort: they agree until one is edited, and then
/// they disagree silently about a number on screen.
///
/// This suite pins the refactor that removed one of the five. The oracle is
/// the OLD formula, written out literally -- the correct shape for a
/// behaviour-preserving change, and the one case where restating the
/// arithmetic in a test is right rather than a mirror-test trap: the point
/// is precisely to detect any divergence from what shipped.
@Suite("nonWageEarnings has one definition")
@MainActor
struct NonWageEarningsOneDefinitionTests {

    private func record(cash: Int, credit: Int, gratuity: Int?, tipOut: Int?) -> ShiftRecord {
        var metrics: ShiftReceiptMetrics?
        if let gratuity {
            var m = ShiftReceiptMetrics()
            m.earningsSchemaVersion = 2          // the record's invariant
            m.gratuityFeesCents = gratuity
            metrics = m
        }
        return ShiftRecord(
            workDate: Date(timeIntervalSince1970: 1_758_000_000),
            cashTipsCents: cash,
            creditTipsCents: credit,
            tipOutCents: tipOut,
            hoursWorked: 5,
            receiptMetrics: metrics
        )
    }

    /// The formula as it stood before the delegation, verbatim.
    private func shippedFormula(_ r: ShiftRecord) -> Int {
        r.cashTipsCents + r.creditTipsCents
            + (r.receiptMetrics?.employeeGratuityFeesCents ?? 0)
            - (r.tipOutCents ?? 0)
    }

    @Test("delegating to PaydayCore changes no value, over a seeded sweep")
    func delegationIsBehaviourPreserving() {
        var rng = SystemRandomNumberGenerator()
        _ = rng
        // Deterministic, not random: a refactor gate that varies run to run
        // cannot be re-derived, and an unreproducible gate is not a gate.
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<400 {
            let r = record(
                cash: next(50_000),
                credit: next(50_000),
                gratuity: next(4) == 0 ? nil : next(5_000),
                tipOut: next(3) == 0 ? nil : next(3_000)
            )
            #expect(r.nonWageEarningsCents == shippedFormula(r))
        }
    }

    @Test("and it equals the canonical engine definition", arguments: [
        (1_000, 2_000, Int?.some(300), Int?.some(150)),
        (0, 0, Int?.none, Int?.none),
        (100, 0, Int?.some(900), Int?.none),
    ])
    func matchesEarningsComponents(cash: Int, credit: Int, gratuity: Int?, tipOut: Int?) {
        let r = record(cash: cash, credit: credit, gratuity: gratuity, tipOut: tipOut)
        let canonical = EarningsComponents(
            voluntaryCashCents: cash,
            voluntaryCreditCents: credit,
            gratuityFeesCents: gratuity ?? 0,
            tipOutCents: tipOut ?? 0
        ).nonWageEarningsCents
        #expect(r.nonWageEarningsCents == canonical)
        #expect(r.nonWageEarningsCents == shippedFormula(r))
    }
    /// The third copy, collapsed. `TipBreakdown` reaches this type with
    /// values already folded to voluntary-only by `total(of:)`, so the
    /// canonical definition applies unchanged.
    ///
    /// The v1 fold itself stays in `LegacyShiftRow` and is deliberately NOT
    /// delegated: it is a sanctioned legacy read leg, not a duplicate of
    /// this formula, and collapsing it would destroy the normalization that
    /// makes a legacy row comparable at all.
    @Test("TipBreakdown's net equals the canonical definition", arguments: [
        (1_000, 2_000, 300, 150),
        (0, 0, 0, 0),
        (100, 0, 900, 0),
        (5_000, 1_234, 0, 777),
    ])
    func tipBreakdownMatchesCanonical(cash: Int, credit: Int, gratuity: Int, tipOut: Int) {
        let b = TipBreakdown(
            cashCents: cash, creditCents: credit,
            tipOutCents: tipOut, gratuityFeesCents: gratuity
        )
        // The formula as it stood before the delegation, verbatim.
        let shipped = (cash + credit) + gratuity - tipOut
        let canonical = EarningsComponents(
            voluntaryCashCents: cash,
            voluntaryCreditCents: credit,
            gratuityFeesCents: gratuity,
            tipOutCents: tipOut
        ).nonWageEarningsCents
        #expect(b.netTotalCents == shipped)
        #expect(b.netTotalCents == canonical)
    }

}
