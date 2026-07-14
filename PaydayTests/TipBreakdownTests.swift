import Testing
import Foundation
@testable import Payday

@Suite("Tip breakdown split")
struct TipBreakdownTests {
    private func entry(_ cents: Int, _ kind: TipKind) -> TipEntry {
        TipEntry(date: .now, amountCents: cents, kind: kind)
    }

    @Test("empty set splits to zero")
    func empty() {
        let breakdown = TipBreakdown.total(of: [])
        #expect(breakdown == .zero)
        #expect(breakdown.totalCents == 0)
    }

    @Test("all cash lands in cash bucket")
    func allCash() {
        let breakdown = TipBreakdown.total(of: [entry(5000, .cash), entry(2500, .cash)])
        #expect(breakdown.cashCents == 7500)
        #expect(breakdown.creditCents == 0)
        #expect(breakdown.totalCents == 7500)
    }

    @Test("all credit lands in credit bucket")
    func allCredit() {
        let breakdown = TipBreakdown.total(of: [entry(4000, .credit), entry(1100, .credit)])
        #expect(breakdown.cashCents == 0)
        #expect(breakdown.creditCents == 5100)
        #expect(breakdown.totalCents == 5100)
    }

    @Test("mixed entries split correctly and sum to total")
    func mixed() {
        let breakdown = TipBreakdown.total(of: [
            entry(8600, .cash),
            entry(11200, .credit),
            entry(6400, .cash),
            entry(9800, .credit)
        ])
        #expect(breakdown.cashCents == 15000)
        #expect(breakdown.creditCents == 21000)
        #expect(breakdown.totalCents == 36000)
    }
}
