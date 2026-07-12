import SwiftUI

/// Asks exactly two things: pay frequency and the most recent payday.
/// Both are editable later from Settings.
struct FirstRunSetupView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore

    @State private var frequency: PayFrequency = .biweekly
    @State private var anchorPayday: Date = .now

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to Payday")
                        .font(.largeTitle.bold())
                    Text("Two quick questions and you're set.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 24)
                .padding(.bottom, 8)

                Form {
                    Section("How often do you get paid?") {
                        Picker("Pay frequency", selection: $frequency) {
                            ForEach(PayFrequency.allCases) { freq in
                                Text(freq.displayName).tag(freq)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .listRowBackground(Color.paydaySurface)

                    Section("When was your most recent payday?") {
                        DatePicker("Payday", selection: $anchorPayday, in: ...Date.now, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                    }
                    .listRowBackground(Color.paydaySurface)

                    if frequency == .twiceMonthly {
                        Text("Paydays fall on the 15th and the last day of every month.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.paydaySurface)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.paydaySurface)
            }
            .background(Color.paydaySurface)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .buttonStyle(.glassProminent)
                        .tint(.accentColor)
                }
            }
        }
    }

    private func save() {
        scheduleStore.schedule = PaySchedule(
            frequency: frequency,
            anchorPayday: Calendar.current.startOfDay(for: anchorPayday)
        )
    }
}
