import SwiftUI
import SwiftData

struct DayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Query private var allEntries: [TipEntry]

    let date: Date
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var undoState = UndoDeleteToastState()

    private var dayEntries: [TipEntry] {
        let day = Calendar.current.startOfDay(for: date)
        return allEntries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
    }

    /// This day's shifts (one closeout each, however many rows it took to
    /// log it) — the sheet lists shifts, not entries, same as Dashboard and
    /// Period detail now that the entry layer never surfaces in the UI.
    private var shifts: [(day: Date, shiftID: UUID, items: [TipEntry])] {
        ShiftDays.groupedByShift(dayEntries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
    }

    /// This day's base-rate wages — never OT, which only exists at the
    /// period level. Matches the sum of the ShiftDayRow amounts listed right
    /// below this total, and CalendarView/PeriodDetailView's per-day wages
    /// for the same day (see WageEstimate.centsSummedPerShift).
    private var dayWageCents: Int {
        WageEstimate.centsSummedPerShift(shiftGroups: shifts.map(\.items), wageCentsPerHour: preferencesStore.baseHourlyWageCents)
    }

    /// Net tips plus wages — the income number, matching the hero total and
    /// every other total in the app (fixes a gross-vs-net mismatch this
    /// sheet used to have with the rest of the app).
    private var totalCents: Int {
        TipBreakdown.total(of: dayEntries).netTotalCents + dayWageCents
    }

    /// Always "Wed, Jul 15" — weekday abbrev, month, day. ShiftDays.humanLabel
    /// (which this sheet used to show) collapses recent days to "Today" /
    /// bare "Wednesday", which reads fine in a list of shifts but not as a
    /// sheet title naming one specific day.
    private var titleText: String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        NavigationStack {
            List {
                if shifts.isEmpty {
                    Text("No tips logged this day.")
                        .foregroundStyle(PaydayColor.textSecondary)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        heroCard
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: PaydaySpacing.p16, bottom: 4, trailing: PaydaySpacing.p16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section("Shifts") {
                        ForEach(shifts, id: \.shiftID) { group in
                            shiftRow(for: group)
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
                LogTipSheet(target: target)
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
    private var heroCard: some View {
        VStack(spacing: 6) {
            Text("Total")
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
            Text(Money.string(fromCents: totalCents))
                .font(PaydayFont.displayLarge)
                .monospacedDigit()
                .foregroundStyle(PaydayColor.textPrimary)
                .contentTransition(.numericText())
                .animation(PaydayAnimation.premiumSpring, value: totalCents)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, PaydaySpacing.p24)
    }

    @ViewBuilder
    private func shiftRow(for group: (day: Date, shiftID: UUID, items: [TipEntry])) -> some View {
        let period = ShiftDetails.resolve(from: group.items).shiftPeriod
        if let anchor = group.items.first {
            Button {
                sheetTarget = .edit(anchor)
            } label: {
                ShiftDayRow(day: group.day, period: period, dayHasMultipleShifts: shifts.count >= 2, entries: group.items, wageCentsPerHour: preferencesStore.baseHourlyWageCents)
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
