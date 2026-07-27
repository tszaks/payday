import Testing
@testable import Payday

@Suite("CardFlowStep")
struct CardFlowStepTests {
    @Test("seven cards, in the fixed deck order")
    func order() {
        #expect(CardFlowStep.allCases == [.tips, .shift, .times, .tipOut, .sales, .servers, .note])
    }

    @Test("each card's on-screen kicker")
    func kickers() {
        #expect(CardFlowStep.tips.kicker == "TIPS")
        #expect(CardFlowStep.shift.kicker == "SHIFT")
        #expect(CardFlowStep.times.kicker == "TIMES")
        #expect(CardFlowStep.tipOut.kicker == "TIP-OUT")
        #expect(CardFlowStep.sales.kicker == "SALES")
        #expect(CardFlowStep.servers.kicker == "SERVERS")
        #expect(CardFlowStep.note.kicker == "NOTE")
    }

    @Test("each card's VoiceOver title")
    func accessibilityTitles() {
        #expect(CardFlowStep.tips.accessibilityTitle == "Tips")
        #expect(CardFlowStep.shift.accessibilityTitle == "Shift")
        #expect(CardFlowStep.times.accessibilityTitle == "Times")
        #expect(CardFlowStep.tipOut.accessibilityTitle == "Tip-out")
        #expect(CardFlowStep.sales.accessibilityTitle == "Sales")
        #expect(CardFlowStep.servers.accessibilityTitle == "Servers")
        #expect(CardFlowStep.note.accessibilityTitle == "Note")
    }

    @Test("rawValue matches deck position, so CardFlowStep(rawValue: step.rawValue + 1) walks forward one card at a time")
    func rawValueIsPosition() {
        for (index, step) in CardFlowStep.allCases.enumerated() {
            #expect(step.rawValue == index)
        }
    }
}
