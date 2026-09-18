import SwiftUI
import SwiftData
import UIKit

/// Plain field snapshot of a TipEntry, captured right before deletion so
/// Undo can rebuild it — the SwiftData model instance itself is gone from
/// the context by the time Undo might be tapped.
///
/// ## Why this file is in PR 5's shared-component slice (METRICS [SC-10])
///
/// Like Duplicate, it shows no figure and is a PRODUCER of every stored
/// money and hours figure of a whole shift — the only one that destroys
/// them and then rewrites them verbatim. It is upstream of every consumer of
/// those fields in BOTH directions, since a delete zeroes them and an undo
/// restores them.
///
/// Its contract is that Undo is an EXACT INVERSE: the shift the engine
/// values after a delete-then-undo is the shift it valued before, to the
/// cent and to the minute. Two fields are deliberately not restored
/// verbatim, and neither is money: `modifiedAt` moves to now (via `touch()`,
/// so the sync leg knows the row changed) and the pending-deletion queue
/// entry is cancelled.
///
/// **Wave 0 changed nothing here, and pinned it instead.**
/// `SharedComponentSnapshotTests.undoIsAnExactInverseThroughTheEngine`
/// values a shift, snapshots it, restores it, values it again, and asserts
/// the two `ShiftValuation`s are equal. A field silently dropped from
/// `DeletedTipSnapshot` — which is what this type's own header records
/// happening once before, when hours, tip-out, sales, period, clock times
/// and server count were all lost on undo — now fails a test instead of
/// quietly changing someone's earnings.
struct DeletedTipSnapshot {
    let id: UUID
    let date: Date
    let amountCents: Int
    let kind: TipKind
    let note: String?
    let recordedAt: Date?
    // Captured so an undo rejoins the exact shift it left, with its
    // canonical hours/tip-out/sales/period/clock-times/server-count intact
    // — all previously dropped.
    let shiftID: UUID?
    let hoursWorked: Double?
    let tipOutCents: Int?
    let salesCents: Int?
    let shiftPeriod: ShiftPeriod?
    let clockIn: Date?
    let clockOut: Date?
    let serverCount: Int?
    let receiptMetrics: ShiftReceiptMetrics?

    init(entry: TipEntry) {
        id = entry.id
        date = entry.date
        amountCents = entry.amountCents
        kind = entry.kind
        note = entry.note
        recordedAt = entry.recordedAt
        shiftID = entry.shiftID
        hoursWorked = entry.hoursWorked
        tipOutCents = entry.tipOutCents
        salesCents = entry.salesCents
        shiftPeriod = entry.shiftPeriod
        clockIn = entry.clockIn
        clockOut = entry.clockOut
        serverCount = entry.serverCount
        receiptMetrics = entry.receiptMetrics
    }

    func restored() -> TipEntry {
        let entry = TipEntry(id: id, date: date, amountCents: amountCents, kind: kind, note: note, recordedAt: recordedAt, hoursWorked: hoursWorked, tipOutCents: tipOutCents, salesCents: salesCents, shiftPeriod: shiftPeriod, shiftID: shiftID, clockIn: clockIn, clockOut: clockOut, serverCount: serverCount, receiptMetrics: receiptMetrics)
        entry.touch()
        return entry
    }
}

/// Immediate delete + Undo toast — Apple's own grammar (Mail, Reminders,
/// Notes) for a destructive swipe action. Deletes right away rather than
/// asking first; Undo is the safety net, not a dialog. Operates on a whole
/// shift's rows at once now (a merged cash+credit closeout deletes and
/// undoes together), never a lone entry.
@MainActor
@Observable
final class UndoDeleteToastState {
    private(set) var snapshots: [DeletedTipSnapshot] = []
    private var dismissTask: Task<Void, Never>?

    /// The atomic write, injected so the FAILURE branch is reachable from a
    /// test. Production passes the default and behaves exactly as before.
    ///
    /// Worth stating why this seam earns its keep, because the schema has no
    /// `@Attribute(.unique)` and it is tempting to conclude `save()` cannot
    /// fail. It can: a CloudKit conflict, disk pressure, or context
    /// validation all surface as a throw here. So the ordering this class
    /// depends on — queue the server-side deletion only AFTER the local write
    /// has persisted — is a live production path, and it is the one ordering
    /// whose failure makes the app and the server disagree about whether the
    /// user's money exists. `design-lint.sh` rule 18 keeps the shape; this is
    /// what lets a test assert the behaviour.
    typealias Committer = (ModelContext, () throws -> Void) throws -> Void

    private let commitWrite: Committer

    init(commitWrite: @escaping Committer = { try ShiftCommands.commit(in: $0, $1) }) {
        self.commitWrite = commitWrite
    }

    /// The shift-representation undo, beside the legacy one rather than
    /// replacing it.
    ///
    /// Both are needed at once during the conversion window: a shipped 1.0
    /// build writes `TipEntry` and an account that has not converted still
    /// reads it, while a converted account deletes a `ShiftRecord`. Only one
    /// can be pending at a time, because the toast shows one undo.
    private(set) var deletedShift: ShiftCommands.DeletedShift?

    var snapshot: DeletedTipSnapshot? { snapshots.first }

    /// One signal for the view layer, so the toast does not have to know which
    /// representation it is undoing.
    var hasPendingUndo: Bool { snapshot != nil || deletedShift != nil }

    // MARK: - The shift representation

