import SwiftUI
import SwiftData

struct DayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allEntries: [TipEntry]

    let date: Date
    /// When set, the sheet shows just one shift (closeout); otherwise the
    /// whole calendar day. A double day opens one shift at a time.
    var shiftID: UUID? = nil
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var undoState = UndoDeleteToastState()

    private var entries: [TipEntry] {
        let scoped: [TipEntry]
        if let shiftID {
            scoped = allEntries.filter { $0.shiftID == shiftID }
        } else {
            let day = Calendar.current.startOfDay(for: date)
            scoped = allEntries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
        }
        return scoped.sorted { $0.amountCents > $1.amountCents }
    }

    private var totalCents: Int {
        entries.reduce(0) { $0 + $1.amountCents }
    }

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    Text("No tips logged this day.")
                        .foregroundStyle(PaydayColor.textSecondary)
                        .listRowSeparator(.hidden)
                } else {
                    if entries.count > 1 {
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

                    Section("Entries") {
                        ForEach(entries) { entry in
                            Button {
                                sheetTarget = .edit(entry)
                            } label: {
                                EntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    undoState.delete(entry, in: modelContext)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .entryContextMenu(entry, sheetTarget: $sheetTarget, undoState: undoState, context: modelContext)
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
}
