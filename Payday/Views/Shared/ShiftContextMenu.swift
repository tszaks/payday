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
    /// The same three actions on a `ShiftRecord`.
    ///
    /// The verbatim-copy contract above still holds, and gets simpler: one
    /// record holds every stored field canonically, so Duplicate copies them
    /// across with the same two substitutions -- a fresh id and
    /// `recordedAt: .now` -- and there is no per-row canonical-owner rule to
    /// preserve, because there are no rows to disagree.
    ///
    /// The wage caveat is unchanged and still deliberate: a duplicate adds
    /// hours to the workweek, so a copy that pushes the week past the
    /// overtime threshold is priced differently from its source, by rule.
    func shiftContextMenu(
        record: ShiftRecord,
        sheetTarget: Binding<TipEntrySheetTarget?>,
        undoState: UndoDeleteToastState,
        context: ModelContext
    ) -> some View {
        contextMenu {
            Button {
                sheetTarget.wrappedValue = .editShift(record)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                duplicateShift(record, into: context)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                undoState.delete(record, in: context)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

}

/// Duplicates one record verbatim, through the command boundary.
///
/// `ShiftCommands.create` rather than a hand-rolled insert, so the copy goes
/// through the same single-save-and-rollback path every other write uses, and
/// so the haptic fires only on success -- the legacy sibling fired it
/// unconditionally after a `try?` and buzzed success on a failed duplicate.
@MainActor
private func duplicateShift(_ record: ShiftRecord, into context: ModelContext) {
    do {
        _ = try ShiftCommands.create(
            in: context,
            workDate: record.workDate,
            shiftPeriod: record.shiftPeriod,
            cashTipsCents: record.cashTipsCents,
            creditTipsCents: record.creditTipsCents,
            tipOutCents: record.tipOutCents,
            salesCents: record.salesCents,
            hoursWorked: record.hoursWorked,
            clockIn: record.clockIn,
            clockOut: record.clockOut,
            serverCount: record.serverCount,
            receiptMetrics: record.receiptMetrics,
            note: record.note
        )
    } catch {
        return
    }
    PaydayHaptics.medium()
}
