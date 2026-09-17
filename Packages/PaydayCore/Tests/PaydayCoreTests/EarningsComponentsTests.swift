import Testing
@testable import PaydayCore

@Suite("EarningsComponents")
struct EarningsComponentsTests {
    let sample = EarningsComponents(
        voluntaryCashCents: 6000, voluntaryCreditCents: 4000, gratuityFeesCents: 500,
        tipOutCents: 1000, regularWagesCents: 1203, overtimeWagesCents: 849
    )

    @Test("zero is the additive identity")
    func additiveIdentity() {
        #expect(sample + .zero == sample)
        #expect(.zero + sample == sample)
        #expect(sample - .zero == sample)
        #expect(sample - sample == .zero)
        #expect(EarningsComponents.zero.earnedIncomeCents == 0)
    }

    @Test("earnedIncome = cash + credit + gratuity - tipOut + regular + overtime")
    func earnedIncomeFormula() {
        #expect(sample.voluntaryTipsCents == 10000)
        #expect(sample.nonWageEarningsCents == 9500)
        #expect(sample.wagesCents == 2052)
        #expect(sample.earnedIncomeCents == 11552)
    }

    @Test("addition is component-wise and commutative")
    func addition() {
        let other = EarningsComponents(voluntaryCashCents: 1, voluntaryCreditCents: 2, gratuityFeesCents: 3,
                                       tipOutCents: 4, regularWagesCents: 5, overtimeWagesCents: 6)
        let sum = sample + other
        #expect(sum == EarningsComponents(voluntaryCashCents: 6001, voluntaryCreditCents: 4002, gratuityFeesCents: 503,
                                          tipOutCents: 1004, regularWagesCents: 1208, overtimeWagesCents: 855))
        #expect(sum == other + sample)
        #expect(sum - other == sample)
        var accumulated = EarningsComponents.zero
        accumulated += sample
        accumulated += other
        #expect(accumulated == sum)
    }

    @Test("reduce over a collection equals the sum of earned income")
    func reduceMatchesSum() {
        let parts = [sample, sample, .zero, sample]
        let total = parts.reduce(.zero, +)
        #expect(total.earnedIncomeCents == parts.map(\.earnedIncomeCents).reduce(0, +))
    }
}
