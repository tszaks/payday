import Testing
import Foundation
@testable import Payday

@Suite("Onboarding diagnosis — deterministic arithmetic on the quiz answers")
struct OnboardingDiagnosisTests {

    // MARK: - Determinism

    @Test("the same answers always produce an equal diagnosis")
    func sameAnswersAreEqual() {
        let first = PaydayOnboardingDiagnosis.compute(
            shifts: .fiveSix, tips: .hundredToTwo, cash: .half,
            tracking: .head, goal: .checkAccuracy
        )
        let second = PaydayOnboardingDiagnosis.compute(
            shifts: .fiveSix, tips: .hundredToTwo, cash: .half,
            tracking: .head, goal: .checkAccuracy
        )
        #expect(first == second)
    }

    // MARK: - Projection

    @Test("the projection is shifts per week times tips per shift times 52, to the nearest $500")
    func projectionIsTheirOwnNumbersMultiplied() {
        // 5.5 shifts x $150 x 52 = $42,900 -> $43,000
        let diagnosis = PaydayOnboardingDiagnosis.compute(
            shifts: .fiveSix, tips: .hundredToTwo, cash: nil, tracking: nil, goal: nil
        )
        #expect(diagnosis.projectedAnnualTips == 43_000)
    }

    @Test("the lowest band still lands on a round, plausible figure")
    func lowestBandProjection() {
        // 1.5 shifts x $75 x 52 = $5,850 -> $6,000
        let diagnosis = PaydayOnboardingDiagnosis.compute(
            shifts: .oneTwo, tips: .underHundred, cash: nil, tracking: nil, goal: nil
        )
        #expect(diagnosis.projectedAnnualTips == 6_000)
    }

    @Test("every band combination stays inside the clamp")
    func everyCombinationIsClamped() {
        for shifts in ShiftLoad.allCases {
            for tips in TipsPerShift.allCases {
                let diagnosis = PaydayOnboardingDiagnosis.compute(
                    shifts: shifts, tips: tips, cash: nil, tracking: nil, goal: nil
                )
                #expect(diagnosis.projectedAnnualTips >= 3_000)
                #expect(diagnosis.projectedAnnualTips <= 130_000)
                #expect(diagnosis.projectedAnnualTips % 500 == 0)
            }
        }
    }

    @Test("the headline never restates the figure the count-up already says")
    func headlineDoesNotRepeatTheFigure() {
        for shifts in ShiftLoad.allCases {
            for tips in TipsPerShift.allCases {
                let diagnosis = PaydayOnboardingDiagnosis.compute(
                    shifts: shifts, tips: tips, cash: nil, tracking: nil, goal: nil
                )
                #expect(!diagnosis.headline.contains("$"))
            }
        }
    }

    // MARK: - Substantiation

    @Test("a missing shift count yields no figure at all, never a fabricated one")
    func missingShiftsSuppressesTheFigure() {
        let diagnosis = PaydayOnboardingDiagnosis.compute(
            shifts: nil, tips: .twoToThree, cash: .half, tracking: .head, goal: .realIncome
        )
        #expect(diagnosis.projectedAnnualTips == 0)
        #expect(diagnosis.projectionCaption.isEmpty)
        #expect(!diagnosis.headline.contains("$"))
    }

    @Test("a missing per-shift figure yields no figure at all")
    func missingTipsSuppressesTheFigure() {
        let diagnosis = PaydayOnboardingDiagnosis.compute(
            shifts: .threeFour, tips: nil, cash: .quarter, tracking: nil, goal: nil
        )
        #expect(diagnosis.projectedAnnualTips == 0)
    }

    // MARK: - Cash line

    @Test("the cash figure is the stated share of the projection, to the nearest $500")
    func cashFigureIsAShareOfTheProjection() throws {
        // Half of $43,000 = $21,500.
        let diagnosis = PaydayOnboardingDiagnosis.compute(
            shifts: .fiveSix, tips: .hundredToTwo, cash: .half, tracking: nil, goal: nil
        )
        let cashLine = try #require(diagnosis.cashLine)
        #expect(cashLine.contains("$21,500"))
    }

    @Test("'almost none' asserts no cash figure, since there is none to assert")
    func almostNoCashAssertsNoFigure() throws {
        let diagnosis = PaydayOnboardingDiagnosis.compute(
            shifts: .fiveSix, tips: .hundredToTwo, cash: .almostNone, tracking: nil, goal: nil
        )
        let cashLine = try #require(diagnosis.cashLine)
        #expect(!cashLine.contains("$"))
    }

