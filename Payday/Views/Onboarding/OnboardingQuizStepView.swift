import SwiftUI

/// A single selectable answer in the intro quiz.
struct OnboardingQuizChoice: Identifiable, Equatable {
    /// rawValue of the backing enum.
    let id: String
    let label: String
    var subtitle: String? = nil
}

/// One question, one screen, single select — ported from Vero's
/// `OnboardingQuizStepView`. Purely presentational: no stores, no environment
/// objects. `OnboardingFlowView` owns the answer state.
struct OnboardingQuizStepView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 1-based position among the six question stages.
    let stepNumber: Int
    let totalSteps: Int
    let title: String
    let choices: [OnboardingQuizChoice]
    /// rawValue of the currently selected choice, if any.
    let selectedID: String?
    /// Micro-insight for the current selection, shown once something is picked.
    let microInsight: String?
    let onSelect: (String) -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, PaydaySpacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: PaydaySpacing.lg) {
                    Text(title)
                        .font(PaydayFont.displayMedium)
                        .foregroundStyle(PaydayColor.textPrimary)
                        .multilineTextAlignment(.leading)
                        .padding(.top, PaydaySpacing.xl)

                    VStack(spacing: PaydaySpacing.xs) {
                        ForEach(choices) { choice in
                            choiceRow(choice)
                        }
                    }

                    if let microInsight, selectedID != nil {
                        Text(microInsight)
                            .font(PaydayFont.subheadline)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, PaydaySpacing.md)
                .padding(.bottom, PaydaySpacing.xl)
            }

            Button(action: onContinue) {
                Text("Continue")
                    .font(PaydayFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PaydaySpacing.xxs)
            }
            .buttonStyle(.glassProminent)
            .tint(PaydayColor.primary)
            .disabled(selectedID == nil)
            .padding(.horizontal, PaydaySpacing.md)
            .padding(.bottom, PaydaySpacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
        .animation(reduceMotion ? nil : PaydayAnimation.paperSpring, value: selectedID)
    }

    /// Six capsules; the current one widens rather than changing color, so
    /// position reads at a glance without a second signal doing the same job.
    private var progressDots: some View {
        HStack(spacing: PaydaySpacing.xxs) {
            ForEach(1...totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= stepNumber ? PaydayColor.primary : PaydayColor.fieldBackground)
                    .frame(width: i == stepNumber ? 20 : 8, height: 8)
                    .animation(reduceMotion ? nil : PaydayAnimation.paperSpring, value: stepNumber)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Question \(stepNumber) of \(totalSteps)")
    }

    private func choiceRow(_ choice: OnboardingQuizChoice) -> some View {
        let isSelected = choice.id == selectedID
        return Button {
            PaydayHaptics.selection()
            onSelect(choice.id)
        } label: {
            HStack(spacing: PaydaySpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.label)
                        .font(PaydayFont.body)
                        .foregroundStyle(PaydayColor.textPrimary)
                    if let subtitle = choice.subtitle {
                        Text(subtitle)
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                }
                Spacer(minLength: PaydaySpacing.xs)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(PaydayFont.iconMedium)
                    .foregroundStyle(isSelected ? PaydayColor.primary : PaydayColor.textTertiary)
            }
            .padding(PaydaySpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PaydayRadius.lg, style: .continuous)
                    .fill(PaydayColor.fieldBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: PaydayRadius.lg, style: .continuous)
                            .stroke(isSelected ? PaydayColor.primary : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    OnboardingQuizStepView(
        stepNumber: 1,
        totalSteps: 6,
        title: "How many shifts do you work in a typical week?",
        choices: ShiftLoad.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
        selectedID: ShiftLoad.threeFour.rawValue,
        microInsight: ShiftLoad.threeFour.microInsight,
        onSelect: { _ in },
        onContinue: {}
    )
}
