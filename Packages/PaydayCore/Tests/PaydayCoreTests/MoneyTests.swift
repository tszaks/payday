import Testing
@testable import PaydayCore

@Suite("Money")
struct MoneyTests {
    @Test("string(fromCents:) formats whole dollars and cents with a thousands separator")
    func stringFromCents() {
        #expect(Money.string(fromCents: 123456) == "$1,234.56")
    }

    @Test("wholeDollarString(fromCents:) rounds to the nearest dollar with no fraction")
    func wholeDollarStringFromCents() {
        #expect(Money.wholeDollarString(fromCents: 182046) == "$1,820")
    }

    @Test("directionalDeltaString(fromCents:) prefixes a down arrow for negative cents")
    func directionalDeltaNegative() {
        #expect(Money.directionalDeltaString(fromCents: -500) == "↓ $5.00")
    }

    @Test("directionalDeltaString(fromCents:) prefixes an up arrow for positive cents")
    func directionalDeltaPositive() {
        #expect(Money.directionalDeltaString(fromCents: 500) == "↑ $5.00")
    }

    @Test("directionalDeltaString(fromCents:) has no arrow at zero")
    func directionalDeltaZero() {
        #expect(Money.directionalDeltaString(fromCents: 0) == "$0.00")
    }

    @Test("string(fromCents:) formats negative cents with a leading minus sign")
    func stringFromNegativeCents() {
        #expect(Money.string(fromCents: -250) == "-$2.50")
    }
}
