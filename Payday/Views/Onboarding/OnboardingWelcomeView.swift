import SwiftUI

/// The first screen of a new install. Same shape as Vero's `WelcomeView` —
/// mark and name, a preview of what the app actually says, then one green CTA
/// with a quieter returning-user escape hatch underneath.
///
/// Where Vero previews chat bubbles, Payday previews its own hero artifact:
/// three cards, one for each beat of the loop in docs/PRODUCT.md (end of
/// shift, between shifts, payday). Every card is label, amount, evidence —
/// the app's whole promise in three lines, no feature list.
struct OnboardingWelcomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onStart: () -> Void
    var onReturning: () -> Void

    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: PaydaySpacing.lg) {
            Spacer()

            VStack(spacing: PaydaySpacing.sm) {
                Image("BrandMark")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 76, height: 76)
                    .foregroundStyle(PaydayColor.primary)
                    .accessibilityHidden(true)

                Text("Payday")
                    .font(PaydayFont.displayLarge)
                    .foregroundStyle(PaydayColor.textPrimary)

                Text("Know what you actually make.")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
            }

            Spacer(minLength: PaydaySpacing.md)

            VStack(spacing: PaydaySpacing.sm) {
                previewCard(
                    label: "Tonight",
                    amount: "$186",
                    evidence: "$34 above your Friday average.",
                    delay: 0.15
                )
                previewCard(
                    label: "This period",
                    amount: "$1,240",
                    evidence: "$120 ahead of last period at this point.",
                    delay: 0.30
                )
                previewCard(
                    label: "Payday",
                    amount: "$618",
                    evidence: "What your check's tips line should read.",
                    delay: 0.45
                )
            }

            Spacer()

            VStack(spacing: PaydaySpacing.sm) {
                // Full width comes from the frame on the LABEL, not on the
                // Button: .glassProminent draws its capsule around the label,
                // so an outer frame only stretches the hit area and leaves a
                // content-hugging pill floating in the middle.
                Button(action: onStart) {
                    Text("Get Started")
                        .font(PaydayFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PaydaySpacing.xxs)
                }
                .buttonStyle(.glassProminent)
                .tint(PaydayColor.primary)

                Button("I've used Payday before", action: onReturning)
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textPrimary)
                    .buttonStyle(PressableButtonStyle())
                    .padding(.top, PaydaySpacing.xxs)
            }
        }
        .padding(.horizontal, PaydaySpacing.md)
        .padding(.bottom, PaydaySpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
        .onAppear { hasAppeared = true }
    }

    /// One preview card. Label, amount, evidence — the same three-part shape
    /// every real card in the app uses, so this screen is a true sample of it
    /// rather than marketing art.
    private func previewCard(label: String, amount: String, evidence: String, delay: Double) -> some View {
        VStack(alignment: .leading, spacing: PaydaySpacing.xxs) {
            Text(label.uppercased())
                .font(PaydayFont.caption3)
                .tracking(0.6)
                .foregroundStyle(PaydayColor.textSecondary)

            Text(amount)
                .font(PaydayFont.displayCompact)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)

            Text(evidence)
                .font(PaydayFont.footnote)
                .foregroundStyle(PaydayColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paydayCard(padding: PaydaySpacing.md, cornerRadius: PaydayRadius.lg)
        .opacity(reduceMotion || hasAppeared ? 1 : 0)
        .offset(y: reduceMotion || hasAppeared ? 0 : 12)
        .animation(
            reduceMotion ? nil : .easeOut(duration: PaydayAnimation.premiumDuration).delay(delay),
            value: hasAppeared
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingWelcomeView(onStart: {}, onReturning: {})
}
