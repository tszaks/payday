import Foundation
import SwiftData
import Testing
@testable import Payday

/// PR 2 slice S9, second half: the swipe-delete toast writes through the
/// atomic boundary, and the server-side deletion queue is only touched once
/// the local write has actually persisted.
///
/// The ordering is the point. The shipped version recorded the server-side
/// deletion BEFORE `try? context.save()`, so a failed save left the rows on
/// screen with their ids already queued, and the next sync deleted rows the
/// user could still see. `try?` made that silent.
///
/// The failure branch is asserted, not just linted. `UndoDeleteToastState`
/// takes an injectable committer so a test can make the write throw, because
/// the branch is genuinely reachable in production: the schema has no
/// `@Attribute(.unique)`, but a CloudKit conflict, disk pressure or context
/// validation all surface as a throw from `save()`. `design-lint.sh` rule 18
/// keeps the shape cheaply; these tests are the real guard.
@Suite("Undo delete toast", .serialized)
@MainActor
struct UndoDeleteToastTests {

    /// A fresh registered account per test. `recordTipDeletions` resolves the
    /// account from the registration rather than taking it as an argument, so
    /// there has to be one for the queue to be written at all.
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

    /// A shift as two rows, which is how a merged cash+credit closeout is
    /// stored: the credit row holds the shift-level facts.
    private func closeout(in context: ModelContext, shiftID: UUID) -> [TipEntry] {
        let cash = TipEntry(date: Self.day, amountCents: 4_200, kind: .cash, shiftID: shiftID)
        let credit = TipEntry(
            date: Self.day,
            amountCents: 7_350,
            kind: .credit,
            hoursWorked: 6.5,
            tipOutCents: 1_100,
            shiftID: shiftID
        )
        context.insert(cash)
        context.insert(credit)
        try? context.save()
        return [cash, credit]
    }

