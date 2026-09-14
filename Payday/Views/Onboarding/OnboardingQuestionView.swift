import SwiftUI

/// A single selectable answer in the intro quiz.
struct OnboardingQuizChoice: Identifiable, Equatable {
    /// rawValue of the backing enum.
    let id: String
    let label: String
    var subtitle: String? = nil
}

/// The inside of one question: the title, the answers, and the micro-insight
/// that appears once something is picked. Deliberately just the contents —
/// the progress dots and the Continue button belong to `OnboardingQuizShell`,
/// which persists across every question so that advancing changes only this
/// view and never the frame around it.
///
/// Purely presentational: no stores, no environment objects. `OnboardingFlowView`
/// owns the answer state.
struct OnboardingQuestionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let choices: [OnboardingQuizChoice]
    /// rawValue of the currently selected choice, if any.
    let selectedID: String?
    /// Micro-insight for the current selection, shown once something is picked.
    let microInsight: String?
    let onSelect: (String) -> Void

    var body: some View {
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
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .padding(.horizontal, PaydaySpacing.md)
            .padding(.bottom, PaydaySpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Scoped to this view's own selection so picking an answer animates
        // the micro-insight in place. The step-to-step transition is the
        // shell's business, not this one's.
        .animation(reduceMotion ? nil : PaydayAnimation.entrance, value: selectedID)
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
    OnboardingQuestionView(
        title: "How many shifts do you work in a typical week?",
        choices: ShiftLoad.allCases.map { OnboardingQuizChoice(id: $0.rawValue, label: $0.displayName) },
        selectedID: ShiftLoad.threeFour.rawValue,
        microInsight: ShiftLoad.threeFour.microInsight,
        onSelect: { _ in }
    )
    .background(PaydayColor.background)
}
