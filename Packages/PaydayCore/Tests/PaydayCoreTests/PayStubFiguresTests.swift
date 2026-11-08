import Testing
@testable import PaydayCore

private func line(_ name: String, _ cents: Int, _ category: String = "other") -> PayStubLine {
    PayStubLine(name: name, category: category, cents: cents)
}

@Suite("Pay stub figures")
struct PayStubFiguresTests {
    @Test("earnings lines are classified by the words that carry the meaning")
    func classification() {
        typealias Kind = PayStubFigures.EarningKind
        let expected: [(String?, Kind)] = [
            ("Credit Card Tips", .tips),
            ("Tips Credit Card", .tips),
            ("Tip Credit Cards", .tips),
            ("Tips - Credit Card", .tips),
            ("CC TIPS", .tips),
            ("Tips Paid", .tips),
            ("Tip Share", .tips),
            ("Charged Tip", .tips),
            ("Cash Tips", .declaredTips),
            ("Declared Tips", .declaredTips),
            ("Tips Reported", .declaredTips),
            ("Gratuity", .gratuity),
            ("Auto Gratuities", .gratuity),
            ("Service Charge", .gratuity),
            ("Tip Credit", .other),
            ("Tip Makeup", .other),
            ("Tip Make-Up", .other),
            ("Tips Credit", .other),
            ("Tip Credit Adjustment", .other),
            ("Regular", .other),
            // "tip" must be a word, not a prefix.
            ("Multiple Shifts", .other),
            ("", .other),
            (nil, .other),
        ]
        for (name, kind) in expected {
            #expect(Kind(name: name) == kind, "\(name ?? "nil")")
        }
    }

    @Test("tip, declared and gratuity lines are summed apart; tip credit is not a tip")
    func sumsApart() {
        let figures = PayStubFigures(
            earnings: [
                line("Regular", 30_000),
                line("Credit Card Tips", 41_235),
                line("Tips - Charged", 1_000),
                line("Cash Tips", 8_800),
                line("Service Charge", 5_510),
                line("Tip Credit", -12_000),
            ],
            deductions: []
        )
        #expect(figures.paidTipsCents == 42_235)
        let cardFirst = PayStubFigures(earnings: [line("Tips Credit Card", 41_235)], deductions: [])
        #expect(cardFirst.paidTipsCents == 41_235, "both word orders are card tips")
        #expect(figures.declaredTipsCents == 8_800)
        #expect(figures.gratuityCents == 5_510)
        #expect(figures.taxesCents == nil)
    }

    @Test("earnings without a tip line are zero tips; no earnings lines are unknown")
    func zeroVersusUnknown() {
        let wagesOnly = PayStubFigures(earnings: [line("Regular", 150_000)], deductions: [])
        #expect(wagesOnly.paidTipsCents == 0)
        #expect(wagesOnly.gratuityCents == nil)
        #expect(wagesOnly.declaredTipsCents == nil)
        let bare = PayStubFigures(earnings: [], deductions: [])
        #expect(bare.paidTipsCents == nil)
    }

    @Test("taxes are federal + state + local + Social Security + Medicare only; none is nil")
    func taxes() {
        let figures = PayStubFigures(
            earnings: [],
            deductions: [
                line("a", 100, "federal"),
                line("b", 20, "state"),
                line("c", 3, "local"),
                line("d", 40, "socialsec"),
                line("e", 5, "medicare"),
                line("f", 999, "retirement"),
                line("g", 999, "benefit"),
                line("h", 999, "memo"),
                line("i", 999, "garnishment"),
            ]
        )
        #expect(figures.taxesCents == 168)
        #expect(PayStubFigures(earnings: [], deductions: [line("401k", 999, "retirement")]).taxesCents == nil)
        #expect(PayStubFigures(earnings: [], deductions: []).taxesCents == nil)
    }

    @Test("a tax line printed negative is still an amount withheld")
    func negativeTaxLine() {
        let figures = PayStubFigures(earnings: [], deductions: [line("Fed", -1_500, "federal"), line("SS", 900, "socialsec")])
        #expect(figures.taxesCents == 2_400)
    }
}
