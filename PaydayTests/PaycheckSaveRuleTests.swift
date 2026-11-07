import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// PR A review fix: with card tips paid at close, the stub prints no tips
/// line, so the paycheck sheet must accept a stub whose tips field is empty
/// as long as some other figure was entered. On the paycheck, the tips line
/// stays required, as it always was. Synthetic round numbers.
@Suite("Paycheck sheet: when the stub as entered can be saved")
struct PaycheckSaveRuleTests {
    private func observation(
        tips: Int? = nil, wages: Int? = nil, gross: Int? = nil, net: Int? = nil
    ) -> PaycheckReconciler.Observation {
        PaycheckReconciler.Observation(
            paidTipsCents: tips,
            regularWagesCents: wages,
            overtimeWagesCents: nil,
            gratuityCents: nil,
            grossCents: gross,
            taxesCents: nil,
            netCents: net
        )
    }

    private func expectation(cardTipsOnCheck: Bool) -> PaycheckReconciler.Expectation {
        PaycheckReconciler.Expectation(result: nil, stamp: nil, cardTipsOnCheck: cardTipsOnCheck)
    }

    @Test("on the paycheck, the tips line is the figure that makes a stub")
    func onTheCheckTheTipsLineIsRequired() {
        let onCheck = expectation(cardTipsOnCheck: true)
        #expect(PaycheckEntryFacts(expectation: onCheck, observation: observation(gross: 8_000, net: 7_000)).canSave == false)
        #expect(PaycheckEntryFacts(expectation: onCheck, observation: observation(tips: 12_000)).canSave == true)
        #expect(PaycheckEntryFacts(expectation: onCheck, observation: observation()).canSave == false)
    }

    @Test("paid at close, any other figure makes a stub and the tips field may stay empty")
    func atCloseAnyOtherFigureIsEnough() {
        let atClose = expectation(cardTipsOnCheck: false)
        #expect(PaycheckEntryFacts(expectation: atClose, observation: observation(gross: 8_000, net: 7_000)).canSave == true)
        #expect(PaycheckEntryFacts(expectation: atClose, observation: observation(wages: 8_000)).canSave == true)
        #expect(PaycheckEntryFacts(expectation: atClose, observation: observation(tips: 500)).canSave == true)
        #expect(PaycheckEntryFacts(expectation: atClose, observation: observation()).canSave == false)
    }
}
