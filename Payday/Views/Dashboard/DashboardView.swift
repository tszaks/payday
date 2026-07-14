import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showSettings = false

    private var calculator: PayPeriodCalculator {
        // Fallback keeps a transient render safe if the schedule is cleared
        // while this view is still mounted; RootView swaps to setup next tick.
        PayPeriodCalculator(schedule: scheduleStore.schedule ?? .fallback)
    }

    private var currentPeriod: PayPeriod {
        calculator.period(containing: .now)
    }

    private var periodEntries: [TipEntry] {
        allEntries.filter { $0.date >= currentPeriod.start && $0.date <= currentPeriod.end }
    }

    private var breakdown: TipBreakdown {
        TipBreakdown.total(of: periodEntries)
    }

    private var totalCents: Int {
        breakdown.totalCents
    }

    private var daysRemaining: Int {
        calculator.daysRemaining(from: .now)
    }

    /// A shift is a day worked, not a row: logging one night now writes up to
    /// two entries (cash + credit), so count distinct days, not entries.
    private var shiftCount: Int {
        Set(periodEntries.map { Calendar.current.startOfDay(for: $0.date) }).count
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
                            .listRowBackground(PaydayColor.background)
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
            .scrollContentBackground(.hidden)
            .background(PaydayColor.background)
            .contentMargins(.bottom, 88, for: .scrollContent) // clear the floating + button
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
                if ProcessInfo.processInfo.arguments.contains("-OpenEditSheet"), let first = periodEntries.first {
                    sheetTarget = .edit(first)
                }
            }
            #endif
            .sheet(isPresented: $showSettings) {
                SettingsView(schedule: scheduleStore.schedule ?? .fallback)
            }
        }
    }

    private var heroCard: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("This pay period")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(Money.string(fromCents: totalCents))
                    .font(PaydayFont.displayXXL)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textPrimary)
                    .contentTransition(.numericText())
                    .animation(PaydayAnimation.premiumSpring, value: totalCents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            HStack(spacing: 12) {
                MoneyTile(label: "Cash", cents: breakdown.cashCents)
                MoneyTile(label: "Credit", cents: breakdown.creditCents)
            }

            HStack(spacing: 12) {
                StatChip(
                    value: daysRemaining == 0 ? "Today" : "\(daysRemaining)",
                    label: daysRemaining == 0 ? "Payday" : (daysRemaining == 1 ? "day left" : "days left")
                )
                StatChip(
                    value: "\(shiftCount)",
                    label: shiftCount == 1 ? "shift logged" : "shifts logged"
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(PaydayColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: PaydayRadius.lg, style: .continuous))
        .paydayPremiumShadow()
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing logged yet this period",
            systemImage: "tray",
            description: Text("Log tonight's tips and watch the total build toward payday.")
        )
        .padding(.vertical, 16)
    }
}

private struct MoneyTile: View {
    let label: String
    let cents: Int

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
            Text(Money.string(fromCents: cents))
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(cents == 0 ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                .contentTransition(.numericText())
                .animation(PaydayAnimation.premiumSpring, value: cents)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(PaydayColor.fieldBackground, in: RoundedRectangle(cornerRadius: PaydayRadius.md))
    }
}

private struct StatChip: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
            Text(label)
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(PaydayColor.fieldBackground, in: RoundedRectangle(cornerRadius: PaydayRadius.md))
    }
}

struct EntryRow: View {
    let entry: TipEntry

    private var subtitle: String {
        let calendar = Calendar.current
        let recordedSameDay = entry.recordedAt.map { calendar.isDate($0, inSameDayAs: entry.date) } ?? false

        var parts = [entry.kind.displayName]
        // Only show the clock time when the tip was recorded the same day it
        // was earned — then it reads as roughly when you worked. For backfills
        // the recorded time isn't the shift time, so we don't imply it is.
        if recordedSameDay, let recordedAt = entry.recordedAt {
            parts.append(recordedAt.formatted(date: .omitted, time: .shortened))
        }
        if let note = entry.note, !note.isEmpty {
            parts.append(note)
        }
        if !recordedSameDay, let recordedAt = entry.recordedAt {
            parts.append("logged \(recordedAt.formatted(.dateTime.month(.abbreviated).day()))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(PaydayFont.body)
                    .foregroundStyle(PaydayColor.textPrimary)
                Text(subtitle)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .monospacedDigit()
            }
            Spacer()
            Text(Money.string(fromCents: entry.amountCents))
                .font(PaydayFont.displaySmall)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
        }
        .padding(.vertical, 4)
    }
}
