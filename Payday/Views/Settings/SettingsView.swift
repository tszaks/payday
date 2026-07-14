import SwiftUI

/// Periods are DERIVED at read time from these settings, never persisted
/// per-entry — so changing frequency or anchor here just regroups existing
/// entries live everywhere else in the app. Entries themselves never change.
struct SettingsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Environment(\.dismiss) private var dismiss

    @State private var frequency: PayFrequency
    @State private var anchorPayday: Date
    @State private var firstWeekday: Int

    private let weekdaySymbols = Calendar.current.weekdaySymbols // [Sunday…Saturday]

    init(schedule: PaySchedule) {
        _frequency = State(initialValue: schedule.frequency)
        _anchorPayday = State(initialValue: schedule.anchorPayday)
        _firstWeekday = State(initialValue: schedule.resolvedFirstWeekday)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pay frequency") {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(PayFrequency.allCases) { freq in
                            Text(freq.displayName).tag(freq)
                        }
                    }
                }
                .listRowBackground(PaydayColor.fieldBackground)

                Section {
                    DatePicker("Payday", selection: $anchorPayday, in: ...Date.now, displayedComponents: .date)
                } header: {
                    Text("Most recent payday")
                } footer: {
                    Text("Set this to the last day of your most recent pay period. Everything is grouped around it.")
                }
                .listRowBackground(PaydayColor.fieldBackground)

                if frequency == .twiceMonthly {
                    Text("Paydays fall on the 15th and the last day of every month.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .onChange(of: anchorPayday) { _, _ in save() }
            .onChange(of: firstWeekday) { _, _ in save() }
        }
        .presentationBackground(PaydayColor.background)
    }

    private func save() {
        scheduleStore.schedule = PaySchedule(
            frequency: frequency,
            anchorPayday: Calendar.current.startOfDay(for: anchorPayday),
            firstWeekday: firstWeekday
        )
    }
}
