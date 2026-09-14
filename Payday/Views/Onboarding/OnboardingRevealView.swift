import SwiftUI

/// The payoff screen: what a year of the shifts they just described adds up
/// to, how much of it is cash, and what the app will do about the goal they
/// picked. Ported from Vero's `OnboardingRevealView` — same staged appearance
/// and count-up choreography.
///
/// Takes a plain `PaydayOnboardingDiagnosis` value. No SwiftData, no stores,
/// no network: every figure here is arithmetic on the quiz answers.
struct OnboardingRevealView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let diagnosis: PaydayOnboardingDiagnosis
    var onContinue: () -> Void

    @State private var showHeadline = false
    @State private var showAmount = false
    @State private var showDetails = false
    @State private var showButton = false
    @State private var displayedAmount: Double = 0

    private let countUpDuration: Double = 1.4

    private var projectionText: String {
        Money.wholeDollarString(fromCents: Int(displayedAmount.rounded()) * 100)
    }

    private var finalProjectionText: String {
        Money.wholeDollarString(fromCents: diagnosis.projectedAnnualTips * 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            // A bare ScrollView sizes to its content, which pins everything to
            // the top and leaves dead space below. Matching the scroll
            // content's minimum height to the space actually available centers
            // it when it fits and lets it scroll when it doesn't.
            //
            // ViewThatFits cannot do this job: it measures a subview's IDEAL
            // height, and wrapping Text reports its single-line height there,
            // so the non-scrolling branch always "fits" and the copy gets
            // clipped at accessibility text sizes.
            GeometryReader { proxy in
                ScrollView {
                    revealContent
                        .padding(.vertical, PaydaySpacing.xl)
                        .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            // Always laid out, never conditionally inserted: an `if` here would
            // change the height GeometryReader above measures and jolt the
            // centered content sideways the moment the button appeared.
            Button(action: onContinue) {
                Text("Set up Payday")
                    .font(PaydayFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PaydaySpacing.xxs)
            }
            .buttonStyle(.glassProminent)
            .tint(PaydayColor.primary)
            .padding(.horizontal, PaydaySpacing.md)
            .padding(.bottom, PaydaySpacing.md)
            .opacity(showButton ? 1 : 0)
            .offset(y: showButton ? 0 : 12)
            .allowsHitTesting(showButton)
            .accessibilityHidden(!showButton)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
        .task { await runRevealSequence() }
    }

    // MARK: - Content

    private var revealContent: some View {
        VStack(spacing: PaydaySpacing.lg) {
                    if showHeadline {
                        Text(diagnosis.headline)
                            .font(PaydayFont.title)
                            .foregroundStyle(PaydayColor.textPrimary)
                            .multilineTextAlignment(.center)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }

                    // Only ever shown when the answers actually produced a
                    // figure. Never count up to a number the inputs don't
                    // substantiate.
                    if showAmount, diagnosis.projectedAnnualTips > 0 {
                        VStack(spacing: PaydaySpacing.xxs) {
                            Text(projectionText)
                                .font(PaydayFont.displayHero)
                                .monospacedDigit()
                                .foregroundStyle(PaydayColor.primary)
                                .contentTransition(.numericText())
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)

                            Text(diagnosis.projectionCaption)
                                .font(PaydayFont.subheadline)
                                .foregroundStyle(PaydayColor.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, PaydaySpacing.lg)
                        .padding(.horizontal, PaydaySpacing.md)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: PaydayRadius.xl, style: .continuous)
                                .fill(PaydayColor.fieldBackground)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.88)))
                        // VoiceOver reads the settled figure, not the rolling digits.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(finalProjectionText) \(diagnosis.projectionCaption)")
                    }

                    if showDetails {
                        VStack(spacing: PaydaySpacing.sm) {
                            if let cashLine = diagnosis.cashLine {
                                Text(cashLine)
                                    .font(PaydayFont.body)
                                    .foregroundStyle(PaydayColor.textPrimary)
                                    .multilineTextAlignment(.center)
                            }
                            if let secondary = diagnosis.secondaryInsight {
                                Text(secondary)
                                    .font(PaydayFont.subheadline)
                                    .foregroundStyle(PaydayColor.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .transition(.opacity)
                    }

        }
        .padding(.horizontal, PaydaySpacing.md)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Animation Sequence

    /// One cancellable task rather than a fan-out of delayed closures, so
    /// leaving the screen mid-reveal stops every pending step.
    private func runRevealSequence() async {
        guard !reduceMotion else {
            displayedAmount = Double(diagnosis.projectedAnnualTips)
            showHeadline = true
            showAmount = true
            showDetails = true
            showButton = true
            return
        }

        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: PaydayAnimation.smoothDuration)) { showHeadline = true }

        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: PaydayAnimation.smoothDuration)) { showAmount = true }

        try? await Task.sleep(for: .milliseconds(200))
        await countUp()
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: PaydayAnimation.smoothDuration)) { showDetails = true }

        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: PaydayAnimation.smoothDuration)) { showButton = true }
    }

    private func countUp() async {
        let target = Double(diagnosis.projectedAnnualTips)
        guard target > 0 else { return }
        let steps = 60
        let stepDuration = countUpDuration / Double(steps)
        for step in 0...steps {
            if Task.isCancelled { return }
            let progress = easeOutCubic(Double(step) / Double(steps))
            withAnimation(.linear(duration: stepDuration)) {
                displayedAmount = target * progress
            }
            try? await Task.sleep(for: .seconds(stepDuration))
        }
        guard !Task.isCancelled else { return }
        displayedAmount = target
        PaydayHaptics.success()
    }

    private func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}

#Preview {
    OnboardingRevealView(
        diagnosis: PaydayOnboardingDiagnosis.compute(
            shifts: .fiveSix,
            tips: .hundredToTwo,
            cash: .half,
            tracking: .head,
            goal: .checkAccuracy
        ),
        onContinue: {}
    )
}
