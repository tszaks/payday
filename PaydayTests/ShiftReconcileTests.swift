import Foundation
import SwiftData
import Testing
@testable import Payday

/// PR 2 slice S8: reconciling pulled shifts, and the two guards that make
/// pull-before-push safe on this leg.
///
/// The shift leg pulls before it pushes, which the tip leg does not. That
/// inversion is what lets a device adopt a server-side fold before overwriting
/// it, and it is only safe because of `locallyChangedBeforeSync` and the
/// two-call split. Both are asserted here against real SwiftData.
@Suite("Shift reconcile", .serialized)
@MainActor
struct ShiftReconcileTests {
    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private static let id = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
    private static let userID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let workDay = Date(timeIntervalSince1970: 1_756_000_000)

    private static func remote(
        cash: Int,
        credit: Int = 0,
        clientUpdatedAt: String = "2026-09-01T23:00:00.000Z",
        deletedAt: String? = nil,
        source: String? = nil,
        legacyEntryIDs: [UUID]? = nil
    ) -> RemoteShift {
        RemoteShift(
            id: id, userID: userID,
            workDate: PaydayRemoteDate.day(workDay),
            shiftPeriod: nil,
            cashTipsCents: cash, creditTipsCents: credit,
            tipOutCents: nil, salesCents: nil, hoursWorked: nil,
            clockIn: nil, clockOut: nil, serverCount: nil,
            receiptMetrics: nil, note: nil, recordedAt: nil,
            clientUpdatedAt: clientUpdatedAt,
            source: source, legacyEntryIDs: legacyEntryIDs,
            nativeModifiedAt: nil, deletedAt: deletedAt, deletedReason: nil,
            gratuityFeesCents: nil, nonWageEarningsCents: nil,
            version: nil, serverUpdatedAt: nil
        )
    }

    // MARK: - The guard that makes pull-before-push safe

    /// The failure this leg's ordering would otherwise cause. A shift the user
    /// edited an hour ago and has not pushed yet must survive a pull, even
    /// when the server holds a different number for it -- a refold, say.
    ///
    /// Without this guard the pull silently overwrites the user's edit with
    /// the server's value and the edit is gone, because the push that would
    /// have sent it happens afterwards and by then the local row matches the
    /// server.
    @Test("a pulled refold does not clobber an unpushed local edit")
    func aPulledRefoldDoesNotClobberAnUnpushedLocalEdit() throws {
        let context = try context()
        let local = ShiftRecord(id: Self.id, workDate: Self.workDay, cashTipsCents: 7_777)
        context.insert(local)
        try context.save()

        // The server holds a refold with a different number.
        _ = try PaydaySyncService.reconcileShifts(
            [Self.remote(cash: 4_200, source: "migration", legacyEntryIDs: [UUID()])],
            in: context,
            locallyChangedBeforeSync: [Self.id]
        )

        #expect(local.cashTipsCents == 7_777, "the unpushed edit must win over the pull")
    }