    private func rowCount(in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<TipEntry>()).count
    }

    // MARK: - Forcing the write to fail

    /// A committer whose write can be made to throw on demand.
    ///
    /// It simulates a failing `save()` FAITHFULLY, which matters: the real
    /// boundary runs the mutation, then the save throws, then `rollback()`
    /// undoes it. Throwing before running the body would test a different and
    /// easier thing — a mutation that never happened — and would pass even if
    /// the production ordering were wrong.
    @MainActor
    private final class ControllableCommitter {
        struct Boom: Error {}
        var shouldThrow = false

        func commit(_ context: ModelContext, _ body: () throws -> Void) throws {
            guard shouldThrow else {
                return try ShiftCommands.commit(in: context, body)
            }
            try body()
            context.rollback()
            throw Boom()
        }
    }

    // MARK: - Delete

    @Test("deleting a closeout removes every row and queues every id")
    func deleteRemovesRowsAndQueuesIDs() throws {
        let userID = registeredAccount()
        let context = try context()
        let rows = closeout(in: context, shiftID: UUID())
        let ids = Set(rows.map(\.id))
        #expect(try rowCount(in: context) == 2)

        let state = UndoDeleteToastState()
        state.delete(rows, in: context)

        #expect(try rowCount(in: context) == 0)
        #expect(Set(PaydaySyncState.pendingTipDeletions(for: userID).keys) == ids)
        // The toast is the only route back to these rows, so it must be up.
        #expect(state.snapshot != nil)
    }

    /// The empty guard, which must not register anything. A queued deletion
    /// for an id that was never deleted is a deletion the server will perform
    /// against a row the user still has.
    @Test("deleting nothing queues nothing and raises no toast")
    func deletingNothingDoesNothing() throws {
        let userID = registeredAccount()
        let context = try context()
        let state = UndoDeleteToastState()

        state.delete([], in: context)

        #expect(PaydaySyncState.pendingTipDeletions(for: userID).isEmpty)
        #expect(state.snapshot == nil)
    }

    // MARK: - Undo

    @Test("undo restores every row and clears the queue")
    func undoRestoresRowsAndClearsQueue() throws {
        let userID = registeredAccount()
        let context = try context()
        let rows = closeout(in: context, shiftID: UUID())

        let state = UndoDeleteToastState()
        state.delete(rows, in: context)
        #expect(!PaydaySyncState.pendingTipDeletions(for: userID).isEmpty)

        state.undo(in: context)

        #expect(try rowCount(in: context) == 2)
        #expect(PaydaySyncState.pendingTipDeletions(for: userID).isEmpty)
        // Dismissed, because there is nothing left to undo.
        #expect(state.snapshot == nil)
    }

    /// `DeletedTipSnapshot` copies roughly fifteen fields by hand, and a
    /// dropped one is a SILENT money change: lose `tipOutCents` and undo
    /// hands back $11 the user never kept; lose `hoursWorked` and the shift
    /// vanishes from every hourly-rate and overtime figure while still
    /// showing its tips.
    ///
    /// Every field is set to a non-default value on purpose. A field left at
    /// its default would compare equal even if the snapshot dropped it, which
    /// is the same reason `ShiftCheckpointTests.fullyPopulated` exists.
    @Test("undo restores every stored field, not just the amount")
    func undoRestoresEveryStoredField() throws {
        _ = registeredAccount()
        let context = try context()

        var metrics = ShiftReceiptMetrics()
        metrics.gratuityFeesCents = 2_500
        metrics.netSalesCents = 88_000
        metrics.guestCount = 41

        let shiftID = UUID()
        let original = TipEntry(
            date: Self.day,
            amountCents: 7_350,
            kind: .credit,
            note: "double covered section 4",
            recordedAt: Self.day.addingTimeInterval(3_600),
            hoursWorked: 6.5,
            tipOutCents: 1_100,
            salesCents: 88_000,
            shiftPeriod: .dinner,
            shiftID: shiftID,
            clockIn: Self.day.addingTimeInterval(43_200),
            clockOut: Self.day.addingTimeInterval(66_600),
            serverCount: 3,
            receiptMetrics: metrics
        )
        context.insert(original)
        try context.save()

        let state = UndoDeleteToastState()
        state.delete([original], in: context)
        #expect(try rowCount(in: context) == 0)
        state.undo(in: context)

        let restored = try #require(try context.fetch(FetchDescriptor<TipEntry>()).first)
        #expect(restored.id == original.id)
        #expect(restored.date == Self.day)
        #expect(restored.amountCents == 7_350)
        #expect(restored.kind == .credit)
        #expect(restored.note == "double covered section 4")
        #expect(restored.recordedAt == Self.day.addingTimeInterval(3_600))
        #expect(restored.hoursWorked == 6.5)
        #expect(restored.tipOutCents == 1_100)
        #expect(restored.salesCents == 88_000)
        #expect(restored.shiftPeriod == .dinner)
        #expect(restored.shiftID == shiftID)
        #expect(restored.clockIn == Self.day.addingTimeInterval(43_200))
        #expect(restored.clockOut == Self.day.addingTimeInterval(66_600))
        #expect(restored.serverCount == 3)
        // The money-bearing half of the receipt. Dropping this loses gratuity
        // that the drawer, the period total and the paycheck all read.
        #expect(restored.receiptMetrics?.gratuityFeesCents == 2_500)
        #expect(restored.receiptMetrics?.netSalesCents == 88_000)
        #expect(restored.receiptMetrics?.guestCount == 41)
    }

    /// Undo with nothing pending must not clear another account's queue or
    /// insert a phantom row.
    @Test("undo with nothing pending is a no-op")
    func undoWithNothingPendingIsANoOp() throws {
        let userID = registeredAccount()
        let context = try context()
        PaydaySyncState.recordTipDeletions([UUID()])
        let before = PaydaySyncState.pendingTipDeletions(for: userID)

        let state = UndoDeleteToastState()
        state.undo(in: context)

        #expect(try rowCount(in: context) == 0)
        #expect(PaydaySyncState.pendingTipDeletions(for: userID).keys.sorted() == before.keys.sorted())
    }

    // MARK: - The ordering, when the write fails

    /// The bug this slice exists to close. The shipped version recorded the
    /// server-side deletion BEFORE the save, so a failure left the rows on
    /// screen with their ids queued, and the next sync deleted — on the
    /// server — rows the user could still see. Nothing may be queued, nothing
    /// dismissed, and no toast may claim a delete that did not happen.
    @Test("a failed delete queues nothing, keeps the rows, and raises no toast")
    func failedDeleteChangesNothing() throws {
        let userID = registeredAccount()
        let context = try context()
        let rows = closeout(in: context, shiftID: UUID())
        let committer = ControllableCommitter()
        let state = UndoDeleteToastState(commitWrite: committer.commit)
        committer.shouldThrow = true

        state.delete(rows, in: context)

        #expect(try rowCount(in: context) == 2)
        #expect(PaydaySyncState.pendingTipDeletions(for: userID).isEmpty)
        #expect(state.snapshot == nil)
    }

    /// The mirror. A failed undo must leave the deletion STILL queued and the
    /// toast STILL up, because the toast is the only affordance that can
    /// recover the row. Cancelling the queue first — as the shipped version
    /// did — left the row absent locally, present on the server, and
    /// unreachable from the UI.
    @Test("a failed undo keeps the deletion queued and the toast up")
    func failedUndoKeepsTheRecoveryPathOpen() throws {
        let userID = registeredAccount()
        let context = try context()
        let rows = closeout(in: context, shiftID: UUID())
        let ids = Set(rows.map(\.id))
        let committer = ControllableCommitter()
        let state = UndoDeleteToastState(commitWrite: committer.commit)

        // A real delete first, so there is something to fail to undo.
        state.delete(rows, in: context)
        #expect(try rowCount(in: context) == 0)
        #expect(Set(PaydaySyncState.pendingTipDeletions(for: userID).keys) == ids)

        committer.shouldThrow = true
        state.undo(in: context)

        #expect(try rowCount(in: context) == 0)
        // Still queued: the server deletion must not be cancelled for a row
        // that was not actually restored.
        #expect(Set(PaydaySyncState.pendingTipDeletions(for: userID).keys) == ids)
        // Still up: Undo can simply be tapped again.
        #expect(state.snapshot != nil)
    }
}
