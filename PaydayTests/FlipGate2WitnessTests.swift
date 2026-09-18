import Foundation
import SwiftData
import Testing
@testable import Payday

/// Flip gate 2: a WITNESS per command, written against `ShiftCommands`
/// directly so the gate exists before the writer is wired to it.
///
/// The danger this closes is precise, and it is why the gate is a witness
/// rather than an outcome check. Every read-side test can pass while the
/// writer still silently runs the legacy `LogTipSheet.saveNew` path, because a
/// correct read of a correctly-written LEGACY row is indistinguishable from a
/// correct read of a new one. "The shift is there and the total is right" is
/// satisfied either way. So each command has to be seen to have taken the new
/// path:
///
///   * `create` writes a `ShiftRecord` and NO `tip_entries` row
///   * `update` mutates the record IN PLACE, same id, no second row
///   * `delete` removes the record and enqueues its deletion
///   * `restore` returns it and resurrects no `TipEntry` (asserted in
///     `ToastShiftPathTests`, since the toast is what exercises it)
///
/// `ShiftCommands.create`/`update`/`delete`/`restore` have zero production
/// callers today, so this is also the reachability hazard being measured
/// rather than documented: the same coverage-versus-reachability distinction
/// that hid the `shiftsAreAuthoritative` wiring for three slices.
@Suite("Flip gate 2: command witnesses", .serialized)
@MainActor
struct FlipGate2WitnessTests {

    private func authoritativeAccount() -> UUID {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let id = UUID()
        PaydaySyncState.forget(userID: id)
        _ = PaydaySyncState.registerCurrentUser(id)
        PaydaySyncState.mutate(userID: id) {
            $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
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

    private func records(_ context: ModelContext) throws -> [ShiftRecord] {
        try context.fetch(FetchDescriptor<ShiftRecord>())
    }

    private func entries(_ context: ModelContext) throws -> [TipEntry] {
        try context.fetch(FetchDescriptor<TipEntry>())
    }

    /// Witness 1. The `and no tip_entries row` half is the whole point: a
    /// create that also wrote a legacy row would satisfy every read-side
    /// assertion while putting the account into the two-representation state
    /// the flip exists to end.
    @Test("create writes a ShiftRecord and no TipEntry")
    func createWritesARecordAndNoEntry() throws {
        _ = authoritativeAccount()
        let context = try context()

        let record = try ShiftCommands.create(
            in: context,
            workDate: Self.day,
            shiftPeriod: .dinner,
            cashTipsCents: 4_200,
            creditTipsCents: 7_350,
            tipOutCents: 1_100,
            hoursWorked: 6.5
        )

        #expect(try records(context).count == 1)
        #expect(try records(context).first?.id == record.id)
        // The witness.
        #expect(try entries(context).isEmpty,
                "a create that also wrote a legacy row would pass every read-side test")
        // And the money is what was asked for, so this is not an empty record.
        #expect(record.cashTipsCents == 4_200)
        #expect(record.creditTipsCents == 7_350)
        #expect(record.tipOutCents == 1_100)
        #expect(record.hoursWorked == 6.5)
    }

    /// Witness 2. In place, same id, no second row -- because an "update" that
    /// inserted a new record and left the old one would double the day's money
    /// while each row looked individually correct.
    @Test("update mutates the record in place, same id, no second row")
    func updateMutatesInPlace() throws {
        _ = authoritativeAccount()
        let context = try context()
        let record = try ShiftCommands.create(
            in: context, workDate: Self.day, cashTipsCents: 4_200, hoursWorked: 6.5
        )
        let originalID = record.id

        try ShiftCommands.update(record, in: context) { edited in
            edited.cashTipsCents = 5_000
            edited.creditTipsCents = 2_500
        }

        let all = try records(context)
        #expect(all.count == 1, "an update that inserted would double the day")
        let updated = try #require(all.first)
        #expect(updated.id == originalID, "the id must survive, or the row is a different shift")
        #expect(updated.cashTipsCents == 5_000)
        #expect(updated.creditTipsCents == 2_500)
        // Untouched fields keep their values: the closure shape exists so a
        // caller cannot erase what it forgot to pass.
        #expect(updated.hoursWorked == 6.5)
        #expect(try entries(context).isEmpty)
    }

    /// Witness 3. Removed AND enqueued, because either half alone is a
    /// divergence: removed without enqueueing leaves the server holding a
    /// shift the device deleted, and enqueued without removing is the
    /// queue-ordering bug #51 fixed in four places.
    @Test("delete removes the record and enqueues its deletion")
    func deleteRemovesAndEnqueues() throws {
        let userID = authoritativeAccount()
        let context = try context()
        let record = try ShiftCommands.create(
            in: context, workDate: Self.day, cashTipsCents: 4_200, hoursWorked: 6.5
        )
        let id = record.id

        _ = try ShiftCommands.delete(record, in: context)

        #expect(try records(context).isEmpty)
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID)[id] != nil,
                "removed but not enqueued leaves the server holding it")
        #expect(PaydaySyncState.shiftTombstones(for: userID)[id] != nil)
        #expect(try entries(context).isEmpty)
    }

    /// Gate 6's parity case, which pins `pruneZeroedRows`' removal as intended
    /// rather than forgotten: editing a shift to zero persists exactly one
    /// zeroed record, neither deleted nor duplicated.
    ///
    /// The old sweep only ever acted when one shift had multiple `TipEntry`
    /// rows (`guard rows.count > 1`), and its every-row-is-zero branch KEPT
    /// the anchor rather than deleting the shift. So this is the same outcome,
    /// reached without a sweep.
    @Test("editing a shift to zero persists exactly one zeroed record")
    func editingToZeroKeepsOneZeroedRecord() throws {
        _ = authoritativeAccount()
        let context = try context()
        let record = try ShiftCommands.create(
            in: context, workDate: Self.day,
            cashTipsCents: 4_200, creditTipsCents: 7_350, hoursWorked: 6.5
        )
        let id = record.id

        try ShiftCommands.update(record, in: context) { edited in
            edited.cashTipsCents = 0
            edited.creditTipsCents = 0
        }

        let all = try records(context)
        #expect(all.count == 1, "not deleted, and not duplicated")
        let zeroed = try #require(all.first)
        #expect(zeroed.id == id)
        #expect(zeroed.cashTipsCents == 0)
        #expect(zeroed.creditTipsCents == 0)
        // The hours survive, which is the thing a sweep would have been most
        // likely to take with it: a wage-only shift is a real shift.
        #expect(zeroed.hoursWorked == 6.5)
    }
}