    /// The other half of the same rule, and the reason the caller makes TWO
    /// calls rather than passing one merged set.
    ///
    /// The readback after the push IS the server's canonical result: a
    /// `client_updated_at` the server clamped to its own clock, a sanitised
    /// receipt payload, or a refold. It must be adopted. Excluding the
    /// just-changed ids from the readback as well would mean the device never
    /// adopts that result while still acknowledging its own local value, so
    /// the row reads clean forever and the divergence is permanent and
    /// unpushable.
    @Test("a server-clamped timestamp on a just-pushed shift is adopted")
    func aServerClampedClientUpdatedAtOnAJustPushedShiftIsAdopted() throws {
        let context = try context()
        let local = ShiftRecord(id: Self.id, workDate: Self.workDay, cashTipsCents: 7_777)
        context.insert(local)
        try context.save()

        // The readback call passes NO exclusion, which is the whole point.
        _ = try PaydaySyncService.reconcileShifts(
            [Self.remote(cash: 7_777, clientUpdatedAt: "2026-09-02T00:00:00.000Z")],
            in: context,
            locallyChangedBeforeSync: []
        )

        #expect(local.modifiedAt
            == PaydayRemoteDate.parseInstant("2026-09-02T00:00:00.000Z"))
    }

    // MARK: - Undo

    /// A shift the user undid is queued for `restore_shifts` and not confirmed
    /// yet, so the server still holds it tombstoned. Applying that tombstone
    /// would delete the row the user just restored, which is the undo silently
    /// failing.
    @Test("a pulled tombstone does not undo an unconfirmed restore")
    func aPulledTombstoneDoesNotUndoARestore() throws {
        let context = try context()
        context.insert(ShiftRecord(id: Self.id, workDate: Self.workDay, cashTipsCents: 5_000))
        try context.save()

        _ = try PaydaySyncService.reconcileShifts(
            [Self.remote(cash: 5_000, deletedAt: "2026-09-02T00:00:00.000Z")],
            in: context,
            restoringIDs: [Self.id]
        )

        #expect(try context.fetch(FetchDescriptor<ShiftRecord>()).count == 1,
                "the restore is not confirmed, so the server's tombstone is stale")
    }

    /// And once the restore is no longer pending, the tombstone does apply --
    /// otherwise a deletion made on another device could never arrive.
    @Test("a pulled tombstone deletes when no restore is pending")
    func aPulledTombstoneAppliesNormally() throws {
        let context = try context()
        context.insert(ShiftRecord(id: Self.id, workDate: Self.workDay, cashTipsCents: 5_000))
        try context.save()

        _ = try PaydaySyncService.reconcileShifts(
            [Self.remote(cash: 5_000, deletedAt: "2026-09-02T00:00:00.000Z")],
            in: context
        )

        #expect(try context.fetch(FetchDescriptor<ShiftRecord>()).isEmpty)
    }

    /// Copied verbatim from the tip leg: a row deleted locally during the pass
    /// must not be resurrected by a pull that predates the deletion.
    @Test("a shift deleted during the pass is not resurrected")
    func aShiftDeletedDuringTheSyncIsNotResurrected() throws {
        let context = try context()

        _ = try PaydaySyncService.reconcileShifts(
            [Self.remote(cash: 5_000)],
            in: context,
            locallyDeletedDuringSync: [Self.id]
        )

        #expect(try context.fetch(FetchDescriptor<ShiftRecord>()).isEmpty)
    }

    // MARK: - Provenance and insertion

    @Test("a shift the device has never seen is inserted with its money")
    func aNewShiftIsInserted() throws {
        let context = try context()

        let active = try PaydaySyncService.reconcileShifts(
            [Self.remote(cash: 5_000, credit: 2_000)], in: context)

        #expect(active == [Self.id])
        let stored = try #require(try context.fetch(FetchDescriptor<ShiftRecord>()).first)
        #expect(stored.cashTipsCents == 5_000)
        #expect(stored.creditTipsCents == 2_000)
    }

    /// Provenance is adopted from the server, never invented locally. `source`
    /// plus `legacyEntryIDs` is the rollback query, and a device that guessed
    /// either would make a conversion artifact unfindable by it.
    @Test("provenance is adopted from the server")
    func provenanceIsAdopted() throws {
        let context = try context()
        let legacy = UUID()

        _ = try PaydaySyncService.reconcileShifts(
            [Self.remote(cash: 4_200, source: "migration", legacyEntryIDs: [legacy])],
            in: context)

        let stored = try #require(try context.fetch(FetchDescriptor<ShiftRecord>()).first)
        #expect(stored.source == .migration)
        #expect(stored.legacyEntryIDs == [legacy])
    }

    /// A row the server sends without provenance must not blank what the
    /// device already holds, or one delta pull erases the rollback query's
    /// only input.
    @Test("absent provenance on the wire does not erase what is stored")
    func absentProvenanceDoesNotErase() throws {
        let context = try context()
        let legacy = UUID()
        let local = ShiftRecord(
            id: Self.id, workDate: Self.workDay, cashTipsCents: 4_200,
            source: .migration, legacyEntryIDs: [legacy])
        context.insert(local)
        try context.save()

        _ = try PaydaySyncService.reconcileShifts(
            [Self.remote(cash: 4_200)], in: context)

        #expect(local.source == .migration)
        #expect(local.legacyEntryIDs == [legacy])
    }

    @Test("an unreadable work date is refused rather than stored wrong")
    func unreadableWorkDateThrows() throws {
        let context = try context()
        var row = Self.remote(cash: 100)
        row = RemoteShift(
            id: row.id, userID: row.userID, workDate: "not-a-date",
            shiftPeriod: nil, cashTipsCents: 100, creditTipsCents: 0,
            tipOutCents: nil, salesCents: nil, hoursWorked: nil,
            clockIn: nil, clockOut: nil, serverCount: nil,
            receiptMetrics: nil, note: nil, recordedAt: nil,
            clientUpdatedAt: row.clientUpdatedAt,
            source: nil, legacyEntryIDs: nil, nativeModifiedAt: nil,
            deletedAt: nil, deletedReason: nil, gratuityFeesCents: nil,
            nonWageEarningsCents: nil, version: nil, serverUpdatedAt: nil)

        #expect(throws: PaydayMigrationError.invalidRemoteData) {
            _ = try PaydaySyncService.reconcileShifts([row], in: context)
        }
    }

    // MARK: - The fingerprint the upload set is built from

    /// The fingerprint must cover every field the device can write and nothing
    /// it cannot. Too narrow and an edit never syncs, which is the `didSet`
    /// failure again; too wide and a server-side refold makes the whole
    /// history look locally edited.
    @Test("editing any writable field changes the fingerprint")
    func everyWritableFieldMovesTheFingerprint() throws {
        let base = ShiftRecord(id: Self.id, workDate: Self.workDay, cashTipsCents: 100)
        let original = try PaydayRowFingerprint.value(base)

        let edits: [(String, (ShiftRecord) -> Void)] = [
            ("cash", { $0.cashTipsCents = 200 }),
            ("credit", { $0.creditTipsCents = 50 }),
            ("tipOut", { $0.tipOutCents = 10 }),
            ("sales", { $0.salesCents = 42_000 }),
            ("hours", { $0.hoursWorked = 6.5 }),
            ("period", { $0.shiftPeriod = .dinner }),
            ("serverCount", { $0.serverCount = 4 }),
            ("note", { $0.note = "busy" }),
            ("clockIn", { $0.clockIn = Self.workDay }),
            ("clockOut", { $0.clockOut = Self.workDay.addingTimeInterval(3_600) }),
            ("recordedAt", { $0.recordedAt = Self.workDay })
        ]

        for (name, edit) in edits {
            let record = ShiftRecord(id: Self.id, workDate: Self.workDay, cashTipsCents: 100)
            edit(record)
            let edited = try PaydayRowFingerprint.value(record)
            #expect(edited != original,
                    "editing \(name) must change the fingerprint or it never syncs")
        }
    }

    /// The other direction: a server-authored column must NOT move it, or a
    /// conversion on the server re-uploads the entire history.
    @Test("server-authored provenance does not move the fingerprint")
    func provenanceDoesNotMoveTheFingerprint() throws {
        let plain = ShiftRecord(id: Self.id, workDate: Self.workDay, cashTipsCents: 100)
        let converted = ShiftRecord(
            id: Self.id, workDate: Self.workDay, cashTipsCents: 100,
            source: .migration, legacyEntryIDs: [UUID(), UUID()])

        let plainPrint = try PaydayRowFingerprint.value(plain)
        let convertedPrint = try PaydayRowFingerprint.value(converted)
        #expect(plainPrint == convertedPrint)
    }
}
