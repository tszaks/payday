import Foundation
import SwiftData
import Testing
@testable import Payday

/// The invariant that makes four call sites wrong, and the misconception it
/// closes.
///
/// `LogTipSheet.delete` carried this comment, directly above a
/// `recordTipDeletions` call placed INSIDE a `ShiftCommands.commit` body:
///
///   "Queued and deleted together, so the server cannot be told about a
///    deletion the device then fails to make, or the reverse."
///
/// Co-locating the two does not achieve that, and cannot. The pending-deletion
/// queue is App Group `UserDefaults` -- `recordTipDeletions` ends in
/// `AppGroup.defaults.set(...)`, which takes effect immediately -- while the
/// rows are SwiftData. `ModelContext.rollback()` restores the rows and has no
/// power over the queue at all. Putting the call inside the transaction body
/// only makes it LOOK transactional.
///
/// So this suite asserts the uncomfortable fact rather than the comforting
/// comment: a rolled-back transaction leaves the queue written. Everything
/// that follows from it -- recording the deletion only after a successful
/// save, at every call site -- depends on this being true, so it is asserted
/// once, here, instead of being re-argued per site.
@Suite("Deletion queue atomicity", .serialized)
@MainActor
struct DeletionQueueAtomicityTests {

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

    private static let day = Date(timeIntervalSince1970: 1_756_000_000)

    /// The load-bearing fact. If this ever starts failing, the queue has
    /// become transactional and every "record only after the save" ordering
    /// in the tree can be simplified.
    @Test("a rolled-back transaction restores the rows but does NOT unqueue the deletion")
    func rollbackDoesNotUndoTheQueueWrite() throws {
        let userID = registeredAccount()
        let context = try context()
        let row = TipEntry(date: Self.day, amountCents: 4_200, kind: .cash, shiftID: UUID())
        context.insert(row)
        try context.save()
        let rowID = row.id

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try ShiftCommands.commit(in: context) {
                // Exactly the shipped shape: queue inside the transaction.
                PaydaySyncState.recordTipDeletions([rowID])
                context.delete(row)
                throw Boom()
            }
        }

        // SwiftData rolled back, as designed.
        #expect(try context.fetch(FetchDescriptor<TipEntry>()).count == 1)

        // And the queue did NOT, which is the whole point. The row is back on
        // the device while its id is still queued for deletion on the server,
        // so the next sync removes money the user can still see.
        #expect(PaydaySyncState.pendingTipDeletions(for: userID).keys.contains(rowID))
    }

    /// The correct ordering, asserted as the positive case: queue only after
    /// the save has actually succeeded, and a failure leaves the queue clean.
    @Test("recording after a successful commit queues; after a failed one, nothing is queued")
    func recordingAfterTheCommitIsSafeInBothDirections() throws {
        let userID = registeredAccount()
        let context = try context()
        let row = TipEntry(date: Self.day, amountCents: 4_200, kind: .cash, shiftID: UUID())
        context.insert(row)
        try context.save()
        let rowID = row.id

        // The failing direction first, so a leaked queue entry from it would
        // be visible in the assertions below rather than masked by them.
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try ShiftCommands.commit(in: context) {
                context.delete(row)
                throw Boom()
            }
        }
        #expect(try context.fetch(FetchDescriptor<TipEntry>()).count == 1)
        #expect(PaydaySyncState.pendingTipDeletions(for: userID).isEmpty)

        // Now the succeeding direction, with the record AFTER the commit.
        let survivor = try #require(try context.fetch(FetchDescriptor<TipEntry>()).first)
        try ShiftCommands.commit(in: context) {
            context.delete(survivor)
        }
        PaydaySyncState.recordTipDeletions([rowID])

        #expect(try context.fetch(FetchDescriptor<TipEntry>()).isEmpty)
        #expect(PaydaySyncState.pendingTipDeletions(for: userID).keys.contains(rowID))
    }
}
