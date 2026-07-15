import Testing
@testable import Payday

@Suite("LogTipsIntent amount validation")
struct LogTipsAmountValidationTests {
    @Test("a normal amount converts to cents")
    func normalAmount() {
        #expect(LogTipsAmountValidation.validatedCents(for: 42.50) == 4250)
    }

    @Test("zero is rejected")
    func zeroRejected() {
        #expect(LogTipsAmountValidation.validatedCents(for: 0) == nil)
    }

    @Test("a negative amount is rejected")
    func negativeRejected() {
        #expect(LogTipsAmountValidation.validatedCents(for: -50) == nil)
    }

    @Test("the maximum amount is accepted")
    func maximumAccepted() {
        #expect(LogTipsAmountValidation.validatedCents(for: 99_999.99) == LogTipsAmountValidation.maximumCents)
    }

    @Test("just over the maximum is rejected")
    func overMaximumRejected() {
        #expect(LogTipsAmountValidation.validatedCents(for: 100_000.00) == nil)
    }

    @Test("fractional cents round to the nearest cent")
    func roundsToNearestCent() {
        #expect(LogTipsAmountValidation.validatedCents(for: 10.006) == 1001)
    }
}
