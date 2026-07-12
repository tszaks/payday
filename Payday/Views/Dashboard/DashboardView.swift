import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showSettings = false

    private var calculator: PayPeriodCalculator {
        PayPeriodCalculator(schedule: scheduleStore.schedule!)
    }

    private var currentPeriod: PayPeriod {
        calculator.period(containing: .now)
    }

    private var periodEntries: [TipEntry] {
        allEntries.filter { $0.date >= currentPeriod.start && $0.date <= currentPeriod.end }
    }

    private var totalCents: Int {
        periodEntries.reduce(0) { $0 + $1.amountCents }
    }

    private var daysRemaining: Int {
        calculator.daysRemaining(from: .now)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    heroCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if periodEntries.isEmpty {
                    Section {
                        emptyState
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section("Recent entries") {
                        ForEach(periodEntries) { entry in
                            Button {
                                sheetTarget = .edit(entry)
                            } label: {
                                EntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    modelContext.delete(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Payday")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(item: $sheetTarget) { target in
                LogTipSheet(target: target)
            }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-OpenLogSheet") {
                    sheetTarget = .new(defaultDate: .now)
                }
            }
            #endif
            .sheet(isPresented: $showSettings) {
                SettingsView(schedule: scheduleStore.schedule!)
            }
        }
    }

    private var heroCard: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("This pay period")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Money.string(fromCents: totalCents))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.35, bounce: 0.15), value: totalCents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            HStack(spacing: 12) {
                StatChip(
                    icon: "calendar",
                    value: daysRemaining == 0 ? "Today" : "\(daysRemaining)",
                    label: daysRemaining == 0 ? "Payday" : (daysRemaining == 1 ? "day left" : "days left")
                )
                StatChip(
                    icon: "briefcase.fill",
                    value: "\(periodEntries.count)",
                    label: periodEntries.count == 1 ? "shift logged" : "shifts logged"
                )
            }

            Button {
                sheetTarget = .new(defaultDate: .now)
            } label: {
                Label("Log Tips", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.accentColor)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.paydaySurface)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.stars")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Nothing logged yet this period")
                .font(.headline)
            Text("Log tonight's tips and watch the total build toward payday.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }
}

private struct StatChip: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct EntryRow: View {
    let entry: TipEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.body)
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Money.string(fromCents: entry.amountCents))
                .font(.system(.body, design: .rounded, weight: .semibold))
        }
        .padding(.vertical, 4)
    }
}
