import Foundation
import SwiftData
import Testing
@testable import Payday

/// The flip's first piece, and gate 2's `restore` witness binds here.
///
/// `UndoDeleteToast` gains a `ShiftRecord` path beside its `TipEntry` one
/// rather than replacing it: both are needed at once during the conversion
/// window, because a shipped 1.0 build writes `TipEntry` and an account that
/// has not converted still reads it, while a converted account deletes a
/// `ShiftRecord`.
///
/// Behaviour-neutral on merge: nothing calls the new path yet. That is exactly
/// why it gets its own tests now — `ShiftCommands.restore` is one of the four
/// zero-caller commands, and the reachability hazard is that unreached code
/// ships unexercised. Gate 2 asserts the witness: a restore returns the
/// `ShiftRecord` and resurrects no `TipEntry`.
@Suite("Toast shift path", .serialized)
@MainActor
struct ToastShiftPathTests {

    private func account(authoritative: Bool = true) -> UUID {
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

    private func shift(in context: ModelContext) throws -> ShiftRecord {
        let record = ShiftRecord(
            workDate: Self.day, shiftPeriod: .dinner,
            cashTipsCents: 4_200, creditTipsCents: 7_350,
            tipOutCents: 1_100, hoursWorked: 6.5, recordedAt: Self.day
        )
        context.insert(record)
        try context.save()
        return record
    }

    private func shiftCount(_ context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<ShiftRecord>()).count
    }

    @Test("deleting a shift removes it, queues it, and raises the toast")
    func deleteRemovesQueuesAndShowsToast() throws {
        let userID = account()
        let context = try context()
        let record = try shift(in: context)
        let id = record.id

        let state = UndoDeleteToastState()
        state.delete(record, in: context)

        #expect(try shiftCount(context) == 0)
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID)[id] != nil)
        #expect(PaydaySyncState.shiftTombstones(for: userID)[id] != nil)
        // The one signal the view layer reads, so the toast is actually up.
        #expect(state.hasPendingUndo)
        #expect(state.deletedShift?.id == id)
        // And the legacy path is untouched, so the two do not interfere.
        #expect(state.snapshot == nil)
    }

    /// Gate 2's `restore` witness: the record comes back, and no `TipEntry` is
    /// resurrected in its place.
    @Test("undo restores the ShiftRecord and resurrects no TipEntry")
    func undoRestoresTheRecordAndNoTipEntry() throws {
        let userID = account()
        let context = try context()
        let record = try shift(in: context)
        let id = record.id

        let state = UndoDeleteToastState()
        state.delete(record, in: context)
        #expect(try shiftCount(context) == 0)

        state.undo(in: context)

        #expect(try shiftCount(context) == 1)
        let restored = try #require(try context.fetch(FetchDescriptor<ShiftRecord>()).first)
        #expect(restored.id == id)
        // The witness. A restore that wrote a legacy row instead would satisfy
        // a naive "the shift is back" assertion while putting the account into
        // the very two-representation state the flip exists to end.
        #expect(try context.fetch(FetchDescriptor<TipEntry>()).isEmpty)

        // Queue and tombstone cleared, so the server is not still told to
        // delete a shift the user just recovered.
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID)[id] == nil)
        #expect(PaydaySyncState.shiftTombstones(for: userID)[id] == nil)
        #expect(!state.hasPendingUndo)
    }

    /// The money survives the round trip. An undo that returned a shift with
    /// different cents would be a silent loss dressed as a recovery.
    @Test("undo returns the same money, field by field")
    func undoPreservesTheMoney() throws {
        _ = account()
        let context = try context()
        let record = try shift(in: context)

        let state = UndoDeleteToastState()
        state.delete(record, in: context)
        state.undo(in: context)

        let restored = try #require(try context.fetch(FetchDescriptor<ShiftRecord>()).first)
        #expect(restored.cashTipsCents == 4_200)
        #expect(restored.creditTipsCents == 7_350)
        #expect(restored.tipOutCents == 1_100)
        #expect(restored.hoursWorked == 6.5)
        #expect(restored.shiftPeriod == .dinner)
    }

    /// A refused delete is expected, not exceptional: `mayMutate` declines a
    /// record with unconfirmed `legacyEntryIDs` while shifts are not yet
    /// authoritative. Nothing is deleted, nothing is queued, and no toast
    /// claims a deletion that did not happen.
    @Test("a refused delete leaves the shift and raises no toast")
    func refusedDeleteChangesNothing() throws {
        let userID = account(authoritative: false)
        let context = try context()
        let record = ShiftRecord(
            workDate: Self.day, cashTipsCents: 4_200,
            hoursWorked: 6.5, recordedAt: Self.day,
            legacyEntryIDs: [UUID()]
        )
        context.insert(record)
        try context.save()

        let state = UndoDeleteToastState()
        state.delete(record, in: context)

        #expect(try shiftCount(context) == 1)
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID).isEmpty)
        #expect(!state.hasPendingUndo)
    }
}
