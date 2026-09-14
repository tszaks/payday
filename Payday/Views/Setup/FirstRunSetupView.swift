import SwiftUI

/// The last step of the intro: the two dates the app can't derive. Restyled
/// (2026-09-14) to continue the quiz's visual language rather
/// than drop into a grouped `Form` — same big left-aligned title, same
/// `fieldBackground` rows at `PaydayRadius.lg`, same green prominent CTA
/// pinned above the safe area. A stranger should not be able to tell where the
/// quiz ended and this began.
///
/// The name is deliberately NOT asked here. Sign in with Apple hands over
/// `fullName` on first authorization and `AppleIdentityProfile.newFirstName`
/// stores it (see PaydayCloudGate), and the gate runs before this screen — so
/// a field here would ask for something the app already knows. Anyone Apple
/// gave no name for (a reinstall returns nil `fullName`) sets it in Settings.
///
/// Asks for two dates a person can read straight off a pay stub — no mental
/// math. Most payroll pays a few days after a period actually ends, so asking
/// for the payday and the period-end separately lets the app work out that lag
/// itself instead of assuming zero (which silently misplaces every period
/// boundary for anyone paid on a delay).
///
/// Pay frequency is NOT asked here when the intro quiz already collected it
/// (DESIGN.md rule 11, "say it once"); the picker appears only for someone who
/// skipped the intro. Everything is editable later from Settings.
struct FirstRunSetupView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(OnboardingStateStore.self) private var onboardingStore

    @State private var frequency: PayFrequency = .biweekly
    @State private var mostRecentPayday: Date = .now
    @State private var periodEndDate: Date = .now
    @State private var hasLoadedQuizFrequency = false

    /// True when the quiz already answered this, so the picker stays hidden.
    private var frequencyIsKnown: Bool { onboardingStore.quizPayFrequency != nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PaydaySpacing.lg) {
                    // One title, not a title plus a group header that
                    // paraphrases it (DESIGN.md rule 11). With the name field
                    // gone this screen asks exactly one thing.
                    Text("Last thing — your pay schedule.")
                        .font(PaydayFont.displayMedium)
                        .foregroundStyle(PaydayColor.textPrimary)
                        .padding(.top, PaydaySpacing.xl)

                    VStack(alignment: .leading, spacing: PaydaySpacing.xs) {
                        if !frequencyIsKnown {
                            frequencyRows
                        }

                        // Separated from the frequency options above: picking
                        // one of four and setting two dates are different
                        // asks, and at the same 8pt gap they read as one
                        // undifferentiated stack of rows.
                        VStack(spacing: PaydaySpacing.xs) {
                            dateRow(
                                label: "Last payday",
                                selection: $mostRecentPayday,
                                range: ...Date.now
                            )
                            .onChange(of: mostRecentPayday) { _, newValue in
                                if periodEndDate > newValue { periodEndDate = newValue }
                            }

                            dateRow(
                                label: "Last day it covered",
                                selection: $periodEndDate,
                                range: ...mostRecentPayday
                            )
                        }
                        .padding(.top, frequencyIsKnown ? 0 : PaydaySpacing.xs)

                        Text("Both dates come straight off your last pay stub. Payday works out the lag between them on its own.")
                            .font(PaydayFont.footnote)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .padding(.top, PaydaySpacing.xxs)
                    }
                }
                .padding(.horizontal, PaydaySpacing.md)
                .padding(.bottom, PaydaySpacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaydayColor.background)
        // A welcome screen's commit control needs one-thumb reach and to
        // unmistakably read as "the next step," not as an edit screen's small
        // top-right Done — full-width and pinned above the safe area, the
        // app's standard prominent button style.
        .safeAreaInset(edge: .bottom) {
            Button { save() } label: {
                Text("Start tracking")
                    .font(PaydayFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PaydaySpacing.xxs)
            }
            .buttonStyle(.glassProminent)
            .tint(PaydayColor.primary)
            .padding(.horizontal, PaydaySpacing.md)
            .padding(.top, PaydaySpacing.sm)
            .padding(.bottom, PaydaySpacing.xs)
            .background(PaydayColor.background)
        }
        .task {
            // Carry the quiz's answer forward exactly once, so a live edit to
            // the picker below (skipped-intro case) is never overwritten.
            guard !hasLoadedQuizFrequency else { return }
            hasLoadedQuizFrequency = true
            if let quizFrequency = onboardingStore.quizPayFrequency {
                frequency = quizFrequency
            }
        }
    }

    // MARK: - Rows

    private var frequencyRows: some View {
        VStack(spacing: PaydaySpacing.xs) {
            ForEach(PayFrequency.allCases) { option in
                Button {
                    PaydayHaptics.selection()
                    frequency = option
                } label: {
                    HStack(spacing: PaydaySpacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.displayName)
                                .font(PaydayFont.body)
                                .foregroundStyle(PaydayColor.textPrimary)
                            Text(option.onboardingSubtitle)
                                .font(PaydayFont.caption)
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                        Spacer(minLength: PaydaySpacing.xs)
                        Image(systemName: frequency == option ? "checkmark.circle.fill" : "circle")
                            .font(PaydayFont.iconMedium)
                            .foregroundStyle(frequency == option ? PaydayColor.primary : PaydayColor.textTertiary)
                    }
                    .padding(PaydaySpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: PaydayRadius.lg, style: .continuous)
                            .fill(PaydayColor.fieldBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: PaydayRadius.lg, style: .continuous)
                                    .stroke(frequency == option ? PaydayColor.primary : Color.clear, lineWidth: 2)
                            )
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(frequency == option ? [.isSelected] : [])
            }
        }
    }

    private func dateRow(
        label: String,
        selection: Binding<Date>,
        range: PartialRangeThrough<Date>
    ) -> some View {
        HStack {
            Text(label)
                .font(PaydayFont.body)
                .foregroundStyle(PaydayColor.textPrimary)
            Spacer(minLength: PaydaySpacing.xs)
            DatePicker("", selection: selection, in: range, displayedComponents: .date)
                .labelsHidden()
                .tint(PaydayColor.primary)
        }
        .padding(PaydaySpacing.md)
        .background(rowBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: PaydayRadius.lg, style: .continuous)
            .fill(PaydayColor.fieldBackground)
    }

    // MARK: - Save

    private func save() {
        let calendar = Calendar.current
        let normalizedPayday = calendar.startOfDay(for: mostRecentPayday)
        let normalizedPeriodEnd = calendar.startOfDay(for: min(periodEndDate, mostRecentPayday))
        let delayDays = max(0, calendar.dateComponents([.day], from: normalizedPeriodEnd, to: normalizedPayday).day ?? 0)

        scheduleStore.schedule = PaySchedule(
            frequency: frequency,
            anchorPeriodEnd: normalizedPeriodEnd,
            payDelayDays: delayDays
        )
        // The schedule is now the source of truth; drop the carried answer so
        // a later Settings edit can never be shadowed by a stale quiz value.
        onboardingStore.clearQuizPayFrequency()
        PaydayHaptics.success()
    }
}
