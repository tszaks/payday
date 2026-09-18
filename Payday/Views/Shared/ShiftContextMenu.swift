import SwiftUI
import SwiftData

/// Edit, Duplicate, Delete — the same three actions on every shift row,
/// wherever shifts are listed (Dashboard, day detail, period detail).
/// Scoped to the whole shift now, not one entry: duplicating or deleting a
/// merged cash+credit closeout acts on both rows together.
///
/// ## Why this file is in PR 5's shared-component slice (METRICS [SC-08])
///
/// It shows no figure, and that is exactly the point: Duplicate is the third
/// live on-device PRODUCER of stored money and hours figures (after the scan
/// prefill and the launch-time hours rewrite), and the only one that writes
/// them with no user-entered value. One tap moves every consumer of those
/// fields at once.
///
/// Its contract is that it copies verbatim. No arithmetic, no
/// normalization, no re-derivation of the shift-level fields — every stored
/// field is copied per row, with exactly two substitutions: one fresh
/// `shiftID` shared by the whole copy, and `recordedAt: .now`. Copying per
/// row rather than re-deriving automatically preserves the canonical rule
/// that only the row which held hours/tip-out/sales/period/clock-times/
/// server-count in the source still holds them in the copy.
///
/// **Wave 0 changed nothing here, and pinned it instead.**
/// `SharedComponentSnapshotTests.duplicateIsValuedIdenticallyByTheEngine`
/// duplicates a shift, values both through `CompensationLedger`, and asserts
/// the copy's non-wage components and minutes are identical to the source's.
/// That test fails if any future edit normalizes a stored amount, drops a
/// receipt payload, or re-derives hours — which is the whole class of bug a
/// verbatim-copy contract exists to prevent.
///
/// Note the one thing the copy may legitimately change: its WAGE. A
/// duplicate adds hours to the workweek, so a copy that pushes the week past
/// the overtime threshold is priced differently from its source, by rule
/// (Design 1, step 4). The test asserts on the non-wage side for exactly
/// that reason.
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

    // Through the atomic boundary, and the haptic only on success. With
    // `autosaveEnabled = false` a `try?` here meant a failed save duplicated
    // nothing at all while still firing the haptic, so the gesture reported
    // that it had worked and the copy was simply absent. The inserts sit
    // INSIDE the boundary because these rows are one closeout sharing one
    // fresh shiftID, and half of them is not a shift.
    do {
        try ShiftCommands.commit(in: context) {
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
                    serverCount: entry.serverCount,
                    receiptMetrics: entry.receiptMetrics
                )
                context.insert(copy)
            }
        }
    } catch {
        return
    }
    PaydayHaptics.medium()
}
