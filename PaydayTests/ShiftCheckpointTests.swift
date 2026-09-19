import Foundation
import Testing
@testable import Payday

/// PR 2 slice S7: the checkpoint fields and queues the shift sync leg needs.
///
/// Almost every assertion here guards a **silent** failure. None of these
/// would throw, crash, or fail another test if the code were wrong; they would
/// each quietly lose a deletion, an undo, or a whole account's sync position.
/// That is the reason the slice is mostly tests.
@Suite("Shift checkpoint and queues", .serialized)
struct ShiftCheckpointTests {

    // MARK: - Fixtures

    /// A fresh account per test, so nothing leaks between them.
    private func newAccount() -> UUID {
        let id = UUID()
        PaydaySyncState.forget(userID: id)
        return id
    }

    /// A fresh account that is also the REGISTERED one, for the two shipped
    /// queue functions that resolve the account from the registration rather
    /// than taking it as an argument. Deliberately not widening those: S10
    /// annotates `recordTipDeletions` as unavailable, so adding a parameter to
    /// it now would be work in the opposite direction.
    private func registeredAccount() -> UUID {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let id = newAccount()
        _ = PaydaySyncState.registerCurrentUser(id)
        return id
    }

    /// A Snapshot with NO field left at its default.
    ///
    /// Deliberately exhaustive: `everySnapshotFieldSurvivesEncodeDecode`
    /// relies on this, because a forgotten decode line only shows up as a
    /// value mismatch if the value being compared differs from the default.
    private static func fullyPopulated() -> PaydaySyncState.Snapshot {
        let a = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000002")!
        let c = UUID(uuidString: "cccccccc-0000-4000-8000-000000000003")!
        return PaydaySyncState.Snapshot(
            tipEntryIDs: [a],
            paycheckIDs: [b],
            migrationVerified: true,
            tipClientUpdatedAt: [a: "2026-09-01T00:00:00.000Z"],
            paycheckClientUpdatedAt: [b: "2026-09-02T00:00:00.000Z"],
            tipContentFingerprint: [a: "0123456789abcdef"],
            paycheckContentFingerprint: [b: "fedcba9876543210"],
            versioningScheme: PaydaySyncState.currentVersioningScheme,
            settingsClientUpdatedAt: "2026-09-03T00:00:00.000Z",
            tipServerCursor: .init(updatedAt: "2026-09-04T00:00:00.000Z", id: a),
            paycheckServerCursor: .init(updatedAt: "2026-09-05T00:00:00.000Z", id: b),
            settingsServerUpdatedAt: "2026-09-06T00:00:00.000Z",
            shiftIDs: [c],
            shiftServerCursor: .init(updatedAt: "2026-09-07T00:00:00.000Z", id: c),
            shiftClientUpdatedAt: [c: "2026-09-08T00:00:00.000Z"],
            shiftContentFingerprint: [c: "abcdef0123456789"],
            shiftServerAckedIDs: [c],
            shiftWriteAttempts: [c: 3],
            pendingShiftRestores: [c: Date(timeIntervalSince1970: 1_700_000_000)],
            shiftsAreAuthoritativeAt: "2026-09-09T00:00:00.000Z"
        )
    }

    // MARK: - The decoder rules

