import AuthenticationServices
import SwiftUI

/// Hosts the whole pre-account intro: welcome, six questions, the beat, the
/// reveal. Ported from Vero's `OnboardingFlowView`, including the live
/// edge-swipe-back gesture so the screen follows the finger instead of only
/// reacting on release.
///
/// Rendered by `PaydayCloudGate`'s signed-out branch, which makes this the
/// app's ONE front door: not signed in means you see the welcome screen,
/// whether it is a first launch or you just signed out. The flow ends at
/// `.account`, which hosts the Sign in with Apple button itself, so there is
/// no plainer sign-in screen to fall through to.
///
/// The six questions share ONE `OnboardingQuizShell`. They are a single branch
/// of the switch below, which is what keeps the shell's identity stable across
/// them: the dots and the Continue button are the same views the whole way
/// through, and only the slot's contents transition. Vero, which this was
/// ported from, still rebuilds its chrome on every step.
struct OnboardingFlowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Plain reference, not @Bindable: nothing here needs a two-way binding,
    /// and @Observable already tracks the property reads in body.
    let viewModel: PaydayOnboardingViewModel

    /// True once this device has been through the quiz before, so a returning
    /// person is offered sign-in first instead of six questions again.
    let hasCompletedQuizBefore: Bool

    /// Called when the quiz finishes, to hand the chosen pay frequency forward
    /// so the setup screen never asks for it twice.
    var onQuizCompleted: (PayFrequency?) -> Void

    /// The Apple authorization result, handed to the gate to exchange for a
    /// session. The flow stays on `.account` until that succeeds.
    var onAuthorize: ((authorization: Result<ASAuthorization, Error>, nonce: String)) -> Void

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
                    hasCompletedQuizBefore: hasCompletedQuizBefore,
                    onStart: { viewModel.advanceStage(from: .welcome, reduceMotion: reduceMotion) },
                    // A returning install already has its answers in the
                    // cloud. Jump to sign-in rather than asking someone to
                    // re-describe shifts the app is about to restore anyway.
                    onReturning: { viewModel.goToStage(.account, reduceMotion: reduceMotion) }
                )
                .transition(quizTransition)

            case .shifts, .tips, .cash, .tracking, .goal, .frequency:
                questionShell
                    .transition(quizTransition)

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
                    onContinue: {
                        // Persist the one answer a shipped feature reads before
                        // moving on, because the flow may end here for a while:
                        // .account waits on the person, not on a timer.
                        onQuizCompleted(viewModel.payFrequency)
                        viewModel.advanceStage(from: .reveal, reduceMotion: reduceMotion)
                    }
                )
                .transition(.opacity)

            case .account:
                OnboardingAccountView(
                    didCompleteQuiz: viewModel.shiftLoad != nil,
                    onAuthorize: onAuthorize
                )
                .transition(quizTransition)
            }
        }
        // On a question the shell handles the drag itself, moving only the
        // slot so the chrome stays put. Everywhere else there is no chrome to
        // hold still, so the whole screen tracks the finger as before.
        .offset(x: viewModel.stage.isQuestion ? 0 : edgeDragOffset)
        .animation(reduceMotion ? nil : PaydayAnimation.stepSlide, value: viewModel.stage)
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

    // MARK: - Questions

    /// One shell for all six questions. `stage` is captured here rather than
    /// read inside the closure so the Continue action carries the stage as of
    /// this render — which is what keeps the double-tap guard in
    /// `advanceStage` meaningful now that the button is no longer rebuilt on
    /// every step.
    private var questionShell: some View {
        let stage = viewModel.stage
        return OnboardingQuizShell(
            stepNumber: stage.questionNumber ?? 1,
            totalSteps: totalSteps,
            isContinueEnabled: viewModel.selectedID != nil,
            contentOffset: edgeDragOffset,
            onContinue: { viewModel.advanceStage(from: stage, reduceMotion: reduceMotion) }
        ) {
            questionContent
                // The identity that makes the slot — and only the slot —
                // transition when the stage changes.
                .id(stage)
                .transition(quizTransition)
        }
    }

    @ViewBuilder
    private var questionContent: some View {
        switch viewModel.stage {
        case .shifts:
            OnboardingQuestionView(
                title: "How many shifts do you work in a typical week?",
                choices: ShiftLoad.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                selectedID: viewModel.shiftLoad?.rawValue,
                microInsight: viewModel.shiftLoad?.microInsight,
                onSelect: { viewModel.shiftLoad = ShiftLoad(rawValue: $0) }
            )

        case .tips:
            OnboardingQuestionView(
                title: "On a normal shift, what do you walk out with?",
                choices: TipsPerShift.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                selectedID: viewModel.tipsPerShift?.rawValue,
                microInsight: viewModel.tipsPerShift?.microInsight,
                onSelect: { viewModel.tipsPerShift = TipsPerShift(rawValue: $0) }
            )

        case .cash:
            OnboardingQuestionView(
                title: "How much of that is cash?",
                choices: CashShare.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                selectedID: viewModel.cashShare?.rawValue,
                microInsight: viewModel.cashShare?.microInsight,
                onSelect: { viewModel.cashShare = CashShare(rawValue: $0) }
            )

        case .tracking:
            OnboardingQuestionView(
                title: "How do you keep track of it now?",
                choices: TipTrackingMethod.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                selectedID: viewModel.trackingMethod?.rawValue,
                microInsight: viewModel.trackingMethod?.microInsight,
                onSelect: { viewModel.trackingMethod = TipTrackingMethod(rawValue: $0) }
            )

        case .goal:
            OnboardingQuestionView(
                title: "What do you want Payday to tell you?",
                choices: PaydayGoal.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
                selectedID: viewModel.goal?.rawValue,
                microInsight: nil,
                onSelect: { viewModel.goal = PaydayGoal(rawValue: $0) }
            )

        case .frequency:
            OnboardingQuestionView(
                title: "How often do you get paid?",
                choices: PayFrequency.allCases.map {
                    OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName, subtitle: $0.onboardingSubtitle)
                },
                selectedID: viewModel.payFrequency?.rawValue,
                microInsight: nil,
                onSelect: { viewModel.payFrequency = PayFrequency(rawValue: $0) }
            )

        default:
            EmptyView()
        }
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
                // Committing travels, so it uses the panel curve. A cancelled
                // drag is the system answering the finger, and Emil's rule for
                // that is simple: release is always snappy.
                let release = shouldGoBack ? PaydayAnimation.stepSlide : PaydayAnimation.paperSpring
                withAnimation(reduceMotion ? nil : release) {
                    edgeDragOffset = 0
                    if shouldGoBack {
                        isNavigatingBack = true
                        viewModel.goToPreviousStage(reduceMotion: reduceMotion)
                    }
                }
            }
    }
}
