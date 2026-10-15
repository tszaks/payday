import Foundation
import SwiftData
import Testing
@testable import Payday

/// Remove Paycheck is hide-now, delete-when-the-Undo-window-closes.
/// These pin the three promises the design makes: Undo commits nothing,
/// expiry commits exactly once, and a kill before expiry commits nothing.
@Suite("Deferred paycheck removal", .serialized)
@MainActor
struct DeferredPaycheckRemovalTests {

    private func registeredAccount() -> UUID {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let id = UUID()
        PaydaySyncState.forget(userID: id)
        _ = PaydaySyncState.registerCurrentUser(id)
        return id
    }

    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func paycheck(in context: ModelContext) throws -> PaycheckRecord {
        let record = PaycheckRecord(
            periodStart: Date(timeIntervalSince1970: 1_756_000_000),
            periodEnd: Date(timeIntervalSince1970: 1_756_600_000),
            paidTipsCents: 12_300
        )
        context.insert(record)
        try context.save()
        return record
    }

    private func rowCount(in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<PaycheckRecord>()).count
    }

    /// A removal whose timer never fires on its own, so each test decides
    /// when the window ends.
    private func removal() -> DeferredPaycheckRemoval {
        DeferredPaycheckRemoval(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
    }

    @Test("removing hides the paycheck at once and deletes nothing")
    func removeOnlyHides() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = try paycheck(in: context)
        let removal = removal()

        removal.remove(record, in: context)

        #expect(removal.isHidden(record.id))
        #expect([record].hidingPendingRemoval(removal).isEmpty)
        #expect(try rowCount(in: context) == 1)
        #expect(PaydaySyncState.pendingPaycheckDeletions(for: userID).isEmpty)
    }

    @Test("Undo commits nothing and shows the paycheck again")
    func undoCommitsNothing() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = try paycheck(in: context)
        let removal = removal()
        var commits = 0

        removal.remove(id: record.id) { commits += 1 }
        let token = try #require(removal.pendingToken)
        #expect(removal.undo())

        // The timer firing late, after Undo, must find nothing.
        removal.expire(token: token)

        #expect(commits == 0)
        #expect(!removal.hasPending)
        #expect([record].hidingPendingRemoval(removal).count == 1)
        #expect(try rowCount(in: context) == 1)
        #expect(PaydaySyncState.pendingPaycheckDeletions(for: userID).isEmpty)
    }

    @Test("expiry commits exactly once, however many times it is reached")
    func expiryCommitsOnce() throws {
        let removal = removal()
        var commits = 0

        removal.remove(id: UUID()) { commits += 1 }
        let token = try #require(removal.pendingToken)
        removal.expire(token: token)
        removal.expire(token: token)
        removal.flush()
        #expect(!removal.undo())

        #expect(commits == 1)
        #expect(!removal.hasPending)
    }

    @Test("expiry deletes the row and queues one server deletion")
    func expiryDeletesRowAndQueues() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = try paycheck(in: context)
        let id = record.id
        let removal = removal()

        removal.remove(record, in: context)
        removal.expire(token: try #require(removal.pendingToken))

        #expect(try rowCount(in: context) == 0)
        #expect(Set(PaydaySyncState.pendingPaycheckDeletions(for: userID).keys) == [id])
    }

    @Test("a stale timer from an earlier removal cannot commit a later one")
    func staleTokenIsIgnored() throws {
        let removal = removal()
        var first = 0
        var second = 0

        removal.remove(id: UUID()) { first += 1 }
        let staleToken = try #require(removal.pendingToken)
        // Starting the second closes the first window: first commits once.
        removal.remove(id: UUID()) { second += 1 }
        #expect(first == 1)

        removal.expire(token: staleToken)
        #expect(second == 0)
        #expect(removal.hasPending)
    }

    /// The hide is in memory only. A process killed inside the window never
    /// ran the commit, so a fresh process sees the paycheck and an empty
    /// queue: nothing was deleted.
    @Test("termination before expiry commits nothing")
    func terminationCommitsNothing() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = try paycheck(in: context)
        var removal: DeferredPaycheckRemoval? = removal()
        var commits = 0

        removal?.remove(id: record.id) { commits += 1 }
        removal = nil // the process dies; no expiry ever runs

        let relaunched = DeferredPaycheckRemoval()
        #expect(!relaunched.hasPending)
        #expect([record].hidingPendingRemoval(relaunched).count == 1)
        #expect(commits == 0)
        #expect(try rowCount(in: context) == 1)
        #expect(PaydaySyncState.pendingPaycheckDeletions(for: userID).isEmpty)
    }

    @Test("a failed commit leaves the paycheck visible and not queued")
    func failedCommitShowsPaycheckAgain() throws {
        let removal = removal()
        struct Boom: Error {}

        removal.remove(id: UUID()) { throw Boom() }
        removal.expire(token: try #require(removal.pendingToken))

        #expect(removal.lastCommitFailed)
        #expect(!removal.hasPending)
    }

    @Test("the toast state shows one toast, and its Undo cancels the paycheck removal")
    func toastStateUndoesPaycheck() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = try paycheck(in: context)
        let state = UndoDeleteToastState(paycheckRemoval: removal())

        state.removePaycheck(record, in: context)
        #expect(state.hasPendingUndo)
        #expect(state.message == "Paycheck removed")

        state.undo(in: context)

        #expect(!state.hasPendingUndo)
        #expect(try rowCount(in: context) == 1)
        #expect(PaydaySyncState.pendingPaycheckDeletions(for: userID).isEmpty)
    }

    @Test("deleting a shift closes a waiting paycheck removal instead of dropping it")
    func shiftDeleteFlushesPaycheck() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = try paycheck(in: context)
        let id = record.id
        let shift = ShiftRecord(workDate: Date(timeIntervalSince1970: 1_756_000_000), cashTipsCents: 5_000)
        context.insert(shift)
        try context.save()
        let state = UndoDeleteToastState(paycheckRemoval: removal())

        state.removePaycheck(record, in: context)
        state.delete(shift, in: context)

        #expect(Set(PaydaySyncState.pendingPaycheckDeletions(for: userID).keys) == [id])
        #expect(state.message == "Shift deleted")
        #expect(state.hasPendingUndo)
    }
}