    /// The test the design insists on generating rather than hand-writing.
    ///
    /// `PendingDeletions` gained three keys in this slice. Swift's SYNTHESIZED
    /// decoder ignores property defaults, so with a synthesized decoder every
    /// blob the shipped 1.0 build wrote would throw `keyNotFound` — and
    /// `loadPending` swallows that with `try?` and hands back an empty queue.
    /// The result would be silently discarding every tip and paycheck deletion
    /// 1.0 made and never flushed, which is the only record those deletions
    /// happened.
    ///
    /// The fixture is built by ENCODING a two-field struct, never by hand.
    /// `[UUID: Date]` is not a JSON object — `UUID` does not conform to
    /// `CodingKeyRepresentable`, so Swift writes a flat unkeyed array of
    /// alternating id and number. A hand-written `{"tipEntries":{"<uuid>":…}}`
    /// fixture decodes as `typeMismatch`, `loadPending` swallows it, the count
    /// reads 0, and the test fails against a perfectly correct decoder. The
    /// obvious next move is to "fix" the storage shape, which breaks reading
    /// every real 1.0 blob.
    @Test("a deletion queue written by the shipped 1.0 build still decodes")
    func pendingDeletionsDecodeA10ShapedBlob() throws {
        struct LegacyPendingDeletions: Encodable {
            var tipEntries: [UUID: Date]
            var paychecks: [UUID: Date]
        }
        let userID = newAccount()
        let doomedTip = UUID()
        let data = try JSONEncoder().encode(LegacyPendingDeletions(
            tipEntries: [doomedTip: Date(timeIntervalSince1970: 0)],
            paychecks: [:]
        ))
        AppGroup.defaults.set(data, forKey: PaydaySyncState.deletionKey(for: userID))

        // The whole point: the 1.0 deletion survives the new keys.
        #expect(PaydaySyncState.pendingTipDeletions(for: userID).count == 1)
        #expect(PaydaySyncState.pendingTipDeletions(for: userID)[doomedTip] != nil)
        // And the new queues read as empty rather than as garbage.
        #expect(PaydaySyncState.pendingShiftDeletions(for: userID).isEmpty)
        #expect(PaydaySyncState.pendingLegacyEntryDeletions(for: userID).isEmpty)
        #expect(PaydaySyncState.shiftTombstones(for: userID).isEmpty)

        PaydaySyncState.forget(userID: userID)
    }

    /// Guards the seven new fields against a forgotten decode line, which is a
    /// write-only field that always loads as its default: no throw, nothing
    /// logged, no other test failing. A non-persisting cursor re-baselines the
    /// account every pass; a non-persisting `pendingShiftRestores` leaves a
    /// shift the user undid deleted.
    @Test("every snapshot field survives an encode and decode round trip")
    func everySnapshotFieldSurvivesEncodeDecode() throws {
        let original = Self.fullyPopulated()
        let decoded = try JSONDecoder().decode(
            PaydaySyncState.Snapshot.self,
            from: try JSONEncoder().encode(original)
        )
        // Equatable, so this catches any field, including ones added later
        // by someone who does not read this file.
        #expect(decoded == original)
    }

    /// A tombstone written by a build that did not yet have a field, or with a
    /// date that cannot be read, must not flush on a fabricated timestamp.
    /// `.distantPast` keeps it queued and retrying, which surfaces; `.now`
    /// would push a deletion stamped with an invented time.
    @Test("a tombstone with an unreadable date defaults to the safe direction")
    func tombstoneDefaultsToDistantPast() throws {
        struct Partial: Encodable { var flushedToServer: Bool }
        let decoded = try JSONDecoder().decode(
            ShiftTombstone.self,
            from: try JSONEncoder().encode(Partial(flushedToServer: true))
        )
        #expect(decoded.deletedAt == .distantPast)
        #expect(decoded.flushedToServer)
    }

    // MARK: - mutate, and the erasure it replaces

    /// The reason `save` had to go. It took the shipped nine fields and built
    /// a FRESH Snapshot, so a caller that omitted a field erased it — and both
    /// shipped callers omitted every shift field. This asserts the property
    /// that makes that unexpressible.
    @Test("clearing one flag preserves every other field")
    func clearingOneFlagPreservesEveryOtherField() {
        let userID = newAccount()
        let full = Self.fullyPopulated()
        PaydaySyncState.mutate(userID: userID) { $0 = full }

        PaydaySyncState.mutate(userID: userID) { $0.migrationVerified = false }

        let after = PaydaySyncState.snapshot(for: userID)
        #expect(!after.migrationVerified)
        // Everything else, field by field, because "it round-trips" is not
        // the same claim as "a write of one field left the rest alone".
        #expect(after.tipEntryIDs == full.tipEntryIDs)
        #expect(after.paycheckIDs == full.paycheckIDs)
        #expect(after.tipClientUpdatedAt == full.tipClientUpdatedAt)
        #expect(after.paycheckClientUpdatedAt == full.paycheckClientUpdatedAt)
        #expect(after.tipContentFingerprint == full.tipContentFingerprint)
        #expect(after.paycheckContentFingerprint == full.paycheckContentFingerprint)
        #expect(after.settingsClientUpdatedAt == full.settingsClientUpdatedAt)
        #expect(after.tipServerCursor == full.tipServerCursor)
        #expect(after.paycheckServerCursor == full.paycheckServerCursor)
        #expect(after.settingsServerUpdatedAt == full.settingsServerUpdatedAt)
        #expect(after.shiftIDs == full.shiftIDs)
        #expect(after.shiftServerCursor == full.shiftServerCursor)
        #expect(after.shiftClientUpdatedAt == full.shiftClientUpdatedAt)
        #expect(after.shiftServerAckedIDs == full.shiftServerAckedIDs)
        #expect(after.shiftWriteAttempts == full.shiftWriteAttempts)
        #expect(after.pendingShiftRestores == full.pendingShiftRestores)
        #expect(after.shiftsAreAuthoritativeAt == full.shiftsAreAuthoritativeAt)

        PaydaySyncState.forget(userID: userID)
    }