    /// Deletes one `ShiftRecord`.
    ///
    /// Singular, where the legacy path takes an array, and that is the point:
    /// the array exists only because a merged cash+credit closeout is TWO
    /// `TipEntry` rows. One shift is one `ShiftRecord`, so the plural
    /// disappears with the two-row model.
    ///
    /// `ShiftCommands.delete` owns the ordering -- it removes the row, saves,
    /// and only then writes the deletion queue and the tombstone (#51). So
    /// this must NOT wrap it in `commitWrite`: that would nest one transaction
    /// inside another and give the set two saves rather than one.
    ///
    /// A refusal is expected rather than exceptional. `mayMutate` declines a
    /// record with unconfirmed `legacyEntryIDs` while shifts are not yet
    /// authoritative, because editing an unconfirmed fold result could clobber
    /// a refold. On refusal nothing is deleted and no toast appears, so the
    /// row simply stays -- which is the truth.
    func delete(_ record: ShiftRecord, in context: ModelContext) {
        let captured: ShiftCommands.DeletedShift
        do {
            captured = try ShiftCommands.delete(record, in: context)
        } catch {
            return
        }

        dismissTask?.cancel()
        deletedShift = captured
        PaydayHaptics.medium()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.deletedShift = nil
        }
    }

    /// Deletes through the atomic boundary, and queues the server-side
    /// deletion only once the local delete has actually persisted.
    ///
    /// The order here is the whole point. The shipped version called
    /// `recordTipDeletions` FIRST and then `try? context.save()`, so a failed
    /// save left the rows on screen while their ids sat in the App Group's
    /// pending-deletion queue. The next sync would then delete, on the server,
    /// rows the user could still see — and the app and the server would
    /// disagree about whether that money exists. `try?` made it silent.
    ///
    /// So: snapshot first (the properties are unreadable once the objects are
    /// deleted), then mutate inside `ShiftCommands.commit`, which saves once
    /// and rolls back on any throw, and only afterwards touch the queue and
    /// the toast. If the save fails nothing is queued, nothing is dismissed,
    /// and the rows stay visible — which is the truth.
    func delete(_ entries: [TipEntry], in context: ModelContext) {
        guard !entries.isEmpty else { return }
        let taken = entries.map(DeletedTipSnapshot.init)
        let ids = entries.map(\.id)

        do {
            try commitWrite(context) {
                for entry in entries { context.delete(entry) }
            }
        } catch {
            // Rolled back: the rows are still here and still the user's.
            // Nothing queued, no toast, no haptic — the failure is visible as
            // the row simply not going away.
            return
        }

        dismissTask?.cancel()
        PaydaySyncState.recordTipDeletions(ids)
        snapshots = taken
        PaydayHaptics.medium()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.snapshots = []
        }
    }

    /// Restores through the same boundary, and un-queues the server deletion
    /// only once the rows are actually back.
    ///
    /// Mirror of the hazard in `delete`. The shipped version called
    /// `cancelTipDeletions` first, so a failed insert left the rows gone
    /// locally with the server deletion cancelled: the row exists on the
    /// server, is absent on the device, and the toast has already been
    /// dismissed, so the user has no way back to it. Cancelling only after a
    /// successful save means a failure leaves the deletion still queued and
    /// the toast still up, so Undo can simply be tapped again.
    func undo(in context: ModelContext) {
        if let captured = deletedShift {
            do {
                _ = try ShiftCommands.restore(captured, in: context)
            } catch {
                // Rolled back, and deliberately NOT dismissed: the deletion is
                // still queued and the tombstone still stands (#51), so the one
                // affordance that can recover this shift is still on screen.
                return
            }
            dismissTask?.cancel()
            deletedShift = nil
            PaydayHaptics.success()
            return
        }

        guard !snapshots.isEmpty else { return }
        let restoring = snapshots

        do {
            try commitWrite(context) {
                for snapshot in restoring { context.insert(snapshot.restored()) }
            }
        } catch {
            // Rolled back, and deliberately NOT dismissed: the deletion is
            // still queued and the toast is still on screen, so the one
            // affordance that can recover this row is still reachable.
            return
        }

        dismissTask?.cancel()
        PaydaySyncState.cancelTipDeletions(restoring.map(\.id))
        snapshots = []
        PaydayHaptics.success()
    }
}

private struct UndoDeleteToastModifier: ViewModifier {
    @Bindable var state: UndoDeleteToastState
    let context: ModelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if state.hasPendingUndo {
                toast
                    .padding(.horizontal, PaydaySpacing.md)
                    .padding(.bottom, PaydaySpacing.md)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        UIAccessibility.post(notification: .announcement, argument: "Shift deleted")
                    }
            }
        }
        .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: state.hasPendingUndo)
    }

    private var toast: some View {
        HStack {
            Text("Shift deleted")
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textPrimary)
            Spacer()
            Button("Undo") {
                state.undo(in: context)
            }
            .font(PaydayFont.subheadlineSemibold)
            .foregroundStyle(PaydayColor.primary)
        }
        .padding(.horizontal, PaydaySpacing.md)
        .padding(.vertical, PaydaySpacing.sm)
        .paydayNativeGlassRoundedRect(cornerRadius: PaydayRadius.md)
    }
}

extension View {
    func undoDeleteToast(_ state: UndoDeleteToastState, context: ModelContext) -> some View {
        modifier(UndoDeleteToastModifier(state: state, context: context))
    }
}
