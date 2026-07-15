import SwiftUI

/// Periods are DERIVED at read time from these settings, never persisted
/// per-entry — so changing frequency or anchor here just regroups existing
/// entries live everywhere else in the app. Entries themselves never change.
struct SettingsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.dismiss) private var dismiss

    @State private var firstName: String
    @State private var appearance: AppAppearance
    @State private var isFaceIDLockEnabled: Bool = false
    @State private var isSmartNudgeEnabled: Bool = true
    @State private var frequency: PayFrequency
    @State private var mostRecentPayday: Date
    @State private var periodEndDate: Date
    @State private var firstWeekday: Int

    private let weekdaySymbols = Calendar.current.weekdaySymbols // [Sunday…Saturday]

    init(schedule: PaySchedule) {
        _frequency = State(initialValue: schedule.frequency)
        _periodEndDate = State(initialValue: schedule.anchorPeriodEnd)
        _mostRecentPayday = State(initialValue: Calendar.current.date(byAdding: .day, value: schedule.resolvedPayDelayDays, to: schedule.anchorPeriodEnd) ?? schedule.anchorPeriodEnd)
        _firstWeekday = State(initialValue: schedule.resolvedFirstWeekday)
        _firstName = State(initialValue: "")
        _appearance = State(initialValue: .system)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your name") {
                    TextField("First name", text: $firstName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section {
                    Toggle("Require Face ID", isOn: $isFaceIDLockEnabled)
                } footer: {
                    Text("Locks Payday when it's in the background. Uses your device passcode as a fallback.")
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section {
                    Toggle("Remind me to log", isOn: $isSmartNudgeEnabled)
                } footer: {
                    Text("A single \"How was tonight?\" notification on a usual work night, only if nothing's logged yet.")
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section("Pay frequency") {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(PayFrequency.allCases) { freq in
                            Text(freq.displayName).tag(freq)
                        }
                    }
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section {
                    DatePicker("Payday", selection: $mostRecentPayday, in: ...Date.now, displayedComponents: .date)
                } header: {
                    Text("Most recent payday")
                } footer: {
                    Text("The day that paycheck actually landed in your account.")
                }
                .listRowBackground(PaydayColor.fieldBackground)
                .onChange(of: mostRecentPayday) { _, newValue in
                    if periodEndDate > newValue { periodEndDate = newValue }
                }

                Section {
                    DatePicker("Last day covered", selection: $periodEndDate, in: ...mostRecentPayday, displayedComponents: .date)
                } header: {
                    Text("What that check paid you for")
                } footer: {
                    Text("The last day of work that paycheck covered. Everything is grouped around this, not the payday itself.")
                }
                .listRowBackground(PaydayColor.fieldBackground)

                if frequency == .twiceMonthly {
                    Text("Periods run the 1st–15th and 16th–end of every month.")
                        .font(PaydayFont.footnote)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .listRowBackground(PaydayColor.fieldBackground)
                }

                Section {
                    Picker("First day", selection: $firstWeekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                } header: {
                    Text("Week starts on")
                } footer: {
                    Text("Sets which day the calendar grid begins on.")
                }
                .listRowBackground(PaydayColor.fieldBackground)

                #if DEBUG
                Section("Developer") {
                    Button("Seed sample data") {
                        DebugSeeder.seedSampleData(scheduleStore: scheduleStore, insightsStore: insightsStore)
                    }
                    Button("Clear all data", role: .destructive) {
                        DebugSeeder.clearAll(scheduleStore: scheduleStore, insightsStore: insightsStore)
                    }
                }
                .listRowBackground(PaydayColor.fieldBackground)
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(PaydayColor.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: frequency) { _, _ in save() }
            .onChange(of: mostRecentPayday) { _, _ in save() }
            .onChange(of: periodEndDate) { _, _ in save() }
            .onChange(of: firstWeekday) { _, _ in save() }
            .onChange(of: firstName) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                preferencesStore.firstName = trimmed.isEmpty ? nil : trimmed
            }
            .onChange(of: appearance) { _, newValue in
                preferencesStore.appearance = newValue
            }
            .onChange(of: isFaceIDLockEnabled) { _, newValue in
                preferencesStore.isFaceIDLockEnabled = newValue
            }
            .onChange(of: isSmartNudgeEnabled) { _, newValue in
                preferencesStore.isSmartNudgeEnabled = newValue
            }
            .onAppear {
                firstName = preferencesStore.firstName ?? ""
                appearance = preferencesStore.appearance
                isFaceIDLockEnabled = preferencesStore.isFaceIDLockEnabled
                isSmartNudgeEnabled = preferencesStore.isSmartNudgeEnabled
            }
        }
        .presentationBackground(PaydayColor.background)
    }

    private func save() {
        let calendar = Calendar.current
        let normalizedPayday = calendar.startOfDay(for: mostRecentPayday)
        let normalizedPeriodEnd = calendar.startOfDay(for: min(periodEndDate, mostRecentPayday))
        let delayDays = max(0, calendar.dateComponents([.day], from: normalizedPeriodEnd, to: normalizedPayday).day ?? 0)

        scheduleStore.schedule = PaySchedule(
            frequency: frequency,
            anchorPeriodEnd: normalizedPeriodEnd,
            payDelayDays: delayDays,
            firstWeekday: firstWeekday
        )
        // Period boundaries move the widget's numbers too.
        PaydayWidgetRefresh.request()
    }
}