    @Test("no cash answer means no cash line")
    func noCashAnswerMeansNoCashLine() {
        let diagnosis = PaydayOnboardingDiagnosis.compute(
            shifts: .fiveSix, tips: .hundredToTwo, cash: nil, tracking: nil, goal: nil
        )
        #expect(diagnosis.cashLine == nil)
    }

    // MARK: - Secondary insight

    @Test("the secondary insight is the promise of the goal they picked")
    func secondaryInsightIsTheGoalPromise() {
        for goal in PaydayGoal.allCases {
            let diagnosis = PaydayOnboardingDiagnosis.compute(
                shifts: .threeFour, tips: .twoToThree, cash: .quarter, tracking: .paper, goal: goal
            )
            #expect(diagnosis.secondaryInsight == goal.promise)
        }
    }

    @Test("no goal means no secondary insight")
    func noGoalMeansNoSecondaryInsight() {
        let diagnosis = PaydayOnboardingDiagnosis.compute(
            shifts: .threeFour, tips: .twoToThree, cash: .quarter, tracking: .paper, goal: nil
        )
        #expect(diagnosis.secondaryInsight == nil)
    }
}

@Suite("Onboarding micro-insights — derived arithmetic, not restatement")
struct OnboardingMicroInsightTests {

    @Test("the shift micro-insight reports shifts per year, rounded to ten")
    func shiftsPerYearArithmetic() {
        #expect(ShiftLoad.oneTwo.microInsight.contains("80 shifts a year"))
        #expect(ShiftLoad.threeFour.microInsight.contains("180 shifts a year"))
        #expect(ShiftLoad.fiveSix.microInsight.contains("290 shifts a year"))
        #expect(ShiftLoad.sevenPlus.microInsight.contains("360 shifts a year"))
    }

