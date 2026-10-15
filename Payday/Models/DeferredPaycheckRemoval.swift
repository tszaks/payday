import Foundation
import SwiftData
import Observation

/// Remove Paycheck, deferred.
///
/// Tyler's rule is that a delete acts now and offers Undo. For a shift that
/// means "delete, then restore from a captured copy". For a paycheck the
/// safer shape is the reverse: HIDE now, and delete for real only when the
/// Undo window closes without Undo.
///
/// ## Why hide first
///
/// - Undo is trivial and exact. The row never left the store, so nothing is
///   re-created and nothing can come back different.
/// - If the app is killed or terminated inside the window, NOTHING was
///   deleted. The hide lives in memory only, so on next launch the paycheck
///   is simply there. That is the safe direction for money data.
/// - The sync queue is untouched during the window. The sync plan sees an
///   ordinary live row, so a sync (or a pull) that runs while the toast is
///   up cannot upload a delete, double-delete, or treat the row as restored.
///
/// ## Exactly one commit
///
/// Everything runs on the main actor. `expire` takes the pending entry OUT of
/// `pending` before it commits, so the Undo tap, the timer, and a second
/// removal that flushes this one can each reach it, and only the first finds
/// anything to commit. The timer also carries a token, so a timer that
/// belonged to an earlier removal cannot commit a later one.
///
/// ## Commit order
///
/// Same as every other delete in the app: remove the row and save, and only
/// then write the deletion queue (`PaydaySyncState.recordPaycheckDeletion`).
/// A failed save leaves the row alive with nothing queued, and the paycheck
/// is shown again, which is the truth.
@MainActor
@Observable
final class DeferredPaycheckRemoval {
    static let shared = DeferredPaycheckRemoval()

    /// How long Undo stays available. Matches the shift toast.
    static let window: Duration = .seconds(4)

    /// Posted whenever the hidden set changes (hide, Undo, commit). The
    /// earnings engine rebuilds on it, so every figure on every screen drops
    /// or regains the paycheck in the same moment the list does.
    nonisolated static let visibilityDidChange = EarningsStore.paycheckVisibilityDidChange

    private struct Pending {
        let id: UUID
        let token: UUID
        let commit: () throws -> Void
    }

    private var pending: Pending?
    private var timer: Task<Void, Never>?
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Set when a commit failed, so the screen can say so. Cleared by the
    /// next removal.
    private(set) var lastCommitFailed = false

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    var hasPending: Bool { pending != nil }

    /// The paycheck that is hidden right now, if any. Screens that list
    /// paychecks drop this id.
    var hiddenID: UUID? { pending?.id }

    /// Same, as a set, for the engine's input source.
    var hiddenIDs: Set<UUID> { pending.map { [$0.id] } ?? [] }

    func isHidden(_ id: UUID) -> Bool { pending?.id == id }

    /// Hides one paycheck and starts the Undo window.
    ///
    /// `commit` performs the real delete. It is injected so a test can count
    /// calls; production passes `commitDelete(id:in:)` below.
    func remove(id: UUID, commit: @escaping () throws -> Void) {
        // One pending removal at a time, like the shift toast. A second one
        // closes the first window early: commit it now, rather than drop it.
        flush()
        lastCommitFailed = false
        let token = UUID()
        pending = Pending(id: id, token: token, commit: commit)
        announce()
        let sleep = self.sleep
        timer = Task { [weak self] in
            try? await sleep(Self.window)
            guard !Task.isCancelled else { return }
            self?.expire(token: token)
        }
    }

    /// Production entry point: removes the paycheck with this id from
    /// `context` when the window closes.
    func remove(_ record: PaycheckRecord, in context: ModelContext) {
        remove(id: record.id) { try Self.commitDelete(id: record.id, in: context) }
    }

    /// Undo. Shows the paycheck again; nothing was deleted, so nothing is
    /// restored. Returns whether there was anything to undo.
    @discardableResult
    func undo() -> Bool {
        guard pending != nil else { return false }
        timer?.cancel()
        timer = nil
        pending = nil
        announce()
        return true
    }

    /// Closes the window now and commits. Used when another removal starts.
    func flush() {
        guard let current = pending else { return }
        expire(token: current.token)
    }

    /// The timer's path, and the test seam for "the window ended".
    func expire(token: UUID) {
        guard let current = pending, current.token == token else { return }
        // Out of `pending` BEFORE the commit: whatever reaches this next
        // finds nothing, which is what makes the commit single-shot.
        pending = nil
        timer?.cancel()
        timer = nil
        do {
            try current.commit()
        } catch {
            lastCommitFailed = true
        }
        // After the commit, so a rebuild reads the final store.
        announce()
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.visibilityDidChange, object: nil)
    }

    /// Token of the pending removal, for tests.
    var pendingToken: UUID? { pending?.token }

    /// The real delete: row first, queue only once it is really gone.
    /// If the row is already gone (another device deleted it and a pull
    /// applied that), there is nothing to delete and nothing to queue.
    static func commitDelete(id: UUID, in context: ModelContext) throws {
        var descriptor = FetchDescriptor<PaycheckRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return }
        try ShiftCommands.commit(in: context) {
            context.delete(record)
        }
        PaydaySyncState.recordPaycheckDeletion(id)
    }
}

extension Array where Element == PaycheckRecord {
    /// The paychecks a screen should show: everything except one whose
    /// removal is waiting out its Undo window.
    @MainActor
    func hidingPendingRemoval(_ removal: DeferredPaycheckRemoval = .shared) -> [PaycheckRecord] {
        guard let hidden = removal.hiddenID else { return self }
        return filter { $0.id != hidden }
    }
}