    /// The exact loss `save` would have caused, written as the scenario rather
    /// than as an API assertion: a user undoes a deletion, a sync pass ends,
    /// and the undo has to still be queued. Under `save` this returned empty
    /// and the shift stayed deleted with nothing to show why.
    @Test("a full sync pass preserves pending shift restores")
    func aFullSyncPassPreservesPendingShiftRestores() {
        let userID = newAccount()
        let undone = UUID()
        PaydaySyncState.recordShiftRestore(undone, at: Date(timeIntervalSince1970: 1), for: userID)
        #expect(PaydaySyncState.pendingShiftRestores(for: userID).count == 1)

        // Exactly the shape the converted call site writes at the end of a
        // pass: the shipped nine fields, naming no shift field at all.
        PaydaySyncState.mutate(userID: userID) { checkpoint in
            checkpoint.tipEntryIDs = [UUID()]
            checkpoint.paycheckIDs = []
            checkpoint.migrationVerified = true
            checkpoint.tipClientUpdatedAt = [:]
            checkpoint.paycheckClientUpdatedAt = [:]
            checkpoint.tipContentFingerprint = [:]
            checkpoint.paycheckContentFingerprint = [:]
            checkpoint.settingsClientUpdatedAt = "2026-09-01T00:00:00.000Z"
            checkpoint.tipServerCursor = .beginning
            checkpoint.paycheckServerCursor = .beginning
            checkpoint.settingsServerUpdatedAt = "2026-09-01T00:00:00.000Z"
        }

        #expect(PaydaySyncState.pendingShiftRestores(for: userID)[undone] != nil)
        PaydaySyncState.forget(userID: userID)
    }

    // MARK: - The legacy deletion queue's own key

    /// Why `legacyEntries` is not stored in `tipEntries`.
    ///
    /// `synchronize` cancels any pending TIP deletion whose local row still
    /// exists, and it does so before the flush. That is safe today only
    /// because the 1.0 delete paths hard-delete the local row in the same
    /// breath. The shift model deliberately keeps the local legacy mirror, so
    /// a shared key means every queued id is still present next pass and the
    /// restore-cancel arm empties the queue **without one
    /// `soft_delete_tip_entries` call ever being issued**: the shift tombstone
    /// reaches the server and the legacy rows stay live forever.
    @Test("a legacy deletion queue entry survives a restore-cancel pass")
    func aLegacyDeletionQueueEntrySurvivesARestoreCancelPass() {
        let userID = registeredAccount()
        let sourceRow = UUID()

        // A shift was deleted, so its legacy sources are queued.
        PaydaySyncState.recordLegacyEntryDeletions([sourceRow], for: userID)
        // The same id is also in the shipped tip queue, as a 1.0 build would
        // have left it.
        PaydaySyncState.recordTipDeletions([sourceRow])

        // The restore-cancel arm: the local row still exists, so the TIP
        // deletion is cancelled.
        PaydaySyncState.clearTipDeletions([sourceRow], for: userID)

        #expect(PaydaySyncState.pendingTipDeletions(for: userID).isEmpty)
        // And the legacy queue is untouched, so the flush still happens.
        #expect(PaydaySyncState.pendingLegacyEntryDeletions(for: userID)[sourceRow] != nil)

        PaydaySyncState.forget(userID: userID)
    }

