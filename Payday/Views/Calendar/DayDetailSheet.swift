import SwiftUI
import SwiftData

struct DayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allEntries: [TipEntry]

    let date: Date
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var undoState = UndoDeleteToastState()

    private var entries: [TipEntry] {
        let day = Calendar.current.startOfDay(for: date)
        return allEntries
            .filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.amountCents > $1.amountCents }
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
                    Section {
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
                    } header: {
                        Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    } footer: {
                        if entries.count > 1 {
                            Text("Total: \(Money.string(fromCents: totalCents))")
                                .monospacedDigit()
                        }
                    }
                    .listRowBackground(PaydayColor.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PaydayColor.background)
            .navigationTitle(date.formatted(.dateTime.month(.abbreviated).day()))
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
