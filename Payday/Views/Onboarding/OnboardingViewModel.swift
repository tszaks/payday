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
        withAnimation(reduceMotion ? nil : PaydayAnimation.paperSpring) {
            stage = newStage
        }
    }

    /// Advance one stage. `expectedStage` is the stage the tapped screen
    /// belongs to: a fast double-tap fires this twice, and the first call
    /// already moved `stage` forward, so the second is rejected here instead of
    /// skipping the next, unanswered question.
    func advanceStage(from expectedStage: PaydayOnboardingStage, reduceMotion: Bool) {
        guard stage == expectedStage, let next = stage.next else { return }
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

        shiftLoad = .fiveSix
        tipsPerShift = .hundredToTwo
        cashShare = .half
        trackingMethod = .head
        goal = .checkAccuracy
        payFrequency = .biweekly
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