    /// The flush clears against the RPC's RETURN SET, so an id the server
    /// declined stays queued. `soft_delete_tip_entries` only writes rows where
    /// the requested date is at or after the stored `client_updated_at`, and
    /// that stored value was clamped to the server's clock while the requested
    /// one is the device's — so a device running behind tombstones nothing and
    /// gets no error.
    @Test("only the ids the server actually wrote leave the legacy queue")
    func onlyServerWrittenIDsLeaveTheLegacyQueue() {
        let userID = newAccount()
        let written = UUID()
        let declined = UUID()
        PaydaySyncState.recordLegacyEntryDeletions([written, declined], for: userID)

        PaydaySyncState.clearLegacyEntryDeletions([written], for: userID)

        let remaining = PaydaySyncState.pendingLegacyEntryDeletions(for: userID)
        #expect(remaining[written] == nil)
        #expect(remaining[declined] != nil, "a declined id must stay queued and retry")

        PaydaySyncState.forget(userID: userID)
    }

    // MARK: - Tombstones and undo

    @Test("deleting a shift queues the deletion and writes a durable tombstone")
    func deleteQueuesBothHalves() {
        let userID = newAccount()
        let shift = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        PaydaySyncState.recordShiftDeletion(shift, at: when, for: userID)

        #expect(PaydaySyncState.pendingShiftDeletions(for: userID)[shift] == when)
        let tombstone = PaydaySyncState.shiftTombstones(for: userID)[shift]
        #expect(tombstone?.deletedAt == when)
        // Not yet flushed, which is what decides whether an undo has to
        // re-push the legacy sources or merely un-queue them.
        #expect(tombstone?.flushedToServer == false)

        PaydaySyncState.markShiftTombstonesFlushed([shift], for: userID)
        #expect(PaydaySyncState.shiftTombstones(for: userID)[shift]?.flushedToServer == true)

        PaydaySyncState.forget(userID: userID)
    }

