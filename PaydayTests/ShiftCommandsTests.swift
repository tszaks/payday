import Foundation
import SwiftData
import Testing
@testable import Payday

/// PR 2 slice S9: the one place a shift is created, edited, deleted or undone.
///
/// Three claims are asserted here, and each of them is a bug the shipped build
/// actually has: a shift saves atomically, a shift with hours but no tips
/// saves at all, and an unconfirmed conversion result is not editable.
@Suite("Shift commands", .serialized)
@MainActor
struct ShiftCommandsTests {
    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        // The invariant `perform` depends on. With autosave on, a run-loop
        // save between the mutation and a throw persists a partial change
        // that rollback() cannot undo, and the atomicity claim is false.
        context.autosaveEnabled = false
        return context
    }

    private func shiftCount(in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<ShiftRecord>()).count
    }

    private static let day = Date(timeIntervalSince1970: 1_756_000_000)

    // MARK: - A shift with hours but no tips

    /// The shipped writer appended a row only for a NON-ZERO tip amount, so a
    /// wage-only shift wrote zero rows: the hours were lost outright, and with
    /// them that shift's contribution to every hourly-rate and overtime
    /// figure.
    @Test("a shift with hours and no tips saves")
    func wageOnlyShiftSaves() throws {
        let context = try context()

        let record = try ShiftCommands.create(
            in: context, workDate: Self.day, hoursWorked: 5
        )

        #expect(record.hoursWorked == 5)
        #expect(record.cashTipsCents == 0)
        #expect(record.creditTipsCents == 0)
        #expect(try shiftCount(in: context) == 1)
    }

    @Test("a shift with gratuity and no voluntary tips saves")
    func gratuityOnlyShiftSaves() throws {
        let context = try context()

        let record = try ShiftCommands.create(
            in: context,
            workDate: Self.day,
            receiptMetrics: ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: 4_200)
        )

        #expect(record.receiptMetrics?.gratuityFeesCents == 4_200)
        #expect(try shiftCount(in: context) == 1)
    }

    @Test("a shift with nothing in it is refused, with the copy")
    func emptyShiftIsRefused() throws {
        let context = try context()

        #expect(throws: ShiftCommands.Failure.nothingToSave) {
            try ShiftCommands.create(in: context, workDate: Self.day)
        }
        #expect(try shiftCount(in: context) == 0)
        #expect(ShiftCommands.Failure.nothingToSave.message
            == "Add tips, hours, or gratuity to save this shift.")
    }

    @Test("zero hours is not something to save")
    func zeroHoursIsNotEnough() {
        #expect(!ShiftCommands.hasSomethingToSave(
            cashTipsCents: 0, creditTipsCents: 0, hoursWorked: 0, receiptMetrics: nil))
        #expect(ShiftCommands.hasSomethingToSave(
            cashTipsCents: 0, creditTipsCents: 0, hoursWorked: 0.25, receiptMetrics: nil))
    }

    // MARK: - Atomicity

    /// The observable invariant, not the mechanism: after a forced throw there
    /// is no half-written record.
    @Test("an edit that throws leaves the record exactly as it was")
    func editThatThrowsChangesNothing() throws {
        let context = try context()
        let record = try ShiftCommands.create(
            in: context, workDate: Self.day, cashTipsCents: 5_000)
        let before = record.cashTipsCents

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try ShiftCommands.update(record, in: context) { editing in
                editing.cashTipsCents = 9_999
                editing.note = "half written"
                throw Boom()
            }
        }

        // Rolled back, so neither field landed.
        let stored = try #require(try context.fetch(FetchDescriptor<ShiftRecord>()).first)
        #expect(stored.cashTipsCents == before)
        #expect(stored.note == nil)
    }

    @Test("an edit that succeeds persists and advances modifiedAt")
    func editPersists() throws {
        let context = try context()
        let record = try ShiftCommands.create(
            in: context, workDate: Self.day, cashTipsCents: 5_000)
        let originalModified = record.modifiedAt

        try ShiftCommands.update(record, in: context) { $0.cashTipsCents = 6_000 }

        #expect(record.cashTipsCents == 6_000)
        // `didSet` never fires on a SwiftData model, so nothing advances this
        // on its own. That is exactly why edits silently stopped syncing in
        // the shipped build: an edited row never entered the upload set.
        #expect(record.modifiedAt > originalModified)
    }

    // MARK: - Delete and undo

    @Test("delete removes the record and captures everything undo needs")
    func deleteCaptures() throws {
        let context = try context()
        let record = try ShiftCommands.create(
            in: context,
            workDate: Self.day,
            shiftPeriod: .dinner,
            cashTipsCents: 5_000,
            creditTipsCents: 2_000,
            tipOutCents: 1_000,
            hoursWorked: 6.5,
            note: "busy"
        )
        let id = record.id

        let deleted = try ShiftCommands.delete(record, in: context)

        #expect(try shiftCount(in: context) == 0)
        #expect(deleted.id == id)
        #expect(deleted.cashTipsCents == 5_000)
        #expect(deleted.creditTipsCents == 2_000)
        #expect(deleted.tipOutCents == 1_000)
        #expect(deleted.hoursWorked == 6.5)
        #expect(deleted.note == "busy")
        #expect(deleted.shiftPeriod == .dinner)
    }

    /// Undo has to be an EXACT inverse, id included. Restoring under a fresh
    /// id would put a second shift on the server and the user would be paid
    /// twice for one night in every total.
    @Test("undo restores the same shift, not a copy of it")
    func undoIsAnExactInverse() throws {
        let context = try context()
        let record = try ShiftCommands.create(
            in: context,
            workDate: Self.day,
            cashTipsCents: 5_000,
            tipOutCents: 1_000,
            hoursWorked: 6.5,
            note: "busy"
        )
        let id = record.id

        let deleted = try ShiftCommands.delete(record, in: context)
        let restored = try ShiftCommands.restore(deleted, in: context)

        #expect(restored.id == id, "the same shift, or the server gets two")
        #expect(try shiftCount(in: context) == 1)
        #expect(restored.cashTipsCents == 5_000)
        #expect(restored.tipOutCents == 1_000)
        #expect(restored.hoursWorked == 6.5)
        #expect(restored.note == "busy")
    }

    /// Provenance survives the round trip, or a restored conversion artifact
    /// becomes invisible to the rollback query that looks for it.
    @Test("undo preserves a converted shift's provenance")
    func undoPreservesProvenance() throws {
        let context = try context()
        let legacyIDs: Set<UUID> = [UUID(), UUID()]
        let record = ShiftRecord(
            workDate: Self.day,
            cashTipsCents: 5_000,
            source: .migration,
            legacyEntryIDs: legacyIDs
        )
        context.insert(record)
        try context.save()

        // Authoritative, so the gate allows the delete.
        let userID = UUID()
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        _ = PaydaySyncState.registerCurrentUser(userID)
        PaydaySyncState.mutate(userID: userID) {
            $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
        }

        let deleted = try ShiftCommands.delete(record, in: context)
        let restored = try ShiftCommands.restore(deleted, in: context)

        #expect(restored.source == .migration)
        #expect(restored.legacyEntryIDs == legacyIDs)

        PaydaySyncState.forget(userID: userID)
    }

    // MARK: - The write gate

    /// A shift the device just authored has one id from birth and is read back
    /// on the additive legacy leg, so there is nothing to protect. Refusing
    /// every mutation while a conversion is outstanding was the first design's
    /// answer and it was too broad.
    @Test("a natively authored shift is editable even before conversion")
    func nativeShiftIsAlwaysEditable() throws {
        let context = try context()
        let userID = UUID()
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        _ = PaydaySyncState.registerCurrentUser(userID)
        // Deliberately NOT authoritative.
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: userID))

        let record = try ShiftCommands.create(
            in: context, workDate: Self.day, cashTipsCents: 5_000)
        #expect(ShiftCommands.mayMutate(record))
        try ShiftCommands.update(record, in: context) { $0.cashTipsCents = 6_000 }
        #expect(record.cashTipsCents == 6_000)

        PaydaySyncState.forget(userID: userID)
    }

    /// The case that IS refused: a fold result the device has not confirmed.
    /// Editing it before the pull could clobber a refold.
    @Test("editing an unconfirmed folded shift is refused")
    func unconfirmedFoldedShiftIsRefused() throws {
        let context = try context()
        let userID = UUID()
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        _ = PaydaySyncState.registerCurrentUser(userID)

        let record = ShiftRecord(
            workDate: Self.day,
            cashTipsCents: 5_000,
            source: .migration,
            legacyEntryIDs: [UUID()]
        )
        context.insert(record)
        try context.save()

        #expect(!ShiftCommands.mayMutate(record))
        #expect(throws: ShiftCommands.Failure.conversionPending) {
            try ShiftCommands.update(record, in: context) { $0.cashTipsCents = 1 }
        }
        #expect(throws: ShiftCommands.Failure.conversionPending) {
            try ShiftCommands.delete(record, in: context)
        }
        // Refused, not corrupted.
        #expect(record.cashTipsCents == 5_000)
        #expect(try shiftCount(in: context) == 1)

        // And the moment the conversion is confirmed, it becomes editable.
        PaydaySyncState.mutate(userID: userID) {
            $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
        }
        #expect(ShiftCommands.mayMutate(record))

        PaydaySyncState.forget(userID: userID)
    }

    /// Signed out there is no conversion in flight to race, so the gate must
    /// not make the app read-only.
    @Test("a signed-out device is never read-only")
    func signedOutIsNotReadOnly() throws {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let record = ShiftRecord(
            workDate: Self.day, cashTipsCents: 5_000,
            source: .migration, legacyEntryIDs: [UUID()]
        )
        #expect(ShiftCommands.mayMutate(record))
    }

    // MARK: - Copy

    /// Fixed at the type so two screens cannot word the same refusal
    /// differently.
    @Test("the three failure strings are the agreed copy")
    func failureCopy() {
        #expect(ShiftCommands.Failure.shiftGone.message == "That shift is no longer here.")
        #expect(ShiftCommands.Failure.nothingToSave.message
            == "Add tips, hours, or gratuity to save this shift.")
        #expect(ShiftCommands.Failure.saveFailed.message
            == "Payday couldn't save that. Nothing was changed.")
    }

    @Test("a future date is clamped to today")
    func futureDateIsClamped() throws {
        let context = try context()
        let record = try ShiftCommands.create(
            in: context,
            workDate: Date.now.addingTimeInterval(86_400 * 7),
            cashTipsCents: 100
        )
        #expect(record.workDate <= Calendar.current.startOfDay(for: .now))
    }
}
