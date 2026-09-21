import SwiftUI
import SwiftData
import UIKit

/// Immediate delete + Undo toast — Apple's own grammar (Mail, Reminders,
/// Notes) for a destructive swipe action. Deletes right away rather than
/// asking first; Undo is the safety net, not a dialog. One shift is one
/// `ShiftRecord`, so delete and undo act on a single row.
@MainActor
@Observable
final class UndoDeleteToastState {
    private var dismissTask: Task<Void, Never>?

    /// The one pending deletion the toast can undo.
    private(set) var deletedShift: ShiftCommands.DeletedShift?

    var hasPendingUndo: Bool { deletedShift != nil }

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
    /// this must NOT wrap it in another commit: that would nest one
    /// transaction inside another and give the set two saves rather than one.
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
