import SwiftUI

/// A short beat between the last question and the reveal, so the reveal feels
/// earned rather than instant. Ported from Vero's `OnboardingAnalyzingView`.
///
/// The steps below are literally what happens: the diagnosis multiplies the
/// shift count by the per-shift figure and applies the cash share. Local timer
/// only, no network, no AI. Nothing here is theater dressed as work.
struct OnboardingAnalyzingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onComplete: () -> Void

    @State private var progress: Double = 0
    @State private var stepIndex = 0

    private let totalDuration: Double = 1.6
    private let tick: Double = 0.04

    private let steps = [
        "Adding up your shifts",
        "Checking the cash split",
        "Putting it together"
    ]

    var body: some View {
        VStack(spacing: PaydaySpacing.lg) {
            Spacer()

            Text("Running your numbers")
                .font(PaydayFont.displaySmall)
                .foregroundStyle(PaydayColor.textPrimary)
                .multilineTextAlignment(.center)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(PaydayColor.primary)
                .frame(maxWidth: 240)

            // One Text with a changing string, NOT .id() + .transition():
            // that pair gives the outgoing and incoming labels separate
            // identities, so both render in the same slot at once and the two
            // sentences overlap into illegible mush mid-crossfade.
            // .contentTransition keeps one identity and fades in place.
            Text(steps[min(stepIndex, steps.count - 1)])
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
                .contentTransition(.opacity)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Running your numbers")
        .accessibilityValue(steps[min(stepIndex, steps.count - 1)])
        // .task is bound to the view's lifetime: back-swiping to a question
        // cancels it, so the final onComplete never fires on the wrong stage
        // and a re-entry starts a single fresh run.
        .task { await run() }
    }

    private func run() async {
        // Reduce Motion gets the beat without the animation: one short pause
        // so the transition still reads as a step, then straight through.
        if reduceMotion {
            progress = 1
            stepIndex = steps.count - 1
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            onComplete()
            return
        }

        let totalTicks = Int(totalDuration / tick)
        for t in 0...totalTicks {
            if Task.isCancelled { return }
            let p = Double(t) / Double(totalTicks)
            withAnimation(.linear(duration: tick)) { progress = p }
            let newStep = min(Int(p * Double(steps.count)), steps.count - 1)
            if newStep != stepIndex {
                withAnimation(.easeInOut(duration: PaydayAnimation.standardDuration)) {
                    stepIndex = newStep
                }
            }
            try? await Task.sleep(for: .seconds(tick))
        }
        guard !Task.isCancelled else { return }
        onComplete()
    }
}

#Preview {
    OnboardingAnalyzingView(onComplete: {})
}
