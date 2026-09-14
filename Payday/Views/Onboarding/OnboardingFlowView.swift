import SwiftUI

/// Hosts the whole pre-account intro: welcome, six questions, the beat, the
/// reveal. Ported from Vero's `OnboardingFlowView`, including the live
/// edge-swipe-back gesture so the screen follows the finger instead of only
/// reacting on release.
///
/// Sits ahead of `PaydayCloudGate` in `RootView`, so a new install sees what
/// the app does before it is ever asked to sign in.
struct OnboardingFlowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Plain reference, not @Bindable: nothing here needs a two-way binding,
    /// and @Observable already tracks the property reads in body.
    let viewModel: PaydayOnboardingViewModel

    /// Called when the intro is done (finished or skipped). Hands the chosen
    /// pay frequency forward so the setup screen never asks it twice.
    var onFinish: (PayFrequency?) -> Void

    /// Live-tracks the edge-swipe-back gesture.
    @State private var edgeDragOffset: CGFloat = 0

    /// True only for the stage change caused by the back gesture, so the
    /// transition reverses to match the swipe instead of always playing the
    /// forward slide. Reset once the change lands.
    @State private var isNavigatingBack = false

    private var quizTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return isNavigatingBack
            ? .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
            : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
    }

    private let totalSteps = PaydayOnboardingStage.questionStages.count

    var body: some View {
        Group {
            switch viewModel.stage {
            case .welcome:
                OnboardingWelcomeView(
                    onStart: { viewModel.advanceStage(from: .welcome, reduceMotion: reduceMotion) },
                    // A returning install already has its answers in the cloud.
                    // Skip straight to the sign-in gate rather than asking
                    // someone to re-describe shifts the app can just restore.
                    onReturning: { onFinish(nil) }
                )
                .transition(quizTransition)

            case .shifts:
                quizStep(
                    stage: .shifts,
                    title: "How many shifts do you work in a typical week?",
                    choices: ShiftLoad.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                    microInsight: viewModel.shiftLoad?.microInsight,
                    onSelect: { viewModel.shiftLoad = ShiftLoad(rawValue: $0) }
                )

            case .tips:
                quizStep(
                    stage: .tips,
                    title: "On a normal shift, what do you walk out with?",
                    choices: TipsPerShift.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                    microInsight: viewModel.tipsPerShift?.microInsight,
                    onSelect: { viewModel.tipsPerShift = TipsPerShift(rawValue: $0) }
                )

            case .cash:
                quizStep(
                    stage: .cash,
                    title: "How much of that is cash?",
                    choices: CashShare.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                    microInsight: viewModel.cashShare?.microInsight,
                    onSelect: { viewModel.cashShare = CashShare(rawValue: $0) }
                )

            case .tracking:
                quizStep(
                    stage: .tracking,
                    title: "How do you keep track of it now?",
                    choices: TipTrackingMethod.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                    microInsight: viewModel.trackingMethod?.microInsight,
                    onSelect: { viewModel.trackingMethod = TipTrackingMethod(rawValue: $0) }
                )

            case .goal:
                quizStep(
                    stage: .goal,
                    title: "What do you want Payday to tell you?",
                    choices: PaydayGoal.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                    microInsight: nil,
                    onSelect: { viewModel.goal = PaydayGoal(rawValue: $0) }
                )

            case .frequency:
                quizStep(
                    stage: .frequency,
                    title: "How often do you get paid?",
                    choices: PayFrequency.allCases.map {
                        OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName, subtitle: $0.onboardingSubtitle)
                    },
                    microInsight: nil,
                    onSelect: { viewModel.payFrequency = PayFrequency(rawValue: $0) }
                )

            case .analyzing:
                OnboardingAnalyzingView(
                    // Only advance if they're still here — guards against a
                    // late timer firing after a back-swipe.
                    onComplete: {
                        if viewModel.stage == .analyzing {
                            viewModel.goToStage(.reveal, reduceMotion: reduceMotion)
                        }
                    }
                )
                .transition(.opacity)

            case .reveal:
                OnboardingRevealView(
                    diagnosis: viewModel.diagnosis,
                    onContinue: { onFinish(viewModel.payFrequency) }
                )
                .transition(.opacity)
            }
        }
        .offset(x: edgeDragOffset)
        .animation(reduceMotion ? nil : PaydayAnimation.paperSpring, value: viewModel.stage)
        .simultaneousGesture(edgeSwipeBack)
        .onChange(of: viewModel.stage) { _, _ in
            // The direction flag only needs to hold for the transition it
            // triggered.
            isNavigatingBack = false
        }
#if DEBUG || targetEnvironment(simulator)
        .task { viewModel.applyDebugStageIfRequested() }
#endif
    }

    // MARK: - Question Stage

    private func quizStep(
        stage: PaydayOnboardingStage,
        title: String,
        choices: [OnboardingQuizChoice],
        microInsight: String?,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        OnboardingQuizStepView(
            stepNumber: stage.questionNumber ?? 1,
            totalSteps: totalSteps,
            title: title,
            choices: choices,
            selectedID: viewModel.selectedID,
            microInsight: microInsight,
            onSelect: onSelect,
            onContinue: { viewModel.advanceStage(from: stage, reduceMotion: reduceMotion) }
        )
        .transition(quizTransition)
    }

    // MARK: - Edge Swipe Back

    private var edgeSwipeBack: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { gesture in
                guard gesture.startLocation.x <= 30, viewModel.stage != .welcome else { return }
                let translation = gesture.translation.width
                if translation <= 0 {
                    edgeDragOffset = 0
                } else if translation > 100 {
                    // Rubber band past the commit threshold — real things slow
                    // before they stop.
                    edgeDragOffset = 100 + ((translation - 100) * 0.3)
                } else {
                    edgeDragOffset = translation
                }
            }
            .onEnded { gesture in
                guard gesture.startLocation.x <= 30, viewModel.stage != .welcome else {
                    withAnimation(reduceMotion ? nil : PaydayAnimation.paperSpring) { edgeDragOffset = 0 }
                    return
                }
                let shouldGoBack = gesture.translation.width > 60 || gesture.velocity.width > 500
                withAnimation(reduceMotion ? nil : PaydayAnimation.paperSpring) {
                    edgeDragOffset = 0
                    if shouldGoBack {
                        isNavigatingBack = true
                        viewModel.goToPreviousStage(reduceMotion: reduceMotion)
                    }
                }
            }
    }
}
