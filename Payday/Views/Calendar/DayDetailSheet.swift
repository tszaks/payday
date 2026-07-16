import SwiftUI
import SwiftData

struct DayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
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

    /// Net — the income number, matching the hero total and every other
    /// total in the app (fixes a gross-vs-net mismatch this sheet used to
    /// have with the rest of the app).
    private var totalCents: Int {
        TipBreakdown.total(of: dayEntries).netTotalCents
    }

    var body: some View {
        NavigationStack {
            List {
                if shifts.isEmpty {
                    Text("No tips logged this day.")
                        .foregroundStyle(PaydayColor.textSecondary)
                        .listRowSeparator(.hidden)
                } else {
                    if shifts.count > 1 {
                        Section {
                            HStack {
                                Text("Total")
                                    .font(PaydayFont.subheadline)
                                    .foregroundStyle(PaydayColor.textSecondary)
                                Spacer()
                                Text(Money.string(fromCents: totalCents))
                                    .font(PaydayFont.displaySmall)
                                    .monospacedDigit()
                                    .foregroundStyle(PaydayColor.textPrimary)
                            }
                            .paydayCard()
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: PaydaySpacing.p16, bottom: 4, trailing: PaydaySpacing.p16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

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
            .navigationTitle(ShiftDays.humanLabel(for: date))
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

    @ViewBuilder
    private func shiftRow(for group: (day: Date, shiftID: UUID, items: [TipEntry])) -> some View {
        let period = ShiftDetails.resolve(from: group.items).shiftPeriod
        if let anchor = group.items.first {
            Button {
                sheetTarget = .edit(anchor)
            } label: {
                ShiftDayRow(day: group.day, period: period, dayHasMultipleShifts: shifts.count >= 2, entries: group.items)
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
