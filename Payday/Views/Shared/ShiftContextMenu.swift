import SwiftUI
import SwiftData

/// Edit, Duplicate, Delete — the same three actions on every shift row,
/// wherever shifts are listed (Dashboard, day detail, period detail).
/// Scoped to the whole shift now, not one entry: duplicating or deleting a
/// merged cash+credit closeout acts on both rows together.
extension View {
    func shiftContextMenu(_ entries: [TipEntry], sheetTarget: Binding<TipEntrySheetTarget?>, undoState: UndoDeleteToastState, context: ModelContext) -> some View {
        contextMenu {
            Button {
                guard let first = entries.first else { return }
                sheetTarget.wrappedValue = .edit(first)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                duplicateShift(entries, into: context)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                undoState.delete(entries, in: context)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

@MainActor
private func duplicateShift(_ entries: [TipEntry], into context: ModelContext) {
    guard !entries.isEmpty else { return }
    // A duplicate is a NEW closeout, so every copied row shares one fresh
    // shiftID (never the source's) — dropping a copy onto the same day
    // becomes an emergent second shift. Copying every stored field per row
    // (rather than re-deriving the shift-level ones) automatically preserves
    // the canonical rule: only the row that held hours/tip-out/sales/period/
    // clock times/server-count in the source still holds them in the copy.
    let shiftID = UUID()
    for entry in entries {
        let copy = TipEntry(
            date: entry.date,
            amountCents: entry.amountCents,
            kind: entry.kind,
            note: entry.note,
            recordedAt: .now,
            hoursWorked: entry.hoursWorked,
            tipOutCents: entry.tipOutCents,
            salesCents: entry.salesCents,
            shiftPeriod: entry.shiftPeriod,
            shiftID: shiftID,
            clockIn: entry.clockIn,
            clockOut: entry.clockOut,
            serverCount: entry.serverCount
        )
        context.insert(copy)
    }
    try? context.save()
    PaydayHaptics.medium()
}
