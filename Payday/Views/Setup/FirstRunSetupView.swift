import SwiftUI

/// Asks for pay frequency plus two dates the user can read straight off a
/// pay stub — no mental math required. Most payroll pays a few days after a
/// period actually ends; asking for the payday and the period-end
/// separately lets the app work out that lag itself instead of assuming
/// zero (which silently misplaces every period boundary for anyone paid on
/// a delay). Both dates and the frequency are editable later from Settings.
struct FirstRunSetupView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore

    @State private var firstName: String = ""
    @State private var frequency: PayFrequency = .biweekly
    @State private var mostRecentPayday: Date = .now
    @State private var periodEndDate: Date = .now

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to Payday")
                        .font(PaydayFont.largeTitle)
                        .foregroundStyle(PaydayColor.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 24)
                .padding(.bottom, 8)

                Form {
                    Section("Name") {
                        TextField("First name", text: $firstName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                    .listRowBackground(PaydayColor.fieldBackground)

                    Section("Pay schedule") {
                        Picker("Pay frequency", selection: $frequency) {
                            ForEach(PayFrequency.allCases) { freq in
                                Text(freq.displayName).tag(freq)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .listRowBackground(PaydayColor.fieldBackground)

                    Section {
                        HStack {
                            Text("Payday")
                            Spacer()
                            DatePicker("", selection: $mostRecentPayday, in: ...Date.now, displayedComponents: .date)
                                .labelsHidden()
                        }
                    }
                    .listRowBackground(PaydayColor.fieldBackground)
                    .onChange(of: mostRecentPayday) { _, newValue in
                        if periodEndDate > newValue { periodEndDate = newValue }
                    }

                    Section {
                        HStack {
                            Text("Last day it covered")
                            Spacer()
                            DatePicker("", selection: $periodEndDate, in: ...mostRecentPayday, displayedComponents: .date)
                                .labelsHidden()
                        }
                    }
                    .listRowBackground(PaydayColor.fieldBackground)

                    if frequency == .twiceMonthly {
                        Text("1st–15th and 16th–month end")
                            .font(PaydayFont.footnote)
                            .foregroundStyle(PaydayColor.textSecondary)
                            .listRowBackground(PaydayColor.fieldBackground)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(PaydayColor.background)
            }
            .background(PaydayColor.background)
            // A welcome screen's commit control needs one-thumb reach and to
            // unmistakably read as "the next step," not as an edit screen's
            // small top-right Done — full-width and pinned above the safe
            // area, the app's standard prominent button style.
            .safeAreaInset(edge: .bottom) {
                Button("Get Started") { save() }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glassProminent)
                    .tint(PaydayColor.primary)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(PaydayColor.background)
            }
        }
    }

    private func save() {
        let trimmedName = firstName.trimmingCharacters(in: .whitespaces)
        preferencesStore.firstName = trimmedName.isEmpty ? nil : trimmedName

        let calendar = Calendar.current
        let normalizedPayday = calendar.startOfDay(for: mostRecentPayday)
        let normalizedPeriodEnd = calendar.startOfDay(for: min(periodEndDate, mostRecentPayday))
        let delayDays = max(0, calendar.dateComponents([.day], from: normalizedPeriodEnd, to: normalizedPayday).day ?? 0)

        scheduleStore.schedule = PaySchedule(
            frequency: frequency,
            anchorPeriodEnd: normalizedPeriodEnd,
            payDelayDays: delayDays
        )
    }
}
