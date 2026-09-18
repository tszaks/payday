import Foundation
import SwiftData
import Testing
@testable import Payday

/// The same money-ordering bug as `DeletionQueueAtomicityTests`, in the SHIFT
/// path, where the stakes are higher.
///
/// `ShiftCommands.delete` wrote its queues INSIDE `perform`, under this
/// comment: "all three inside the same command, so a crash between them
/// cannot leave the server holding a live shift the device thinks it deleted,
/// or vice versa." Co-locating them does not achieve that. The queues are App
/// Group `UserDefaults` and take effect immediately; the row is SwiftData;
/// `rollback()` reaches only the latter.
///
/// Worse than the tip path for two reasons. `recordShiftDeletion` also writes
/// a durable tombstone which the source says is "cleared only by a restore,
/// never pruned by time and never by a sync" -- so a failed save left a
/// PERMANENT record that a still-present shift had been deleted. And
/// `recordLegacyEntryDeletions` tombstones the legacy sources, which is what
/// makes a deletion visible to a shipped 1.0 build, so the same failure would
/// hide the night on the old build too.
///
/// `restore` was the same shape with FIVE queue writes, in the other
/// direction: a failed insert left the shift absent from the device while
/// every durable record of its deletion had been erased.
@Suite("Shift queue ordering", .serialized)
@MainActor
struct ShiftQueueOrderingTests {

    /// Authoritative by default, because `ShiftCommands.mayMutate` refuses to
    /// touch a record with non-empty `legacyEntryIDs` while shifts are not yet
    /// authoritative -- it would be editing an unconfirmed fold result. The
    /// first draft of this suite omitted that and got `.conversionPending`
    /// instead of its own error, which is the write gate working.
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

    private func shift(in context: ModelContext, legacy: Set<UUID> = []) throws -> ShiftRecord {
        let record = ShiftRecord(
            workDate: Self.day, cashTipsCents: 4_200, creditTipsCents: 7_350,
            hoursWorked: 6.5, recordedAt: Self.day, legacyEntryIDs: legacy
        )
        context.insert(record)
        try context.save()
        return record
    }

    struct Boom: Error {}

    /// A save that runs the mutation, then fails, exactly as a real throwing
    /// `save()` does.
    private func failingSave(_ context: ModelContext) throws {
        context.rollback()
        throw Boom()
    }

    // MARK: - delete

    @Test("a failed delete leaves the shift, and queues nothing")
    func failedDeleteQueuesNothing() throws {
        let userID = registeredAccount()
        let context = try context()
        let legacyID = UUID()
        let record = try shift(in: context, legacy: [legacyID])
        let shiftID = record.id

        #expect(throws: Boom.self) {
            _ = try ShiftCommands.delete(record, in: context, saving: failingSave)
        }

        // The shift is still the user's.
        #expect(try context.fetch(FetchDescriptor<ShiftRecord>()).count == 1)
        // And nothing was queued for the server. Each of these, written while
        // the row survived, was a separate way for the account to diverge.
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID).isEmpty)
        #expect(PaydaySyncState.shiftTombstones(for: userID)[shiftID] == nil)
        #expect(PaydaySyncState.pendingLegacyEntryDeletions(for: userID)[legacyID] == nil)
    }

    @Test("a successful delete removes the shift and queues it, tombstone and legacy sources")
    func successfulDeleteQueuesEverything() throws {
        let userID = registeredAccount()
        let context = try context()
        let legacyID = UUID()
        let record = try shift(in: context, legacy: [legacyID])
        let shiftID = record.id

        _ = try ShiftCommands.delete(record, in: context)

        #expect(try context.fetch(FetchDescriptor<ShiftRecord>()).isEmpty)
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID)[shiftID] != nil)
        #expect(PaydaySyncState.shiftTombstones(for: userID)[shiftID] != nil)
        // The legacy sources too, or the deletion is invisible to a 1.0 build.
        #expect(PaydaySyncState.pendingLegacyEntryDeletions(for: userID)[legacyID] != nil)
    }

    // MARK: - restore

    @Test("a failed restore keeps the deletion queued and the tombstone standing")
    func failedRestoreKeepsTheDeletionDurable() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = try shift(in: context)
        let shiftID = record.id
        let deleted = try ShiftCommands.delete(record, in: context)
        #expect(PaydaySyncState.shiftTombstones(for: userID)[shiftID] != nil)

        #expect(throws: Boom.self) {
            _ = try ShiftCommands.restore(deleted, in: context, saving: failingSave)
        }

        // Nothing came back, so the durable record of the deletion must still
        // stand. Erasing it here is what left a shift absent from the device
        // with no explanation of why.
        #expect(try context.fetch(FetchDescriptor<ShiftRecord>()).isEmpty)
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID)[shiftID] != nil)
        #expect(PaydaySyncState.shiftTombstones(for: userID)[shiftID] != nil)
    }

    @Test("a successful restore brings the shift back and clears the deletion")
    func successfulRestoreClearsTheQueue() throws {
        let userID = registeredAccount()
        let context = try context()
        let record = try shift(in: context)
        let shiftID = record.id
        let deleted = try ShiftCommands.delete(record, in: context)

        _ = try ShiftCommands.restore(deleted, in: context)

        #expect(try context.fetch(FetchDescriptor<ShiftRecord>()).count == 1)
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID)[shiftID] == nil)
        #expect(PaydaySyncState.shiftTombstones(for: userID)[shiftID] == nil)
    }
}
