import SwiftUI

/// The persistent frame around the six question screens: progress dots pinned
/// at the top, the Continue button pinned at the bottom, and a slot between
/// them for whichever question is on screen.
///
/// Why this exists. The chrome used to live *inside* each question view, so
/// every step was a complete screen and advancing slid the dots and the button
/// along with the content. That reads as a page turn rather than as answering
/// the next question in a form you are already inside — Tyler, 2026-09-14:
/// "the whole page changes, including the little progress bar at the top… it's
/// like complete pages instead of just the inside changing."
///
/// Now the dots and the button are a single long-lived view each. They are
/// never reinserted, so they cannot move: the dots interpolate their own fill
/// in place, the button only changes enabled state, and the transition is
/// confined to the slot.
struct OnboardingQuizShell<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 1-based position among the question stages.
    let stepNumber: Int
    let totalSteps: Int
    let isContinueEnabled: Bool
    /// Live edge-swipe-back translation. Applied to the slot only, so the
    /// frame stays put while the question tracks the finger.
    let contentOffset: CGFloat
    let onContinue: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, PaydaySpacing.md)

            // A ZStack holds the slot's geometry steady while the outgoing and
            // incoming questions briefly coexist mid-transition. In a plain
            // VStack the two would contend for layout and nudge the dots and
            // button — the exact jitter this view exists to remove. Clipping
            // keeps a sliding question from drawing over the chrome.
            ZStack(alignment: .top) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .offset(x: contentOffset)
            .clipped()

            Button(action: onContinue) {
                Text("Continue")
                    .font(PaydayFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PaydaySpacing.xxs)
            }
            .buttonStyle(.glassProminent)
            .tint(PaydayColor.primary)
            .disabled(!isContinueEnabled)
            .padding(.horizontal, PaydaySpacing.md)
            .padding(.bottom, PaydaySpacing.md)
            .animation(reduceMotion ? nil : PaydayAnimation.entrance, value: isContinueEnabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
    }

    /// Six capsules; the active one widens rather than changing color, so
    /// position reads at a glance without a second signal doing the same job.
    /// Because this view now persists across questions, that width change
    /// interpolates instead of being rebuilt already at its new size.
    private var progressDots: some View {
        HStack(spacing: PaydaySpacing.xxs) {
            ForEach(1...totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= stepNumber ? PaydayColor.primary : PaydayColor.fieldBackground)
                    .frame(width: i == stepNumber ? 20 : 8, height: 8)
            }
        }
        .animation(reduceMotion ? nil : PaydayAnimation.progressMorph, value: stepNumber)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Question \(stepNumber) of \(totalSteps)")
    }
}

#Preview {
    OnboardingQuizShell(
        stepNumber: 3,
        totalSteps: 6,
        isContinueEnabled: true,
        contentOffset: 0,
        onContinue: {}
    ) {
        OnboardingQuestionView(
            title: "How much of that is cash?",
            choices: CashShare.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
            selectedID: CashShare.half.rawValue,
            microInsight: CashShare.half.microInsight,
            onSelect: { _ in }
        )
    }
}
