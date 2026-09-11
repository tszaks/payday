import SwiftUI
import SwiftData

private struct DayDetailFacts {
    let shifts: [(day: Date, shiftID: UUID, items: [TipEntry])]
    let totalCents: Int

    init(allEntries: [TipEntry], date: Date, wageCentsPerHour: Int?) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let entries = allEntries.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let resolvedShifts = ShiftDays.groupedByShift(
            entries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod,
            calendar: calendar
        )
        let wages = WageEstimate.centsSummedPerShift(
            shiftGroups: resolvedShifts.map(\.items),
            wageCentsPerHour: wageCentsPerHour
        )
        shifts = resolvedShifts
        totalCents = TipBreakdown.total(of: entries).netTotalCents + wages
    }
}

struct DayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var allEntries: [TipEntry]

    let date: Date
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var undoState = UndoDeleteToastState()

    /// Always "Wed, Jul 15" — weekday abbrev, month, day. ShiftDays.humanLabel
    /// (which this sheet used to show) collapses recent days to "Today" /
    /// bare "Wednesday", which reads fine in a list of shifts but not as a
    /// sheet title naming one specific day.
    private var titleText: String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        let facts = DayDetailFacts(
            allEntries: allEntries,
            date: date,
            wageCentsPerHour: preferencesStore.baseHourlyWageCents
        )
        NavigationStack {
            List {
                if facts.shifts.isEmpty {
                    Text("No tips logged this day.")
                        .foregroundStyle(PaydayColor.textSecondary)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        heroCard(totalCents: facts.totalCents)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: PaydaySpacing.p16, bottom: 4, trailing: PaydaySpacing.p16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section("Shifts") {
                        ForEach(facts.shifts, id: \.shiftID) { group in
                            shiftRow(for: group, shiftCount: facts.shifts.count)
                        }
                    }
                    .listRowBackground(PaydayColor.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PaydayColor.background)
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        sheetTarget = .new(defaultDate: date)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Log shift")
                }
            }
            .sheet(item: $sheetTarget) { target in
                LogTipSheet(target: target).paydayAppearance()
            }
        }
        .undoDeleteToast(undoState, context: modelContext)
        .presentationDetents([.medium, .large])
        .presentationBackground(PaydayColor.background)
    }

    /// The sheet's one hero — same grammar as the Dashboard/Period-detail
    /// heroes (caption above a big monospaced number), floating directly on
    /// the sheet's background rather than inside its own card: this sheet
    /// has no second object competing for attention, so a shadow here would
    /// mark nothing.
    private func heroCard(totalCents: Int) -> some View {
        VStack(spacing: 6) {
            Text("Total")
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
            Text(Money.string(fromCents: totalCents))
                .font(PaydayFont.displayLarge)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: totalCents)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, PaydaySpacing.p24)
    }

    @ViewBuilder
    private func shiftRow(
        for group: (day: Date, shiftID: UUID, items: [TipEntry]),
        shiftCount: Int
    ) -> some View {
        let period = ShiftDetails.resolve(from: group.items).shiftPeriod
        if let anchor = group.items.first {
            Button {
                sheetTarget = .edit(anchor)
            } label: {
                ShiftDayRow(day: group.day, period: period, dayHasMultipleShifts: shiftCount >= 2, entries: group.items, wageCentsPerHour: preferencesStore.baseHourlyWageCents)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    undoState.delete(group.items, in: modelContext)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .shiftContextMenu(group.items, sheetTarget: $sheetTarget, undoState: undoState, context: modelContext)
        }
    }
}