    /// An account switch or a rollback clears the whole key, and the restore
    /// queue has to go with it or a re-migration meets a stale undo.
    @Test("forgetting an account clears its shift queues too")
    func forgetClearsShiftQueues() {
        let userID = newAccount()
        PaydaySyncState.recordShiftDeletion(UUID(), for: userID)
        PaydaySyncState.recordShiftRestore(UUID(), for: userID)
        PaydaySyncState.recordLegacyEntryDeletions([UUID()], for: userID)
        PaydaySyncState.mutate(userID: userID) { $0.shiftsAreAuthoritativeAt = "2026-09-01T00:00:00.000Z" }

        PaydaySyncState.forget(userID: userID)

        #expect(PaydaySyncState.pendingShiftDeletions(for: userID).isEmpty)
        #expect(PaydaySyncState.pendingShiftRestores(for: userID).isEmpty)
        #expect(PaydaySyncState.pendingLegacyEntryDeletions(for: userID).isEmpty)
        #expect(PaydaySyncState.shiftTombstones(for: userID).isEmpty)
        // Clearing this is what returns the reader to the legacy leg.
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: userID))
    }

    // MARK: - Authority and baselines

    @Test("shift authority is a persisted server fact, never inferred")
    func shiftAuthorityIsPersisted() {
        let userID = newAccount()
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: userID))

        PaydaySyncState.mutate(userID: userID) {
            $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
        }
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: userID))

        PaydaySyncState.forget(userID: userID)
    }

    /// A durable cursor must never outlive the replaceable cache it describes,
    /// or the account starts after a high-water mark for rows it no longer has.
    @Test("a missing shift cache forces a baseline, and an absent one does not")
    func shiftCacheBaselineRules() {
        let shift = UUID()
        let withCursor = PaydaySyncState.Snapshot(
            shiftIDs: [shift],
            shiftServerCursor: .beginning
        )

        #expect(PaydaySyncState.shiftCacheRequiresBaseline(
            localShiftIDs: [], checkpoint: withCursor
        ))
        #expect(!PaydaySyncState.shiftCacheRequiresBaseline(
            localShiftIDs: [shift], checkpoint: withCursor
        ))
        // An id queued for deletion is expected to be gone locally, so its
        // absence is not evidence of a lost cache.
        #expect(!PaydaySyncState.shiftCacheRequiresBaseline(
            localShiftIDs: [], pendingShiftDeletionIDs: [shift], checkpoint: withCursor
        ))

        // Before conversion there is no shift cursor and no shift cache, and
        // that is the normal state for every account today. It must not drag
        // the account into a baseline it has no use for.
        let noCursor = PaydaySyncState.Snapshot(shiftIDs: [shift])
        #expect(!PaydaySyncState.shiftCacheRequiresBaseline(
            localShiftIDs: [], checkpoint: noCursor
        ))
    }

    /// The tip cursor advances to the newest `updated_at` it pulled. That is
    /// wrong for shifts: a shift is written by the fold INSIDE a 1.0 build's
    /// transaction, so its timestamp is stamped when the fold runs but the row
    /// only becomes visible on commit, which can be much later. A cursor
    /// already past that stamp would never deliver the row.
    @Test("the shift cursor is held back from the server clock")
    func shiftCursorSafetyWindowIsFiveMinutes() {
        #expect(PaydaySyncState.shiftCursorSafetyWindow == 300)
    }

    // MARK: - The out-of-process accessor

    /// The accessor the widget and the Siri intent read, and the wiring bug
    /// it closes.
    ///
    /// `EarningsStore.init` documents that "S7 passes its single
    /// `shiftsAreAuthoritative` in here". S7 shipped without doing it, so the
    /// parameter kept its pre-S7 default of `false` at every production call
    /// site and `.shiftCacheWiped` became unreachable in the shipped app. The
    /// consequence is specific: `ModelContextEarningsInputSource.fetchInputs`
    /// reads shifts from `ShiftRecord` ONLY and counts `TipEntry` purely as
    /// `legacyTipEntryCount`, so a converted account whose shift cache was
    /// purged computed from zero shifts while that count knew the data was
    /// still there — and every surface rendered $0.
    @Test("no registered account means shifts are not authoritative")
    func signedOutIsNotAuthoritative() {
        // `forget` clears `currentUserKey` when the account being forgotten
        // is the registered one, which is the only way back to signed-out.
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        #expect(PaydaySyncState.registeredUserID == nil)
        #expect(!PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount)
    }

    /// Registered but NOT yet converted. This is every existing user today,
    /// and it must stay `false`: treating a pre-conversion account as a wiped
    /// cache would blank every screen for everyone.
    @Test("a registered account before conversion is not authoritative")
    func registeredButUnconvertedIsNotAuthoritative() {
        let userID = registeredAccount()
        #expect(!PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount)
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: userID))
    }

    /// Registered AND converted. The accessor must agree with the per-account
    /// function for the same account — one fact, one answer, whichever process
    /// is asking.
    @Test("a converted registered account is authoritative, and agrees with the per-account read")
    func convertedRegisteredAccountIsAuthoritative() {
        let userID = registeredAccount()
        PaydaySyncState.mutate(userID: userID) {
            $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
        }
        #expect(PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: userID) ==
                PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount)
    }

    /// The accessor must follow the REGISTERED account, not any account that
    /// happens to have converted. Otherwise signing into a second, unconverted
    /// account would inherit the first one's authority and read its empty
    /// shift cache as real.
    @Test("the accessor follows the registered account, not a converted stranger")
    func accessorFollowsTheRegisteredAccount() {
        let converted = registeredAccount()
        PaydaySyncState.mutate(userID: converted) {
            $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
        }
        #expect(PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount)

        // Switch to a different, unconverted account. The accessor must go
        // false: inheriting the previous account's authority would read its
        // empty shift cache as real data for someone else.
        let other = registeredAccount()
        #expect(other != converted)
        #expect(!PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount)

        // And the switch necessarily DISCARDS the old account's checkpoint,
        // rather than leaving it dormant. `registerCurrentUser` refuses a
        // switch while another account is registered (`canRegister`), so the
        // only route to a different account is `forget`, which removes that
        // account's snapshot key outright. Asserted because the first draft
        // of this test assumed the opposite and expected the old fact to
        // survive.
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: converted))
    }
}
