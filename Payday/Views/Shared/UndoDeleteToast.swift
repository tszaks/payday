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

    var snapshot: DeletedTipSnapshot? { snapshots.first }

    func delete(_ entries: [TipEntry], in context: ModelContext) {
        guard !entries.isEmpty else { return }
        dismissTask?.cancel()
        snapshots = entries.map(DeletedTipSnapshot.init)
        PaydaySyncState.recordTipDeletions(entries.map(\.id))
        for entry in entries { context.delete(entry) }
        try? context.save()
        PaydayHaptics.medium()
        PaydayWidgetRefresh.request()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.snapshots = []
        }
    }

    func undo(in context: ModelContext) {
        guard !snapshots.isEmpty else { return }
        dismissTask?.cancel()
        PaydaySyncState.cancelTipDeletions(snapshots.map(\.id))
        for snapshot in snapshots { context.insert(snapshot.restored()) }
        try? context.save()
        snapshots = []
        PaydayHaptics.success()
        PaydayWidgetRefresh.request()
    }
}

private struct UndoDeleteToastModifier: ViewModifier {
    @Bindable var state: UndoDeleteToastState
    let context: ModelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if state.snapshot != nil {
                toast
                    .padding(.horizontal, PaydaySpacing.md)
                    .padding(.bottom, PaydaySpacing.md)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        UIAccessibility.post(notification: .announcement, argument: "Shift deleted")
                    }
            }
        }
        .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: state.snapshot != nil)
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
