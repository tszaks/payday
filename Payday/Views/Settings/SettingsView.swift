import SwiftUI
import SwiftData

/// Periods are DERIVED at read time from these settings, never persisted
/// per-entry — so changing frequency or anchor here just regroups existing
/// entries live everywhere else in the app. Entries themselves never change.
struct SettingsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(MoveLedgerStore.self) private var moveLedgerStore
    @Environment(\.dismiss) private var dismiss
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    @State private var firstName: String
    @State private var isFaceIDLockEnabled: Bool = false
    @State private var isSmartNudgeEnabled: Bool = true
    @State private var isPaydayReminderEnabled: Bool = true
    @State private var frequency: PayFrequency
    @State private var mostRecentPayday: Date
    @State private var periodEndDate: Date
    @State private var firstWeekday: Int
    @State private var wageDigitsText: String = ""
    @FocusState private var isWageFieldFocused: Bool
    @State private var isShowingBackfillSheet = false

    private let weekdaySymbols = Calendar.current.weekdaySymbols // [Sunday…Saturday]
    private static let maxWageDigits = 4 // caps at $99.99/hr

    init(schedule: PaySchedule) {
        _frequency = State(initialValue: schedule.frequency)
        _periodEndDate = State(initialValue: schedule.anchorPeriodEnd)
        _mostRecentPayday = State(initialValue: Calendar.current.date(byAdding: .day, value: schedule.resolvedPayDelayDays, to: schedule.anchorPeriodEnd) ?? schedule.anchorPeriodEnd)
        _firstWeekday = State(initialValue: schedule.resolvedFirstWeekday)
        _firstName = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("First name", text: $firstName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Picker("Appearance", selection: appearanceBinding) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section("Notifications & Security") {
                    Toggle("Require Face ID", isOn: $isFaceIDLockEnabled)
                    Toggle("Shift reminder", isOn: $isSmartNudgeEnabled)
                    Toggle("Payday reminder", isOn: $isPaydayReminderEnabled)
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section("Pay Schedule") {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(PayFrequency.allCases) { freq in
                            Text(freq.displayName).tag(freq)
                        }
                    }
                    DatePicker("Payday", selection: $mostRecentPayday, in: ...Date.now, displayedComponents: .date)
                    DatePicker("Last day covered", selection: $periodEndDate, in: ...mostRecentPayday, displayedComponents: .date)
                    if frequency == .twiceMonthly {
                        Text("1st–15th and 16th–month end")
                            .font(PaydayFont.footnote)
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                    HStack {
                        Text("Hourly wage")
                            .foregroundStyle(PaydayColor.textPrimary)
                        Spacer()
                        ZStack(alignment: .trailing) {
                            Text(preferencesStore.baseHourlyWageCents.map { Money.string(fromCents: $0) } ?? "$0.00")
                                .foregroundStyle(preferencesStore.baseHourlyWageCents == nil ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                                .monospacedDigit()
                                .accessibilityHidden(true)
                            TextField("", text: $wageDigitsText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($isWageFieldFocused)
                                .opacity(0.01)
                                .frame(maxWidth: 90)
                                .accessibilityLabel("Hourly wage")
                                .accessibilityValue(preferencesStore.baseHourlyWageCents.map { Money.string(fromCents: $0) } ?? "Not set")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { isWageFieldFocused = true }
                }
                .listRowBackground(PaydayColor.fieldBackground)
                .onChange(of: mostRecentPayday) { _, newValue in
                    if periodEndDate > newValue { periodEndDate = newValue }
                }
                .onChange(of: wageDigitsText) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(Self.maxWageDigits))
                    if filtered != newValue { wageDigitsText = filtered }
                    preferencesStore.baseHourlyWageCents = filtered.isEmpty ? nil : Int(filtered)
                }

                Section("Data") {
                    Button("Add Past Shifts") { isShowingBackfillSheet = true }
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section("Calendar") {
                    Picker("First day", selection: $firstWeekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                }
                .listRowBackground(PaydayColor.fieldBackground)

                #if DEBUG
                Section("Developer") {
                    Button("Seed sample data") {
                        DebugSeeder.seedSampleData(scheduleStore: scheduleStore, insightsStore: insightsStore)
                    }
                    Button("Seed follow-up demo") {
                        DebugSeeder.seedFollowUpDemoData(insightsStore: insightsStore, moveLedgerStore: moveLedgerStore)
                    }
                    Button("Clear all data", role: .destructive) {
                        DebugSeeder.clearAll(scheduleStore: scheduleStore, insightsStore: insightsStore, moveLedgerStore: moveLedgerStore)
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
                if isWageFieldFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { isWageFieldFocused = false }
                    }
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
            .onChange(of: isFaceIDLockEnabled) { _, newValue in
                preferencesStore.isFaceIDLockEnabled = newValue
            }
            .onChange(of: isSmartNudgeEnabled) { _, newValue in
                preferencesStore.isSmartNudgeEnabled = newValue
                // Turning this ON is the other deliberate moment (besides
                // the first logged shift) this app ever asks for
                // notification permission — see SmartNudgeScheduler.
                if newValue {
                    Task { await SmartNudgeScheduler.requestAuthorizationIfNeeded() }
                }
            }
            .onChange(of: isPaydayReminderEnabled) { _, newValue in
                preferencesStore.isPaydayReminderEnabled = newValue
                PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: scheduleStore.schedule, allEntries: allEntries, paycheckRecords: paycheckRecords)
            }
            .onAppear {
                firstName = preferencesStore.firstName ?? ""
                isFaceIDLockEnabled = preferencesStore.isFaceIDLockEnabled
                isSmartNudgeEnabled = preferencesStore.isSmartNudgeEnabled
                isPaydayReminderEnabled = preferencesStore.isPaydayReminderEnabled
                wageDigitsText = preferencesStore.baseHourlyWageCents.map(String.init) ?? ""
            }
            .sheet(isPresented: $isShowingBackfillSheet) {
                BackfillSheet().paydayAppearance()
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

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { preferencesStore.appearance },
            set: { preferencesStore.appearance = $0 }
        )
    }
}
