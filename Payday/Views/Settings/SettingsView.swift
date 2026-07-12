import SwiftUI

/// Periods are DERIVED at read time from these settings, never persisted
/// per-entry — so changing frequency or anchor here just regroups existing
/// entries live everywhere else in the app. Entries themselves never change.
struct SettingsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(\.dismiss) private var dismiss

    @State private var frequency: PayFrequency
    @State private var anchorPayday: Date

    init(schedule: PaySchedule) {
        _frequency = State(initialValue: schedule.frequency)
        _anchorPayday = State(initialValue: schedule.anchorPayday)
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

                Section("Most recent payday") {
                    DatePicker("Payday", selection: $anchorPayday, in: ...Date.now, displayedComponents: .date)
                }

                if frequency == .twiceMonthly {
                    Text("Paydays fall on the 15th and the last day of every month.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                #if DEBUG
                Section("Developer") {
                    Button("Seed sample data") {
                        DebugSeeder.seedSampleData(scheduleStore: scheduleStore)
                    }
                    Button("Clear all data", role: .destructive) {
                        DebugSeeder.clearAll(scheduleStore: scheduleStore)
                    }
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: frequency) { _, _ in save() }
            .onChange(of: anchorPayday) { _, _ in save() }
        }
    }

    private func save() {
        scheduleStore.schedule = PaySchedule(
            frequency: frequency,
            anchorPayday: Calendar.current.startOfDay(for: anchorPayday)
        )
    }
}
