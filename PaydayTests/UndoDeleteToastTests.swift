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
    ///
    /// The field list is checked against the stored attributes SwiftData
    /// itself reports for `ShiftRecord`, so an attribute added to the model
    /// without a line here fails this test instead of being skipped by it.
    @Test("undo restores every stored field, not just the amounts")
    func undoRestoresEveryStoredField() throws {
        _ = registeredAccount()
        let context = try context()

        let id = UUID()
        let sources: Set<UUID> = [UUID(), UUID()]
        func populated() -> ShiftRecord {
            var metrics = ShiftReceiptMetrics()
            metrics.gratuityFeesCents = 2_500
            metrics.netSalesCents = 88_000
            metrics.guestCount = 41
            return ShiftRecord(
                id: id,
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
                tipShareInCents: 1_800,
                roleName: "Bar",
                jobName: "Uptown",
                receiptMetrics: metrics,
                note: "double covered section 4",
                recordedAt: Self.day.addingTimeInterval(3_600),
                source: .migration,
                legacyEntryIDs: sources
            )
        }
        // A deleted model cannot be read back, so the expected values live on
        // an identical record that never enters the store.
        let expected = populated()
        let original = populated()
        context.insert(original)
        try context.save()

        let state = UndoDeleteToastState()
        state.delete(original, in: context)
        #expect(try rowCount(in: context) == 0)
        state.undo(in: context)

        let restored = try #require(try context.fetch(FetchDescriptor<ShiftRecord>()).first)

        // One line per stored attribute, by its SwiftData name.
        let survives: [(String, (ShiftRecord, ShiftRecord) -> Bool)] = [
            ("id", { $0.id == $1.id }),
            ("workDate", { $0.workDate == $1.workDate }),
            ("shiftPeriodRaw", { $0.shiftPeriod == $1.shiftPeriod }),
            ("cashTipsCents", { $0.cashTipsCents == $1.cashTipsCents }),
            ("creditTipsCents", { $0.creditTipsCents == $1.creditTipsCents }),
            ("tipOutCents", { $0.tipOutCents == $1.tipOutCents }),
            ("salesCents", { $0.salesCents == $1.salesCents }),
            ("hoursWorked", { $0.hoursWorked == $1.hoursWorked }),
            ("clockIn", { $0.clockIn == $1.clockIn }),
            ("clockOut", { $0.clockOut == $1.clockOut }),
            ("serverCount", { $0.serverCount == $1.serverCount }),
            ("tipShareInCents", { $0.tipShareInCents == $1.tipShareInCents }),
            ("roleName", { $0.roleName == $1.roleName }),
            ("jobName", { $0.jobName == $1.jobName }),
            // The money-bearing half of the receipt. Dropping this loses
            // gratuity that the drawer, the period total and the paycheck read.
            ("receiptMetricsJSON", { $0.receiptMetrics == $1.receiptMetrics }),
            ("note", { $0.note == $1.note }),
            ("recordedAt", { $0.recordedAt == $1.recordedAt }),
            ("sourceRaw", { $0.source == $1.source }),
            ("legacyEntryIDsRaw", { $0.legacyEntryIDs == $1.legacyEntryIDs })
        ]
        // The mutation clock is the one attribute a restore must NOT copy: a
        // restore is a new write, and `ShiftRecord.modifiedAt` orders writes.
        let notCopied: Set<String> = ["modifiedAt"]

        let attributes = try #require(Schema([ShiftRecord.self]).entitiesByName["ShiftRecord"]).attributes
        #expect(Set(survives.map(\.0)).union(notCopied) == Set(attributes.map(\.name)))

        let defaults = ShiftRecord()
        for (name, same) in survives {
            #expect(!same(expected, defaults), "\(name) is at its default, so a dropped copy would go unseen")
            #expect(same(restored, expected), "undo did not restore \(name)")
        }
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
