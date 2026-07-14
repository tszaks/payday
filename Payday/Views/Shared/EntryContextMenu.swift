import SwiftUI
import SwiftData

/// Edit, Duplicate, Delete — the same three actions on every entry row,
/// wherever entries are listed (Dashboard, day detail, period detail).
extension View {
    func entryContextMenu(_ entry: TipEntry, sheetTarget: Binding<TipEntrySheetTarget?>, undoState: UndoDeleteToastState, context: ModelContext) -> some View {
        contextMenu {
            Button {
                sheetTarget.wrappedValue = .edit(entry)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                duplicateTipEntry(entry, into: context)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                undoState.delete(entry, in: context)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

@MainActor
private func duplicateTipEntry(_ entry: TipEntry, into context: ModelContext) {
    let copy = TipEntry(date: entry.date, amountCents: entry.amountCents, kind: entry.kind, note: entry.note, recordedAt: .now, isDouble: entry.isDouble)
    context.insert(copy)
    try? context.save()
    PaydayHaptics.medium()
}
