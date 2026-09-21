import Foundation
import SwiftData
import Testing
@testable import Payday

/// The swipe-delete toast writes through the atomic boundary, and the
/// server-side deletion queue is only touched once the local write has
/// actually persisted.
///
/// The ordering is the point. The shipped version recorded the server-side
/// deletion BEFORE `try? context.save()`, so a failed save left the rows on
/// screen with their ids already queued, and the next sync deleted rows the
/// user could still see. `try?` made that silent.
///
/// The failure branches are asserted through the two reachable refusals —
/// `ShiftCommands.delete` throwing `.conversionPending` for an unconfirmed
/// fold result, and `ShiftQueueOrderingTests` owning the save-throws ordering
/// at the command level — because the toast no longer wraps the write in an
/// injectable committer: `ShiftCommands.delete` IS the boundary.
@Suite("Undo delete toast", .serialized)
@MainActor
struct UndoDeleteToastTests {

    /// A fresh registered account per test. `recordShiftDeletion` resolves the
    /// account from the registration rather than taking it as an argument, so
    /// there has to be one for the queue to be written at all.
    private func registeredAccount(authoritative: Bool = true) -> UUID {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let id = UUID()
        PaydaySyncState.forget(userID: id)
        _ = PaydaySyncState.registerCurrentUser(id)
        if authoritative {
            PaydaySyncState.mutate(userID: id) {
                $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
            }
        }
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

    /// One shift, which since the flip is one row: cash and credit merged.
    private func closeout(in context: ModelContext) -> ShiftRecord {
        let record = ShiftRecord(
            workDate: Self.day,
            cashTipsCents: 4_200,
            creditTipsCents: 7_350,
            tipOutCents: 1_100,
            hoursWorked: 6.5
        )
        context.insert(record)
        try? context.save()
        return record
    }

    private func rowCount(in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<ShiftRecord>()).count
    }

    // MARK: - Delete

    @Test("deleting a shift removes the row and queues its id")
    func deleteRemovesRowsAndQueuesIDs() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = closeout(in: context)
        #expect(try rowCount(in: context) == 1)

        let state = UndoDeleteToastState()
        state.delete(record, in: context)

        #expect(try rowCount(in: context) == 0)
        #expect(Set(PaydaySyncState.pendingShiftDeletions(for: userID).keys) == [record.id])
        // The toast is the only route back to this row, so it must be up.
        #expect(state.hasPendingUndo)
    }

    /// A refused delete — a converted-but-unconfirmed fold result on a
    /// non-authoritative account — must not queue anything and must not raise
    /// the toast. A queued deletion for a row still on screen is a deletion
    /// the server will perform against a shift the user still has.
    @Test("a refused delete queues nothing and raises no toast")
    func refusedDeleteDoesNothing() throws {
        let userID = registeredAccount(authoritative: false)
        let context = try context()
        let record = ShiftRecord(
            workDate: Self.day, cashTipsCents: 4_200,
            source: .migration, legacyEntryIDs: [UUID()]
        )
        context.insert(record)
        try context.save()

        let state = UndoDeleteToastState()
        state.delete(record, in: context)

        #expect(try rowCount(in: context) == 1)
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID).isEmpty)
        #expect(!state.hasPendingUndo)
    }

    // MARK: - Undo

    @Test("undo restores the row and clears the queue")
    func undoRestoresRowsAndClearsQueue() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = closeout(in: context)

        let state = UndoDeleteToastState()
        state.delete(record, in: context)
        #expect(!PaydaySyncState.pendingShiftDeletions(for: userID).isEmpty)

        state.undo(in: context)

        #expect(try rowCount(in: context) == 1)
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID).isEmpty)
        // Dismissed, because there is nothing left to undo.
        #expect(!state.hasPendingUndo)
    }

    /// `DeletedShift` copies roughly fifteen fields by hand, and a dropped
    /// one is a SILENT money change: lose `tipOutCents` and undo hands back
    /// $11 the user never kept; lose `hoursWorked` and the shift vanishes from
    /// every hourly-rate and overtime figure while still showing its tips.
    ///
    /// Every field is set to a non-default value on purpose. A field left at
    /// its default would compare equal even if the capture dropped it, which
    /// is the same reason `ShiftCheckpointTests.fullyPopulated` exists.
    @Test("undo restores every stored field, not just the amounts")
    func undoRestoresEveryStoredField() throws {
        _ = registeredAccount()
        let context = try context()

        var metrics = ShiftReceiptMetrics()
        metrics.gratuityFeesCents = 2_500
        metrics.netSalesCents = 88_000
        metrics.guestCount = 41

        let original = ShiftRecord(
            workDate: Self.day,
            shiftPeriod: .dinner,
            cashTipsCents: 1_200,
            creditTipsCents: 7_350,
            tipOutCents: 1_100,
            salesCents: 88_000,
            hoursWorked: 6.5,
            clockIn: Self.day.addingTimeInterval(43_200),
            clockOut: Self.day.addingTimeInterval(66_600),
            serverCount: 3,
            receiptMetrics: metrics,
            note: "double covered section 4",
            recordedAt: Self.day.addingTimeInterval(3_600)
        )
        context.insert(original)
        try context.save()

        let state = UndoDeleteToastState()
        state.delete(original, in: context)
        #expect(try rowCount(in: context) == 0)
        state.undo(in: context)

        let restored = try #require(try context.fetch(FetchDescriptor<ShiftRecord>()).first)
        #expect(restored.id == original.id)
        #expect(restored.workDate == Self.day)
        #expect(restored.cashTipsCents == 1_200)
        #expect(restored.creditTipsCents == 7_350)
        #expect(restored.note == "double covered section 4")
        #expect(restored.recordedAt == Self.day.addingTimeInterval(3_600))
        #expect(restored.hoursWorked == 6.5)
        #expect(restored.tipOutCents == 1_100)
        #expect(restored.salesCents == 88_000)
        #expect(restored.shiftPeriod == .dinner)
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
        PaydaySyncState.recordShiftDeletion(UUID())
        let before = PaydaySyncState.pendingShiftDeletions(for: userID)

        let state = UndoDeleteToastState()
        state.undo(in: context)

        #expect(try rowCount(in: context) == 0)
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID).keys.sorted() == before.keys.sorted())
    }
}
