import SwiftUI

/// A money figure that counts up to its target once and then holds.
///
/// Payday's signature motion: the number arriving rather than simply being
/// printed. Used on the welcome screen's one focal card, where it is what
/// draws the eye to the focal object without that object needing to be the
/// physically largest thing on screen.
///
/// The loop is one cancellable task rather than a fan-out of delayed closures,
/// so leaving the screen mid-count stops every pending step.
struct OnboardingCountUp: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Target in whole dollars.
    let targetDollars: Int
    let font: Font
    var color: Color = PaydayColor.primary
    var duration: Double = 1.0
    var startDelay: Double = 0
    /// Fired once the figure lands, for whatever should follow it.
    var onSettle: (() -> Void)? = nil

    @State private var displayed: Double = 0

    private var settledText: String {
        Money.wholeDollarString(fromCents: targetDollars * 100)
    }

    var body: some View {
        Text(Money.wholeDollarString(fromCents: Int(displayed.rounded()) * 100))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            // VoiceOver reads the figure it lands on, never the rolling digits.
            .accessibilityLabel(settledText)
            .task { await run() }
    }

    private func run() async {
        guard !reduceMotion else {
            displayed = Double(targetDollars)
            onSettle?()
            return
        }
        if startDelay > 0 {
            try? await Task.sleep(for: .seconds(startDelay))
        }
        guard !Task.isCancelled else { return }

        let steps = 60
        let stepDuration = duration / Double(steps)
        for step in 0...steps {
            if Task.isCancelled { return }
            let progress = easeOutCubic(Double(step) / Double(steps))
            withAnimation(.linear(duration: stepDuration)) {
                displayed = Double(targetDollars) * progress
            }
            try? await Task.sleep(for: .seconds(stepDuration))
        }
        guard !Task.isCancelled else { return }
        displayed = Double(targetDollars)
        onSettle?()
    }

    private func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}
