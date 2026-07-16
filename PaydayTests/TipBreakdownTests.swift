import Testing
import Foundation
@testable import Payday

@Suite("Tip breakdown split")
struct TipBreakdownTests {
    private func entry(_ cents: Int, _ kind: TipKind, tipOut: Int? = nil) -> TipEntry {
        TipEntry(date: .now, amountCents: cents, kind: kind, tipOutCents: tipOut)
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

    @Test("tip-outs across multiple entries sum")
    func tipOutsSum() {
        let breakdown = TipBreakdown.total(of: [
            entry(5000, .cash, tipOut: 500),
            entry(8000, .credit, tipOut: 800)
        ])
        #expect(breakdown.tipOutCents == 1300)
        #expect(breakdown.netTotalCents == 11700)
    }
}
