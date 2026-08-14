import SwiftUI
import SwiftData
import UIKit

/// Plain field snapshot of a TipEntry, captured right before deletion so
/// Undo can rebuild it — the SwiftData model instance itself is gone from
/// the context by the time Undo might be tapped.
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
        TipEntry(id: id, date: date, amountCents: amountCents, kind: kind, note: note, recordedAt: recordedAt, hoursWorked: hoursWorked, tipOutCents: tipOutCents, salesCents: salesCents, shiftPeriod: shiftPeriod, shiftID: shiftID, clockIn: clockIn, clockOut: clockOut, serverCount: serverCount, receiptMetrics: receiptMetrics)
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
        .animation(PaydayAnimation.premiumSpring, value: state.snapshot != nil)
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
