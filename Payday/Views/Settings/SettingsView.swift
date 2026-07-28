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
    @State private var appearance: AppAppearance
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

    @State private var workCalendarStore = WorkCalendarStore()
    @State private var connectedWorkCalendarTitle: String?
    @State private var isShowingWorkCalendarPicker = false
    @State private var availableWorkCalendars: [(id: String, title: String, sourceTitle: String)] = []
    @State private var workCalendarConnectCaption = SettingsView.defaultWorkCalendarCaption

    private let weekdaySymbols = Calendar.current.weekdaySymbols // [Sunday…Saturday]
    private static let maxWageDigits = 4 // caps at $99.99/hr
    private static let defaultWorkCalendarCaption = "Times the shift reminder to your posted schedule. Payday reads only the calendar you pick; it never leaves your phone."
    private static let deniedWorkCalendarCaption = "Calendar access is off for Payday in Settings."

    init(schedule: PaySchedule) {
        _frequency = State(initialValue: schedule.frequency)
        _periodEndDate = State(initialValue: schedule.anchorPeriodEnd)
        _mostRecentPayday = State(initialValue: Calendar.current.date(byAdding: .day, value: schedule.resolvedPayDelayDays, to: schedule.anchorPeriodEnd) ?? schedule.anchorPeriodEnd)
        _firstWeekday = State(initialValue: schedule.resolvedFirstWeekday)
        _firstName = State(initialValue: "")
        _appearance = State(initialValue: .system)
    }

    /// Standardizes on inline captions (a caption `Text` living right under its
    /// control) instead of Section footers — a footer can only belong to one
    /// Section, which is exactly what forced this screen into eight separate
    /// single-row sections with wide gaps between them in the first place.
    /// Inline captions let related controls share one grouped Section while
    /// each one keeps its own explanation, matching Apple's own grouped-list
    /// pattern (e.g. Settings.app's own toggle rows).
    @ViewBuilder
    private func captionedRow<Content: View>(_ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            Text(caption)
                .font(PaydayFont.footnote)
                .foregroundStyle(PaydayColor.textSecondary)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("First name", text: $firstName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section("Notifications & Security") {
                    captionedRow("Locks Payday when it's in the background. Uses your device passcode as a fallback.") {
                        Toggle("Require Face ID", isOn: $isFaceIDLockEnabled)
                    }
                    captionedRow("A single \"How was your shift?\" notification on a usual work day, only if nothing's logged yet.") {
                        Toggle("Remind me to log", isOn: $isSmartNudgeEnabled)
                    }
                    captionedRow("One notification on payday morning with what your check should say.") {
                        Toggle("Payday reminder", isOn: $isPaydayReminderEnabled)
                    }
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section("Work Schedule") {
                    if preferencesStore.workCalendarIdentifier != nil {
                        captionedRow("Shift reminders follow this schedule.") {
                            HStack {
                                Text(connectedWorkCalendarTitle ?? "Work calendar")
                                    .foregroundStyle(PaydayColor.textPrimary)
                                Spacer()
                                Button("Disconnect") { disconnectWorkCalendar() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(PaydayColor.textSecondary)
                            }
                        }
                        // For a MIXED calendar (shifts next to dentist
                        // appointments): the user states the rule, the app
                        // applies it literally. Blank = every event counts.
                        captionedRow("Only count events whose title contains this. Leave empty if every event is a shift.") {
                            TextField("Filter, e.g. your restaurant's name", text: workCalendarKeywordBinding)
                                .autocorrectionDisabled()
                        }
                    } else {
                        captionedRow(workCalendarConnectCaption) {
                            Button("Connect Work Calendar") { connectWorkCalendar() }
                        }
                    }
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section("Pay Schedule") {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(PayFrequency.allCases) { freq in
                            Text(freq.displayName).tag(freq)
                        }
                    }
                    captionedRow("The day that paycheck actually landed in your account.") {
                        DatePicker("Payday", selection: $mostRecentPayday, in: ...Date.now, displayedComponents: .date)
                    }
                    captionedRow("The last day of work that paycheck covered. Everything is grouped around this, not the payday itself.") {
                        DatePicker("Last day covered", selection: $periodEndDate, in: ...mostRecentPayday, displayedComponents: .date)
                    }
                    if frequency == .twiceMonthly {
                        Text("Periods run the 1st–15th and 16th–end of every month.")
                            .font(PaydayFont.footnote)
                            .foregroundStyle(PaydayColor.textSecondary)
                    }
                    captionedRow("Your base pay before tips (tipped minimum is a few dollars an hour in many states). Payday uses it only to estimate the wages line on your paycheck.") {
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
                    captionedRow("Backfill history from before Payday. More history means better insights.") {
                        Button("Add Past Shifts") { isShowingBackfillSheet = true }
                    }
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section("Calendar") {
                    captionedRow("Sets which day the calendar grid begins on.") {
                        Picker("First day", selection: $firstWeekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(weekdaySymbols[day - 1]).tag(day)
                            }
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
            .onChange(of: appearance) { _, newValue in
                preferencesStore.appearance = newValue
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
                appearance = preferencesStore.appearance
                isFaceIDLockEnabled = preferencesStore.isFaceIDLockEnabled
                isSmartNudgeEnabled = preferencesStore.isSmartNudgeEnabled
                isPaydayReminderEnabled = preferencesStore.isPaydayReminderEnabled
                wageDigitsText = preferencesStore.baseHourlyWageCents.map(String.init) ?? ""
                if let identifier = preferencesStore.workCalendarIdentifier {
                    connectedWorkCalendarTitle = workCalendarStore.availableCalendars().first { $0.id == identifier }?.title
                }
            }
            .sheet(isPresented: $isShowingBackfillSheet) {
                BackfillSheet()
            }
            .sheet(isPresented: $isShowingWorkCalendarPicker) {
                WorkCalendarPickerSheet(calendars: availableWorkCalendars, onSelect: selectWorkCalendar)
            }
        }
        .presentationBackground(PaydayColor.background)
    }

    /// The one deliberate place this app ever asks iOS for calendar
    /// access — an explicit tap here, never on launch. Already-authorized
    /// taps skip straight to the picker; a fresh denial swaps the caption
    /// in place rather than showing an alert.
    private func connectWorkCalendar() {
        Task {
            if workCalendarStore.authorizationStatus == .fullAccess {
                presentWorkCalendarPicker()
                return
            }
            if await workCalendarStore.requestAccess() {
                presentWorkCalendarPicker()
            } else {
                workCalendarConnectCaption = Self.deniedWorkCalendarCaption
            }
        }
    }

    private func presentWorkCalendarPicker() {
        availableWorkCalendars = workCalendarStore.availableCalendars()
        isShowingWorkCalendarPicker = true
    }

    private func selectWorkCalendar(id: String, title: String) {
        preferencesStore.workCalendarIdentifier = id
        connectedWorkCalendarTitle = title
        SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries)
    }

    private var workCalendarKeywordBinding: Binding<String> {
        Binding(
            get: { preferencesStore.workCalendarKeyword ?? "" },
            set: { newValue in
                preferencesStore.workCalendarKeyword = newValue
                rescheduleNudgeForWorkCalendarChange()
            }
        )
    }

    /// Keyword edits change which events count, so the pending nudge is
    /// re-aimed on each change — replacing the single pending request is
    /// cheap and idempotent.
    private func rescheduleNudgeForWorkCalendarChange() {
        SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries)
    }

    private func disconnectWorkCalendar() {
        preferencesStore.workCalendarIdentifier = nil
        connectedWorkCalendarTitle = nil
        workCalendarConnectCaption = Self.defaultWorkCalendarCaption
        SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries)
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
