import SwiftUI

/// Holds the intro flow's state: the quiz answers, the stage machine, and the
/// derived diagnosis. Ported from Vero's `OnboardingViewModel`, converted to
/// `@Observable` to match Payday's own store pattern rather than Vero's older
/// `ObservableObject`.
///
/// Owned by `RootView` as `@State` so answers survive across stages, and read
/// once on exit to hand the pay frequency forward.
@MainActor
@Observable
final class PaydayOnboardingViewModel {
    var stage: PaydayOnboardingStage = .welcome

    var shiftLoad: ShiftLoad?
    var tipsPerShift: TipsPerShift?
    var cashShare: CashShare?
    var trackingMethod: TipTrackingMethod?
    var goal: PaydayGoal?
    var payFrequency: PayFrequency?

    /// Personalized reading derived purely from the answers above (no I/O).
    var diagnosis: PaydayOnboardingDiagnosis {
        PaydayOnboardingDiagnosis.compute(
            shifts: shiftLoad,
            tips: tipsPerShift,
            cash: cashShare,
            tracking: trackingMethod,
            goal: goal
        )
    }

    /// The answer id currently selected on `stage`, if any. Nil on non-question
    /// stages, which is also what disables the Continue button.
    var selectedID: String? {
        switch stage {
        case .shifts: shiftLoad?.rawValue
        case .tips: tipsPerShift?.rawValue
        case .cash: cashShare?.rawValue
        case .tracking: trackingMethod?.rawValue
        case .goal: goal?.rawValue
        case .frequency: payFrequency?.rawValue
        default: nil
        }
    }

    // MARK: - Stage Navigation

    func goToStage(_ newStage: PaydayOnboardingStage, reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : PaydayAnimation.stepSlide) {
            stage = newStage
        }
    }

    /// Advance one stage. `expectedStage` is the stage the tapped control
    /// belonged to when it was rendered, so a fast double-tap whose first call
    /// already moved `stage` forward is rejected instead of skipping ahead.
    ///
    /// The Continue button is now a single long-lived view inside
    /// `OnboardingQuizShell` rather than one button per step, so that check
    /// alone is no longer airtight — SwiftUI may hand the button a refreshed
    /// closure between the two taps. The invariant is therefore enforced here
    /// where it actually belongs: never leave a question with no answer.
    func advanceStage(from expectedStage: PaydayOnboardingStage, reduceMotion: Bool) {
        guard stage == expectedStage else { return }
        guard !stage.isQuestion || selectedID != nil else { return }
        guard let next = stage.next else { return }
        goToStage(next, reduceMotion: reduceMotion)
    }

    /// Step back one stage, skipping the transient `.analyzing` beat so a
    /// back-swipe from the reveal lands on the last question rather than an
    /// auto-advancing loading screen.
    func goToPreviousStage(reduceMotion: Bool) {
        guard var prev = stage.previous else { return }
        if prev == .analyzing, let before = prev.previous {
            prev = before
        }
        goToStage(prev, reduceMotion: reduceMotion)
    }

    // MARK: - Debug

#if DEBUG || targetEnvironment(simulator)
    /// QA/screenshot hook, same house pattern as `-DebugForcePaydayMoment` and
    /// `-DebugExpandBreakdown`: `-DebugOnboardingStage reveal` opens straight
    /// to that screen with a representative set of answers already filled in,
    /// so every stage can be inspected without tapping through the whole flow.
    func applyDebugStageIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DebugOnboardingStage"),
              arguments.count > index + 1,
              let requested = PaydayOnboardingStage(rawValue: arguments[index + 1])
        else { return }

        // Fill only the answers that PRECEDE the requested stage, so the flow
        // opens in the state it would genuinely be in at that point. Filling
        // all of them would leave the requested question already answered,
        // hiding the disabled-to-enabled Continue state — the one thing you
        // most want to see when reviewing the step transition.
        let questions = PaydayOnboardingStage.questionStages
        let fillCount: Int
        switch requested {
        case .welcome: fillCount = 0
        case .analyzing, .reveal: fillCount = questions.count
        default: fillCount = questions.firstIndex(of: requested) ?? 0
        }
        for question in questions.prefix(fillCount) {
            switch question {
            case .shifts: shiftLoad = .fiveSix
            case .tips: tipsPerShift = .hundredToTwo
            case .cash: cashShare = .half
            case .tracking: trackingMethod = .head
            case .goal: goal = .checkAccuracy
            case .frequency: payFrequency = .biweekly
            default: break
            }
        }
        stage = requested
    }
#endif

    // MARK: - Reset

    /// Clear every answer and return to the welcome screen, so answers can't
    /// leak into a second attempt or a different person on the same device.
    func reset() {
        stage = .welcome
        shiftLoad = nil
        tipsPerShift = nil
        cashShare = nil
        trackingMethod = nil
        goal = nil
        payFrequency = nil
    }
}
