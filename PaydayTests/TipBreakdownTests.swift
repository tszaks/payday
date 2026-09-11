import Testing
import Foundation
@testable import Payday

@Suite("Tip breakdown split")
struct TipBreakdownTests {
    private func entry(_ cents: Int, _ kind: TipKind, tipOut: Int? = nil, gratuityFees: Int? = nil, shiftID: UUID? = nil) -> TipEntry {
        TipEntry(
            date: .now,
            amountCents: cents,
            kind: kind,
            tipOutCents: tipOut,
            shiftID: shiftID,
            receiptMetrics: gratuityFees.map { ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: $0) }
        )
    }

    @Test("empty set splits to zero")
    func empty() {
        let breakdown = TipBreakdown.total(of: [])
        #expect(breakdown == .zero)
        #expect(breakdown.grossTotalCents == 0)
        #expect(breakdown.netTotalCents == 0)
    }

    @Test("all cash lands in cash bucket")
    func allCash() {
        let breakdown = TipBreakdown.total(of: [entry(5000, .cash), entry(2500, .cash)])
        #expect(breakdown.cashCents == 7500)
        #expect(breakdown.creditCents == 0)
        #expect(breakdown.grossTotalCents == 7500)
    }

    @Test("all credit lands in credit bucket")
    func allCredit() {
        let breakdown = TipBreakdown.total(of: [entry(4000, .credit), entry(1100, .credit)])
        #expect(breakdown.cashCents == 0)
        #expect(breakdown.creditCents == 5100)
        #expect(breakdown.grossTotalCents == 5100)
    }

    @Test("mixed entries split correctly and sum to gross")
    func mixed() {
        let breakdown = TipBreakdown.total(of: [
            entry(8600, .cash),
            entry(11200, .credit),
            entry(6400, .cash),
            entry(9800, .credit)
        ])
        #expect(breakdown.cashCents == 15000)
        #expect(breakdown.creditCents == 21000)
        #expect(breakdown.grossTotalCents == 36000)
        #expect(breakdown.tipOutCents == 0)
        #expect(breakdown.netTotalCents == 36000)
    }

    @Test("net is gross minus tip-out; cash/credit stay gross")
    func netSubtractsTipOut() {
        // A cash+credit night with a $19.92 tip-out on the credit entry —
        // the exact shape that showed two different totals on one screen.
        let breakdown = TipBreakdown.total(of: [
            entry(12700, .cash),
            entry(40980, .credit, tipOut: 1992)
        ])
        #expect(breakdown.cashCents == 12700)
        #expect(breakdown.creditCents == 40980)
        #expect(breakdown.grossTotalCents == 53680)
        #expect(breakdown.tipOutCents == 1992)
        #expect(breakdown.netTotalCents == 51688)
    }

    @Test("tip-outs across separate shifts sum")
    func tipOutsAcrossShiftsSum() {
        let breakdown = TipBreakdown.total(of: [
            entry(5000, .cash, tipOut: 500, shiftID: UUID()),
            entry(8000, .credit, tipOut: 800, shiftID: UUID())
        ])
        #expect(breakdown.tipOutCents == 1300)
        #expect(breakdown.netTotalCents == 11700)
    }

    @Test("duplicate shift-level tip-out resolves once from the canonical entry")
    func duplicateTipOutWithinShiftResolvesOnce() {
        let shiftID = UUID()
        let breakdown = TipBreakdown.total(of: [
            entry(5000, .cash, tipOut: 500, shiftID: shiftID),
            entry(8000, .credit, tipOut: 800, shiftID: shiftID)
        ])

        #expect(breakdown.tipOutCents == 800)
        #expect(breakdown.netTotalCents == 12200)
    }

    @Test("Toast gratuity is earnings but remains separate from voluntary tips")
    func toastGratuityStaysSeparate() {
        // IMG_0674: $121.36 Non-cash tips + $40.50 employee gratuity/fees
        // - $22.43 tip sharing = $139.43 non-wage earnings.
        let breakdown = TipBreakdown.total(of: [
            entry(12_136, .credit, tipOut: 2_243, gratuityFees: 4_050)
        ])

        #expect(breakdown.creditCents == 12_136)
        #expect(breakdown.gratuityFeesCents == 4_050)
        #expect(breakdown.grossTotalCents == 12_136)
        #expect(breakdown.earnedBeforeTipOutCents == 16_186)
        #expect(breakdown.netTotalCents == 13_943)
    }

    @Test("legacy combined Toast amounts normalize without changing earnings")
    func legacyCombinedAmountNormalizes() {
        let legacy = TipEntry(
            date: .now,
            amountCents: 16_186,
            kind: .credit,
            tipOutCents: 2_243,
            receiptMetrics: ShiftReceiptMetrics(
                earningsSchemaVersion: nil,
                gratuityFeesCents: 4_050
            )
        )

        let breakdown = TipBreakdown.total(of: [legacy])

        #expect(breakdown.creditCents == 12_136)
        #expect(breakdown.gratuityFeesCents == 4_050)
        #expect(breakdown.netTotalCents == 13_943)
    }
}