    @Test("every answer band carries a micro-insight")
    func everyBandHasCopy() {
        for band in ShiftLoad.allCases { #expect(!band.microInsight.isEmpty) }
        for band in TipsPerShift.allCases { #expect(!band.microInsight.isEmpty) }
        for band in CashShare.allCases { #expect(!band.microInsight.isEmpty) }
        for method in TipTrackingMethod.allCases { #expect(!method.microInsight.isEmpty) }
        for goal in PaydayGoal.allCases { #expect(!goal.promise.isEmpty) }
        for frequency in PayFrequency.allCases { #expect(!frequency.onboardingSubtitle.isEmpty) }
    }
}

@Suite("Onboarding stage machine")
struct OnboardingStageTests {

    @Test("there are exactly six numbered question stages, in order")
    func sixQuestionsInOrder() {
        #expect(PaydayOnboardingStage.questionStages.count == 6)
        for (index, stage) in PaydayOnboardingStage.questionStages.enumerated() {
            #expect(stage.questionNumber == index + 1)
        }
    }

    @Test("welcome, analyzing and reveal are not numbered questions")
    func nonQuestionStagesAreUnnumbered() {
        #expect(PaydayOnboardingStage.welcome.questionNumber == nil)
        #expect(PaydayOnboardingStage.analyzing.questionNumber == nil)
        #expect(PaydayOnboardingStage.reveal.questionNumber == nil)
        #expect(PaydayOnboardingStage.account.questionNumber == nil)
    }

    @Test("the stages advance welcome through sign-in and stop there")
    func stagesAdvanceToTheEnd() {
        var stage = PaydayOnboardingStage.welcome
        var visited = [stage]
        while let next = stage.next {
            stage = next
            visited.append(stage)
        }
        #expect(visited == PaydayOnboardingStage.allCases)
        // .account is the terminus: the flow ends by signing in, rather than
        // handing off to a separate sign-in screen.
        #expect(stage == .account)
    }

    @MainActor
    @Test("a fast double tap cannot skip past an unanswered question")
    func doubleTapCannotSkipAQuestion() {
        let viewModel = PaydayOnboardingViewModel()
        viewModel.stage = .shifts
        viewModel.shiftLoad = .threeFour
        viewModel.advanceStage(from: .shifts, reduceMotion: true)
        #expect(viewModel.stage == .tips)
        // The second tap of a double tap still reports the old stage.
        viewModel.advanceStage(from: .shifts, reduceMotion: true)
        #expect(viewModel.stage == .tips)
    }

    @MainActor
    @Test("a question with no answer cannot be advanced past, whatever fires it")
    func unansweredQuestionBlocksAdvance() {
        // The Continue button is one long-lived view now, so it can be handed
        // a refreshed closure carrying the CURRENT stage between two taps of a
        // double tap. The stage check alone would let that through; the
        // answered-question invariant is what actually holds the line.
        let viewModel = PaydayOnboardingViewModel()
        viewModel.stage = .tips
        viewModel.advanceStage(from: .tips, reduceMotion: true)
        #expect(viewModel.stage == .tips)

        viewModel.tipsPerShift = .twoToThree
        viewModel.advanceStage(from: .tips, reduceMotion: true)
        #expect(viewModel.stage == .cash)
    }

    @MainActor
    @Test("the non-question stages still advance without an answer")
    func nonQuestionStagesAdvanceFreely() {
        let viewModel = PaydayOnboardingViewModel()
        #expect(viewModel.stage == .welcome)
        viewModel.advanceStage(from: .welcome, reduceMotion: true)
        #expect(viewModel.stage == .shifts)
    }

    @Test("exactly the six numbered stages report as questions")
    func isQuestionMatchesTheNumberedStages() {
        for stage in PaydayOnboardingStage.allCases {
            #expect(stage.isQuestion == (stage.questionNumber != nil))
        }
        #expect(PaydayOnboardingStage.allCases.filter(\.isQuestion).count == 6)
        #expect(PaydayOnboardingStage.welcome.isQuestion == false)
        #expect(PaydayOnboardingStage.analyzing.isQuestion == false)
        #expect(PaydayOnboardingStage.reveal.isQuestion == false)
        #expect(PaydayOnboardingStage.account.isQuestion == false)
    }

    @MainActor
    @Test("stepping back from the reveal lands on the last question, not the beat")
    func backFromRevealSkipsAnalyzing() {
        let viewModel = PaydayOnboardingViewModel()
        viewModel.stage = .reveal
        viewModel.goToPreviousStage(reduceMotion: true)
        #expect(viewModel.stage == .frequency)
    }

    @MainActor
    @Test("reset clears every answer so nothing leaks into a second run")
    func resetClearsEveryAnswer() {
        let viewModel = PaydayOnboardingViewModel()
        viewModel.stage = .reveal
        viewModel.shiftLoad = .fiveSix
        viewModel.tipsPerShift = .twoToThree
        viewModel.cashShare = .most
        viewModel.trackingMethod = .head
        viewModel.goal = .realIncome
        viewModel.payFrequency = .weekly

        viewModel.reset()

        #expect(viewModel.stage == .welcome)
        #expect(viewModel.shiftLoad == nil)
        #expect(viewModel.tipsPerShift == nil)
        #expect(viewModel.cashShare == nil)
        #expect(viewModel.trackingMethod == nil)
        #expect(viewModel.goal == nil)
        #expect(viewModel.payFrequency == nil)
        #expect(viewModel.selectedID == nil)
    }

    @MainActor
    @Test("selectedID reports the answer for the stage on screen, not another one")
    func selectedIDFollowsTheCurrentStage() {
        let viewModel = PaydayOnboardingViewModel()
        viewModel.shiftLoad = .fiveSix
        viewModel.tipsPerShift = .overThree

        viewModel.stage = .shifts
        #expect(viewModel.selectedID == ShiftLoad.fiveSix.rawValue)
        viewModel.stage = .tips
        #expect(viewModel.selectedID == TipsPerShift.overThree.rawValue)
        viewModel.stage = .cash
        #expect(viewModel.selectedID == nil)
    }
}

@Suite("Onboarding state store")
struct OnboardingStateStoreTests {

    private func makeStore() -> (OnboardingStateStore, UserDefaults) {
        let suiteName = "payday.onboarding.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (OnboardingStateStore(defaults: defaults), defaults)
    }

    @Test("a fresh install has not finished the intro and carries no frequency")
    func freshInstallDefaults() {
        let (store, _) = makeStore()
        #expect(store.hasFinishedIntro == false)
        #expect(store.quizPayFrequency == nil)
    }

    @Test("both values survive a relaunch")
    func valuesPersist() {
        let (store, defaults) = makeStore()
        store.hasFinishedIntro = true
        store.quizPayFrequency = .twiceMonthly

        let reloaded = OnboardingStateStore(defaults: defaults)
        #expect(reloaded.hasFinishedIntro)
        #expect(reloaded.quizPayFrequency == .twiceMonthly)
    }

    @Test("clearing the carried frequency does not resurrect it on relaunch")
    func clearingTheFrequencyPersists() {
        let (store, defaults) = makeStore()
        store.quizPayFrequency = .weekly
        store.clearQuizPayFrequency()

        let reloaded = OnboardingStateStore(defaults: defaults)
        #expect(reloaded.quizPayFrequency == nil)
    }
}
