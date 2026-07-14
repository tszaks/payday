import SwiftUI
import SwiftData

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
    let isDouble: Bool

    init(entry: TipEntry) {
        id = entry.id
        date = entry.date
        amountCents = entry.amountCents
        kind = entry.kind
        note = entry.note
        recordedAt = entry.recordedAt
        isDouble = entry.isDouble
    }

    func restored() -> TipEntry {
        TipEntry(id: id, date: date, amountCents: amountCents, kind: kind, note: note, recordedAt: recordedAt, isDouble: isDouble)
    }
}

/// Immediate delete + Undo toast — Apple's own grammar (Mail, Reminders,
/// Notes) for a destructive swipe action. Deletes right away rather than
/// asking first; Undo is the safety net, not a dialog.
@MainActor
@Observable
final class UndoDeleteToastState {
    private(set) var snapshot: DeletedTipSnapshot?
    private var dismissTask: Task<Void, Never>?

    func delete(_ entry: TipEntry, in context: ModelContext) {
        dismissTask?.cancel()
        snapshot = DeletedTipSnapshot(entry: entry)
        context.delete(entry)
        try? context.save()
        PaydayHaptics.medium()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.snapshot = nil
        }
    }

    func undo(in context: ModelContext) {
        guard let snapshot else { return }
        dismissTask?.cancel()
        context.insert(snapshot.restored())
        try? context.save()
        self.snapshot = nil
        PaydayHaptics.success()
    }
}

private struct UndoDeleteToastModifier: ViewModifier {
    @Bindable var state: UndoDeleteToastState
    let context: ModelContext

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if state.snapshot != nil {
                toast
                    .padding(.horizontal, PaydaySpacing.md)
                    .padding(.bottom, PaydaySpacing.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(PaydayAnimation.premiumSpring, value: state.snapshot != nil)
    }

    private var toast: some View {
        HStack {
            Text("Tip deleted")
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
