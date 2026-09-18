import Foundation

/// Durable client metadata only. Financial values remain in Supabase and the
/// SwiftData store is a replaceable offline cache.
enum PaydaySyncState {
    struct ServerCursor: Codable, Equatable, Sendable {
        let updatedAt: String
        let id: UUID

        static let beginning = ServerCursor(
            updatedAt: "1970-01-01T00:00:00.000Z",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        )

        var postgrestFilter: String {
            "updated_at.gt.\(updatedAt),and(updated_at.eq.\(updatedAt),id.gt.\(id.uuidString.lowercased()))"
        }

        static func advanced(
            from current: ServerCursor?,
            candidates: [(updatedAt: String?, id: UUID)]
        ) -> ServerCursor? {
            candidates.compactMap { candidate -> (cursor: ServerCursor, date: Date)? in
                guard let updatedAt = candidate.updatedAt,
                      let date = PaydayRemoteDate.parseInstant(updatedAt) else { return nil }
                return (ServerCursor(updatedAt: updatedAt, id: candidate.id), date)
            }
            .reduce(current.map { ($0, PaydayRemoteDate.parseInstant($0.updatedAt) ?? .distantPast) }) {
                best, candidate in
                guard let best else { return candidate }
                if candidate.date != best.1 { return candidate.date > best.1 ? candidate : best }
                return candidate.cursor.id.uuidString > best.0.id.uuidString ? candidate : best
            }?.0
        }
    }

    /// What a per-row version in a checkpoint MEANS. Stamped into every
    /// checkpoint so an upgrade never has to guess.
    ///
    /// `0` is the shipped scheme: the version was the row's `modifiedAt`
    /// rendered as `client_updated_at`. It could not detect an edit, because
    /// nothing advanced `modifiedAt` (see `TipEntry.touch(at:)`).
    /// `1` is the content fingerprint, see `PaydayRowFingerprint`.
    static let currentVersioningScheme = 1

    struct Snapshot: Codable, Equatable {
        var tipEntryIDs: Set<UUID>
        var paycheckIDs: Set<UUID>
        var migrationVerified: Bool
        var tipClientUpdatedAt: [UUID: String]
        var paycheckClientUpdatedAt: [UUID: String]
        /// The acknowledged content fingerprints — the versions change
        /// detection actually compares. `tipClientUpdatedAt` is still written
        /// beside them, unused for change detection, so a build rolled back
        /// to the timestamp scheme still finds a checkpoint it understands
        /// instead of re-uploading everything.
        ///
        /// Four per-row dictionaries is the cost of that rollback safety net,
        /// re-encoded into the app-group defaults on every sync. Kept rather
        /// than trimmed to two because the deployed `upsert_tip_entries`
        /// carries no clock predicate, so the full re-upload a rolled-back
        /// build would perform could overwrite a newer edit from another
        /// device. The size is paid for on the fingerprint side instead:
        /// `PaydayMigrationHash.fingerprint` stores 16 hex characters, not 64.
        var tipContentFingerprint: [UUID: String]
        var paycheckContentFingerprint: [UUID: String]
        var versioningScheme: Int
        var settingsClientUpdatedAt: String?
        var tipServerCursor: ServerCursor?
        var paycheckServerCursor: ServerCursor?
        var settingsServerUpdatedAt: String?

        // MARK: Shifts (PR 2 slice S7)
        //
        // Seven fields, and every one of them fails SILENTLY if its decode
        // line is forgotten. `init(from:)` below is hand-written with
        // `decodeIfPresent` for every key so that an old checkpoint still
        // loads, which means a missing line does not throw -- it produces a
        // write-only field that always reads back as its default. Nothing
        // logs, nothing crashes, no test fails on its own. A non-persisting
        // `pendingShiftRestores` quietly deletes a shift the user undid; a
        // non-persisting cursor re-baselines the whole account every pass.
        // `design-lint.sh` compares this property list against both
        // `CodingKeys` and the assignments in `init(from:)`, and
        // `everySnapshotFieldSurvivesEncodeDecode` round-trips a fully
        // non-default Snapshot so a forgotten key fails as a value mismatch
        // even if the lint is bypassed.

        /// Shift ids this checkpoint believes the server holds.
        var shiftIDs: Set<UUID>
        var shiftServerCursor: ServerCursor?
        var shiftClientUpdatedAt: [UUID: String]
        /// Durability, from SERVER RESPONSES ONLY -- never from a local fetch,
        /// which would assert local presence as server durability.
        var shiftServerAckedIDs: Set<UUID>
        /// Failed-write retry counts, on a 1/2/4/8-pass backoff. A shift the
        /// server refused is retried and surfaced, never dropped and never
        /// acknowledged: a loop, not a loss.
        var shiftWriteAttempts: [UUID: Int]
        /// Undo that has not yet been confirmed by the server. Durable,
        /// because losing it means a shift the user restored stays deleted.
        var pendingShiftRestores: [UUID: Date]
        /// A SERVER-SOURCED coverage fact, not a local one. Non-nil is what
        /// switches the reader from the legacy leg to `shifts`. Clearing it is
        /// what switches the reader back, which is how rollback and an account
        /// switch both work.
        var shiftsAreAuthoritativeAt: String?

        init(
            tipEntryIDs: Set<UUID> = [],
            paycheckIDs: Set<UUID> = [],
            migrationVerified: Bool = false,
            tipClientUpdatedAt: [UUID: String] = [:],
            paycheckClientUpdatedAt: [UUID: String] = [:],
            tipContentFingerprint: [UUID: String] = [:],
            paycheckContentFingerprint: [UUID: String] = [:],
            versioningScheme: Int = PaydaySyncState.currentVersioningScheme,
            settingsClientUpdatedAt: String? = nil,
            tipServerCursor: ServerCursor? = nil,
            paycheckServerCursor: ServerCursor? = nil,
            settingsServerUpdatedAt: String? = nil,
            shiftIDs: Set<UUID> = [],
            shiftServerCursor: ServerCursor? = nil,
            shiftClientUpdatedAt: [UUID: String] = [:],
            shiftServerAckedIDs: Set<UUID> = [],
            shiftWriteAttempts: [UUID: Int] = [:],
            pendingShiftRestores: [UUID: Date] = [:],
            shiftsAreAuthoritativeAt: String? = nil
        ) {
            self.tipEntryIDs = tipEntryIDs
            self.paycheckIDs = paycheckIDs
            self.migrationVerified = migrationVerified
            self.tipClientUpdatedAt = tipClientUpdatedAt
            self.paycheckClientUpdatedAt = paycheckClientUpdatedAt
            self.tipContentFingerprint = tipContentFingerprint
            self.paycheckContentFingerprint = paycheckContentFingerprint
            self.versioningScheme = versioningScheme
            self.settingsClientUpdatedAt = settingsClientUpdatedAt
            self.tipServerCursor = tipServerCursor
            self.paycheckServerCursor = paycheckServerCursor
            self.settingsServerUpdatedAt = settingsServerUpdatedAt
            self.shiftIDs = shiftIDs
            self.shiftServerCursor = shiftServerCursor
            self.shiftClientUpdatedAt = shiftClientUpdatedAt
            self.shiftServerAckedIDs = shiftServerAckedIDs
            self.shiftWriteAttempts = shiftWriteAttempts
            self.pendingShiftRestores = pendingShiftRestores
            self.shiftsAreAuthoritativeAt = shiftsAreAuthoritativeAt
        }

        private enum CodingKeys: String, CodingKey {
            case tipEntryIDs
            case paycheckIDs
            case migrationVerified
            case tipClientUpdatedAt
            case paycheckClientUpdatedAt
            case tipContentFingerprint
            case paycheckContentFingerprint
            case versioningScheme
            case settingsClientUpdatedAt
            case tipServerCursor
            case paycheckServerCursor
            case settingsServerUpdatedAt
            case shiftIDs
            case shiftServerCursor
            case shiftClientUpdatedAt
            case shiftServerAckedIDs
            case shiftWriteAttempts
            case pendingShiftRestores
            case shiftsAreAuthoritativeAt
        }

        /// Hand-written so a checkpoint persisted by any earlier build still
        /// decodes: every key is optional with a default, and an absent
        /// `versioningScheme` means the shipped timestamp scheme rather than
        /// this one. Dropping a checkpoint on a decode failure would discard
        /// pending deletions and force a full baseline, so no field added
        /// here may ever be required.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            tipEntryIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .tipEntryIDs) ?? []
            paycheckIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .paycheckIDs) ?? []
            migrationVerified = try values.decodeIfPresent(Bool.self, forKey: .migrationVerified) ?? false
            tipClientUpdatedAt = try values.decodeIfPresent([UUID: String].self, forKey: .tipClientUpdatedAt) ?? [:]
            paycheckClientUpdatedAt = try values.decodeIfPresent([UUID: String].self, forKey: .paycheckClientUpdatedAt) ?? [:]
            tipContentFingerprint = try values.decodeIfPresent([UUID: String].self, forKey: .tipContentFingerprint) ?? [:]
            paycheckContentFingerprint = try values.decodeIfPresent([UUID: String].self, forKey: .paycheckContentFingerprint) ?? [:]
            versioningScheme = try values.decodeIfPresent(Int.self, forKey: .versioningScheme) ?? 0
            settingsClientUpdatedAt = try values.decodeIfPresent(String.self, forKey: .settingsClientUpdatedAt)
            tipServerCursor = try values.decodeIfPresent(ServerCursor.self, forKey: .tipServerCursor)
            paycheckServerCursor = try values.decodeIfPresent(ServerCursor.self, forKey: .paycheckServerCursor)
            settingsServerUpdatedAt = try values.decodeIfPresent(String.self, forKey: .settingsServerUpdatedAt)
            shiftIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .shiftIDs) ?? []
            shiftServerCursor = try values.decodeIfPresent(ServerCursor.self, forKey: .shiftServerCursor)
            shiftClientUpdatedAt = try values.decodeIfPresent([UUID: String].self, forKey: .shiftClientUpdatedAt) ?? [:]
            shiftServerAckedIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .shiftServerAckedIDs) ?? []
            shiftWriteAttempts = try values.decodeIfPresent([UUID: Int].self, forKey: .shiftWriteAttempts) ?? [:]
            pendingShiftRestores = try values.decodeIfPresent([UUID: Date].self, forKey: .pendingShiftRestores) ?? [:]
            shiftsAreAuthoritativeAt = try values.decodeIfPresent(String.self, forKey: .shiftsAreAuthoritativeAt)
        }
    }

    private static func key(for userID: UUID) -> String {
        "com.szakacsmedia.payday.supabaseSync.\(userID.uuidString.lowercased())"
    }

    /// Every queue that carries an unflushed deletion.
    ///
    /// The decoder is hand-written and every key is optional, and that is
    /// load-bearing rather than stylistic. Swift's SYNTHESIZED decoder does
    /// not use property defaults, so the moment a key is added here every
    /// blob a 1.0 build wrote throws `keyNotFound` -- and `loadPending`
    /// swallows that with `try?` and returns an empty queue. The result is
    /// that adding a field would SILENTLY DISCARD every tip and paycheck
    /// deletion the shipped build made and never managed to flush, which is
    /// the only record that those deletions ever happened. Measured, not
    /// assumed.
    ///
    /// Normative for this file: every persisted `Codable` here has a
    /// hand-written decoder in which every key is optional. No exceptions.
    ///
    /// One trap for whoever writes a fixture for this: `[UUID: Date]` is NOT
    /// a JSON object. `UUID` does not conform to `CodingKeyRepresentable`, so
    /// Swift encodes these as a flat unkeyed ARRAY of alternating id and
    /// number. A hand-written `{"tipEntries":{"<uuid>":"..."}}` fixture
    /// decodes as `typeMismatch`, `loadPending` swallows it, and the test
    /// fails against a perfectly correct decoder -- which invites someone to
    /// "fix" the storage shape and break reading every real 1.0 blob. Generate
    /// fixtures by ENCODING.
    private struct PendingDeletions: Codable {
        var tipEntries: [UUID: Date] = [:]
        var paychecks: [UUID: Date] = [:]
        var shifts: [UUID: Date] = [:]
        var shiftTombstones: [UUID: ShiftTombstone] = [:]
        /// The legacy source rows of a deleted shift, queued for the shipped
        /// `soft_delete_tip_entries`.
        ///
        /// This has its OWN key rather than sharing `tipEntries`, and the
        /// reason is specific. `synchronize` cancels any pending tip deletion
        /// whose local `TipEntry` row still exists, and it does that BEFORE
        /// the flush runs. Today that is safe only because the 1.0 delete
        /// paths hard-delete the local row in the same breath. Under the
        /// shift model the local legacy mirror is deliberately kept, so every
        /// id queued into `tipEntries` would still be present on the next
        /// pass and the restore-cancel arm would empty the queue **without
        /// one `soft_delete_tip_entries` call ever being issued**: the shift
        /// tombstone reaches the server and the legacy rows stay live
        /// forever. The restore-cancel arm does not touch this key.
        var legacyEntries: [UUID: Date] = [:]

        private enum CodingKeys: String, CodingKey {
            case tipEntries, paychecks, shifts, shiftTombstones, legacyEntries
        }

        init() {}

        init(from decoder: Decoder) throws {
            let v = try decoder.container(keyedBy: CodingKeys.self)
            tipEntries = try v.decodeIfPresent([UUID: Date].self, forKey: .tipEntries) ?? [:]
            paychecks = try v.decodeIfPresent([UUID: Date].self, forKey: .paychecks) ?? [:]
            shifts = try v.decodeIfPresent([UUID: Date].self, forKey: .shifts) ?? [:]
            shiftTombstones = try v.decodeIfPresent([UUID: ShiftTombstone].self, forKey: .shiftTombstones) ?? [:]
            legacyEntries = try v.decodeIfPresent([UUID: Date].self, forKey: .legacyEntries) ?? [:]
        }
    }

    private static let currentUserKey = "com.szakacsmedia.payday.supabaseCurrentUserID"

    /// Internal rather than private for exactly one reason: the test that
    /// proves a blob written by the shipped 1.0 build still decodes has to
    /// write to the REAL key. A test that rebuilt this format string itself
    /// would keep passing if the key were ever renamed, while every real 1.0
    /// blob silently became unreachable -- which is the loss the hand-written
    /// decoder above exists to prevent.
    static func deletionKey(for userID: UUID) -> String {
        "com.szakacsmedia.payday.supabasePendingDeletions.\(userID.uuidString.lowercased())"
    }

    /// Forget an account entirely: its registration, its sync snapshot, and
    /// any deletions still pending upload.
    ///
    /// Account deletion previously left all three behind. The leftover
    /// registration was the worse half of that: `canRegister` only admits a
    /// user when none is registered or the same one is, so a device whose
    /// account had been deleted would refuse the NEXT Apple ID with
    /// `accountMismatch` — a lockout, on a device with no account left to
    /// mismatch against.
    static func forget(userID: UUID) {
        let defaults = AppGroup.defaults
        defaults.removeObject(forKey: key(for: userID))
        defaults.removeObject(forKey: deletionKey(for: userID))
        if registeredUserID == userID {
            defaults.removeObject(forKey: currentUserKey)
        }
    }

    /// The SwiftData cache is not partitioned by account. Refuse an account
    /// switch instead of ever relabeling cached financial rows for a different
    /// user. A future per-account store migration can deliberately relax this.
    @discardableResult
    static func registerCurrentUser(_ userID: UUID) -> Bool {
        guard canRegister(userID: userID, registeredUserID: registeredUserID) else { return false }
        AppGroup.defaults.set(userID.uuidString, forKey: currentUserKey)
        return true
    }

    static func canRegister(userID: UUID, registeredUserID: UUID?) -> Bool {
        registeredUserID == nil || registeredUserID == userID
    }

    static var registeredUserID: UUID? {
        AppGroup.defaults.string(forKey: currentUserKey).flatMap(UUID.init(uuidString:))
    }

    static func recordTipDeletions(_ ids: some Sequence<UUID>, at date: Date = .now) {
        guard let userID = currentUserID else { return }
        var pending = loadPending(for: userID)
        for id in ids { pending.tipEntries[id] = date }
        savePending(pending, for: userID)
    }

    static func cancelTipDeletions(_ ids: some Sequence<UUID>) {
        guard let userID = currentUserID else { return }
        var pending = loadPending(for: userID)
        for id in ids { pending.tipEntries.removeValue(forKey: id) }
        savePending(pending, for: userID)
    }

    static func recordPaycheckDeletion(_ id: UUID, at date: Date = .now) {
        guard let userID = currentUserID else { return }
        var pending = loadPending(for: userID)
        pending.paychecks[id] = date
        savePending(pending, for: userID)
    }

    static func pendingTipDeletions(for userID: UUID) -> [UUID: Date] {
        loadPending(for: userID).tipEntries
    }

    static func pendingPaycheckDeletions(for userID: UUID) -> [UUID: Date] {
        loadPending(for: userID).paychecks
    }

    static func clearTipDeletions(_ ids: some Sequence<UUID>, for userID: UUID) {
        var pending = loadPending(for: userID)
        for id in ids { pending.tipEntries.removeValue(forKey: id) }
        savePending(pending, for: userID)
    }

    static func clearPaycheckDeletions(_ ids: some Sequence<UUID>, for userID: UUID) {
        var pending = loadPending(for: userID)
        for id in ids { pending.paychecks.removeValue(forKey: id) }
        savePending(pending, for: userID)
    }

    static func knownTipEntryIDs(for userID: UUID) -> Set<UUID> {
        load(for: userID).tipEntryIDs
    }

    static func knownPaycheckIDs(for userID: UUID) -> Set<UUID> {
        load(for: userID).paycheckIDs
    }

    static func migrationIsVerified(for userID: UUID) -> Bool {
        load(for: userID).migrationVerified
    }

    static func snapshot(for userID: UUID) -> Snapshot {
        load(for: userID)
    }

    static func changedIDs(
        current: [UUID: String],
        acknowledged: [UUID: String]
    ) -> Set<UUID> {
        Set(current.compactMap { id, version in
            acknowledged[id] == version ? nil : id
        })
    }

    /// True for exactly one sync per install: the checkpoint acknowledges rows
    /// under the shipped timestamp scheme and therefore records no content
    /// fingerprints to compare against. `save` stamps the current scheme, so
    /// this never fires twice.
    ///
    /// A fresh install has nothing acknowledged and needs no seeding — every
    /// local row is simply missing a fingerprint and uploads, which is what
    /// already happened for a new account.
    static func requiresFingerprintSeeding(checkpoint: Snapshot) -> Bool {
        checkpoint.versioningScheme < currentVersioningScheme
            && !(checkpoint.tipEntryIDs.isEmpty && checkpoint.paycheckIDs.isEmpty)
    }

    /// One server row as the seeding comparison has to see it: its content,
    /// plus the two clocks that answer "has this device seen this content?".
    struct SeedingServerRow: Equatable, Sendable {
        let id: UUID
        let contentFingerprint: String
        /// The writing client's clock, as stored by the server.
        let clientUpdatedAt: String
        /// The server's own row clock — the same value the delta cursor is
        /// built from.
        let serverUpdatedAt: String?
        let isDeleted: Bool
    }

    /// The acknowledged fingerprints to use on that one seeding sync.
    ///
    /// Neither obvious shortcut is acceptable. Seeding from the LOCAL rows
    /// would declare every correction the timestamp bug already dropped to be
    /// acknowledged, losing it for good. Seeding from nothing would make every
    /// row look changed and re-upload the entire history. So a live server row
    /// the device has already pulled acknowledges ITS OWN content: a local row
    /// that differs from it is exactly the correction that never got sent, and
    /// it uploads on this sync and never again, while an identical row uploads
    /// nothing.
    ///
    /// That reasoning holds only where the server has not moved since this
    /// device last looked. Where it HAS moved, "local differs from server" is
    /// equally the signature of a newer edit made elsewhere — by a second
    /// device that upgraded first, or by the agent API, which stamps
    /// `client_updated_at = now()` on every update — and uploading the local
    /// side would overwrite it permanently, because the deployed
    /// `upsert_tip_entries` carries no clock predicate at all. So a row this
    /// device has NOT seen acknowledges the LOCAL content: it does not upload,
    /// and the delta pull in this same sync delivers the newer row normally.
    ///
    /// A row the server has tombstoned acknowledges the LOCAL content for the
    /// same reason, so this one-time seeding can never resurrect a row another
    /// device deleted. A row the server has never seen has no entry at all, so
    /// it uploads as the insert it is.
    static func seededVersions(
        local: [UUID: String],
        localClientUpdatedAt: [UUID: String],
        serverRows: [SeedingServerRow],
        pulledThrough: ServerCursor?
    ) -> [UUID: String] {
        let pulledThroughInstant = pulledThrough.flatMap { PaydayRemoteDate.parseInstant($0.updatedAt) }
        var result: [UUID: String] = [:]
        for row in serverRows {
            let acknowledgeLocal = row.isDeleted || serverRowIsUnseen(
                row,
                pulledThrough: pulledThroughInstant,
                localClientUpdatedAt: localClientUpdatedAt[row.id]
            )
            if acknowledgeLocal {
                if let localVersion = local[row.id] { result[row.id] = localVersion }
            } else {
                result[row.id] = row.contentFingerprint
            }
        }
        return result
    }

    /// Whether the server's current copy of a row is content this device has
    /// never pulled, which is the case where a difference from local must NOT
    /// be read as an unsent local correction.
    ///
    /// Two independent signals, either one sufficient, because the cost of a
    /// false "seen" is permanent data loss and the cost of a false "unseen" is
    /// only that one lost correction stays lost:
    ///
    /// 1. The server's own clock. If the row's `updated_at` is past the delta
    ///    cursor this device last pulled through, the device has not read this
    ///    version. Anything unknowable here — no cursor at all, an
    ///    unparseable stamp — counts as unseen; with no cursor this sync is a
    ///    full baseline anyway, so the pull heals local without the upload.
    /// 2. The writing client's clock. A row last written by `reconcileTips`
    ///    carries `modifiedAt` == the server's `client_updated_at` at that
    ///    time, and the shipped bug froze that clock, so a server
    ///    `client_updated_at` STRICTLY newer than local `modifiedAt` means
    ///    someone else wrote after this device last read. This is the signal
    ///    that still works when the cursor cannot be trusted.
    private static func serverRowIsUnseen(
        _ row: SeedingServerRow,
        pulledThrough: Date?,
        localClientUpdatedAt: String?
    ) -> Bool {
        guard let pulledThrough,
              let serverUpdatedAt = row.serverUpdatedAt.flatMap(PaydayRemoteDate.parseInstant)
        else { return true }
        if serverUpdatedAt > pulledThrough { return true }
        guard let serverWrote = PaydayRemoteDate.parseInstant(row.clientUpdatedAt),
              let localWrote = localClientUpdatedAt.flatMap(PaydayRemoteDate.parseInstant)
        else { return false }
        return serverWrote > localWrote
    }

    /// Durable cursors must never outlive the replaceable SwiftData cache they
    /// describe. If a previously populated cache disappears, force a complete
    /// server baseline instead of starting after the old high-water marks.
    static func cacheRequiresBaseline(
        localTipIDs: Set<UUID>,
        localPaycheckIDs: Set<UUID>,
        pendingTipDeletionIDs: Set<UUID> = [],
        pendingPaycheckDeletionIDs: Set<UUID> = [],
        checkpoint: Snapshot
    ) -> Bool {
        let expectedTipIDs = checkpoint.tipEntryIDs.subtracting(pendingTipDeletionIDs)
        let expectedPaycheckIDs = checkpoint.paycheckIDs.subtracting(pendingPaycheckDeletionIDs)
        return !expectedTipIDs.isSubset(of: localTipIDs)
            || !expectedPaycheckIDs.isSubset(of: localPaycheckIDs)
    }

    /// Versions here are content fingerprints, never timestamps — a device
    /// clock must not decide whether a row was edited mid-sync.
    static func localRowChangedDuringSync(
        id: UUID,
        currentVersion: String,
        capturedVersions: [UUID: String]
    ) -> Bool {
        capturedVersions[id] != currentVersion
    }

    static func IDsChangedDuringSync(
        captured: [UUID: String],
        current: [UUID: String]
    ) -> Set<UUID> {
        Set(captured.keys).union(current.keys).filter { captured[$0] != current[$0] }
    }

    /// Checkpoints may acknowledge canonical readback values, but never a
    /// local mutation that happened while the network request was suspended.
    /// Carrying the old acknowledged value (or no value for a new row) keeps
    /// that mutation eligible for the next delta upload.
    static func acknowledgedVersions(
        current: [UUID: String],
        checkpoint: [UUID: String],
        changedDuringSync: Set<UUID>
    ) -> [UUID: String] {
        var result = current
        for id in changedDuringSync {
            if let prior = checkpoint[id] {
                result[id] = prior
            } else {
                result.removeValue(forKey: id)
            }
        }
        return result
    }

    /// Read, modify, write. **The only way to write a checkpoint.**
    ///
    /// This replaces a `save` that took the shipped nine fields and built a
    /// FRESH `Snapshot`, so any caller that omitted a field erased it. With
    /// seven shift fields added, leaving that in place would have wiped all
    /// seven at the end of every single sync pass: re-baseline every pass,
    /// re-push every shift every pass, and `pendingShiftRestores` lost, which
    /// silently deletes a shift the user undid. Both shipped callers passed
    /// only the nine, so the erasure would have been immediate and total.
    ///
    /// A closure over `inout` makes the erasure unexpressible: a caller
    /// touches the fields it means to and cannot omit the rest.
    static func mutate(userID: UUID, _ body: (inout Snapshot) -> Void) {
        var snapshot = load(for: userID)
        body(&snapshot)
        snapshot.versioningScheme = currentVersioningScheme
        if let data = try? JSONEncoder().encode(snapshot) {
            AppGroup.defaults.set(data, forKey: key(for: userID))
        }
    }

    // MARK: - Shifts (PR 2 slice S7)

    /// How far back the shift cursor is held from the server's clock.
    ///
    /// The tip cursor advances to the newest `updated_at` it pulled. That is
    /// wrong for shifts, because a shift is written by the on-arrival fold
    /// INSIDE a 1.0 build's transaction: its `updated_at` is stamped when the
    /// fold runs, but the row only becomes visible when that transaction
    /// commits, which can be much later. A cursor that had already advanced
    /// past that stamp would never deliver the row, and the shift would be
    /// invisible on every device forever.
    ///
    /// So the cursor is `min(newest pulled, serverNow - this)`. Rows inside
    /// the window are re-pulled next pass, which costs nothing: reconciling a
    /// shift is idempotent and the volume is one account's recent shifts.
    ///
    /// Deliberately NOT applied to the tip cursor in this PR. Nothing folds
    /// tip entries into existence, so they do not have this hazard, and
    /// widening a shipped cursor's behaviour is a separate risk.
    static let shiftCursorSafetyWindow: TimeInterval = 300

    /// Whether `public.shifts` may be read as the authority for this account.
    ///
    /// A server-sourced fact, persisted once observed. Both failure directions
    /// are real and neither is recoverable by guessing: read the legacy leg
    /// too long and every newly logged shift is invisible, so the user logs it
    /// twice and two ids reach the server; switch too early and the history
    /// renders empty or partial. So this is never inferred from a local
    /// migration version, which is what both earlier designs did.
    static func shiftsAreAuthoritative(for userID: UUID) -> Bool {
        load(for: userID).shiftsAreAuthoritativeAt != nil
    }

    /// The shift half of `cacheRequiresBaseline`: a durable cursor must never
    /// outlive the replaceable cache it describes.
    ///
    /// Kept as its own function rather than folded into the existing one
    /// because an account can legitimately have a full tip cache and no shift
    /// cache at all -- that is every account before its conversion is
    /// observed -- and a combined predicate would force a pointless full
    /// re-baseline of the tips as well.
    static func shiftCacheRequiresBaseline(
        localShiftIDs: Set<UUID>,
        pendingShiftDeletionIDs: Set<UUID> = [],
        checkpoint: Snapshot
    ) -> Bool {
        checkpoint.shiftServerCursor != nil
            && !checkpoint.shiftIDs.subtracting(pendingShiftDeletionIDs).isSubset(of: localShiftIDs)
    }

    // MARK: Shift deletions

    static func recordShiftDeletion(
        _ id: UUID,
        at date: Date = .now,
        for userID: UUID? = nil
    ) {
        guard let userID = userID ?? currentUserID else { return }
        var pending = loadPending(for: userID)
        pending.shifts[id] = date
        // The durable tombstone, written in the same breath. It is cleared
        // only by a restore, never pruned by time and never by a sync, so an
        // undo remains an exact inverse however long it takes.
        pending.shiftTombstones[id] = ShiftTombstone(deletedAt: date)
        savePending(pending, for: userID)
    }

    static func pendingShiftDeletions(for userID: UUID) -> [UUID: Date] {
        loadPending(for: userID).shifts
    }

    static func clearShiftDeletions(_ ids: some Sequence<UUID>, for userID: UUID) {
        var pending = loadPending(for: userID)
        for id in ids { pending.shifts.removeValue(forKey: id) }
        savePending(pending, for: userID)
    }

    static func shiftTombstones(for userID: UUID) -> [UUID: ShiftTombstone] {
        loadPending(for: userID).shiftTombstones
    }

    /// Records that the server accepted the tombstone. Kept, not deleted:
    /// whether a deletion reached the server is what decides whether an undo
    /// has to re-push the legacy source rows or merely un-queue them.
    static func markShiftTombstonesFlushed(_ ids: some Sequence<UUID>, for userID: UUID) {
        var pending = loadPending(for: userID)
        for id in ids where pending.shiftTombstones[id] != nil {
            pending.shiftTombstones[id]?.flushedToServer = true
        }
        savePending(pending, for: userID)
    }

    static func clearShiftTombstones(_ ids: some Sequence<UUID>, for userID: UUID) {
        var pending = loadPending(for: userID)
        for id in ids { pending.shiftTombstones.removeValue(forKey: id) }
        savePending(pending, for: userID)
    }

    // MARK: Shift restores

    /// A restore queued durably, because an undo that is lost on relaunch
    /// leaves the shift deleted and the user has no way to know.
    ///
    /// Lives in the checkpoint rather than the deletion blob so that
    /// `forget` and a rollback clear it with everything else.
    static func recordShiftRestore(_ id: UUID, at date: Date = .now, for userID: UUID? = nil) {
        guard let userID = userID ?? currentUserID else { return }
        mutate(userID: userID) { $0.pendingShiftRestores[id] = date }
    }

    static func pendingShiftRestores(for userID: UUID) -> [UUID: Date] {
        load(for: userID).pendingShiftRestores
    }

    /// Cleared only after a confirmation read shows the shift is live again.
    static func clearShiftRestores(_ ids: some Sequence<UUID>, for userID: UUID) {
        mutate(userID: userID) { snapshot in
            for id in ids { snapshot.pendingShiftRestores.removeValue(forKey: id) }
        }
    }

    // MARK: The legacy source rows of a deleted shift

    /// Queues the legacy rows behind a deleted shift for the shipped
    /// `soft_delete_tip_entries`, through a key of their own.
    ///
    /// See `PendingDeletions.legacyEntries` for why sharing the tip queue
    /// would have emptied it without ever issuing one call.
    static func recordLegacyEntryDeletions(
        _ ids: some Sequence<UUID>,
        at date: Date = .now,
        for userID: UUID? = nil
    ) {
        guard let userID = userID ?? currentUserID else { return }
        var pending = loadPending(for: userID)
        for id in ids { pending.legacyEntries[id] = date }
        savePending(pending, for: userID)
    }

    /// Undo before the flush: the rows were never tombstoned, so un-queueing
    /// them is the whole inverse.
    static func cancelLegacyEntryDeletions(_ ids: some Sequence<UUID>, for userID: UUID? = nil) {
        guard let userID = userID ?? currentUserID else { return }
        var pending = loadPending(for: userID)
        for id in ids { pending.legacyEntries.removeValue(forKey: id) }
        savePending(pending, for: userID)
    }

    static func pendingLegacyEntryDeletions(for userID: UUID) -> [UUID: Date] {
        loadPending(for: userID).legacyEntries
    }

    /// Cleared against the RPC's RETURN SET, never unconditionally.
    ///
    /// `soft_delete_tip_entries` only writes rows where
    /// `p_deleted_at >= client_updated_at`, and `client_updated_at` was
    /// clamped to the server's clock while `p_deleted_at` is the device's. A
    /// device running behind the server therefore tombstones NOTHING and gets
    /// no error, and the shipped client clears its whole queue regardless. So
    /// the caller passes only the ids the server said it wrote; the rest stay
    /// queued and retry, and the skew is bounded so it converges.
    static func clearLegacyEntryDeletions(_ ids: some Sequence<UUID>, for userID: UUID) {
        var pending = loadPending(for: userID)
        for id in ids { pending.legacyEntries.removeValue(forKey: id) }
        savePending(pending, for: userID)
    }

    private static func load(for userID: UUID) -> Snapshot {
        guard let data = AppGroup.defaults.data(forKey: key(for: userID)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            return Snapshot()
        }
        return snapshot
    }

    private static var currentUserID: UUID? {
        registeredUserID
    }

    private static func loadPending(for userID: UUID) -> PendingDeletions {
        guard let data = AppGroup.defaults.data(forKey: deletionKey(for: userID)),
              let value = try? JSONDecoder().decode(PendingDeletions.self, from: data)
        else { return PendingDeletions() }
        return value
    }

    private static func savePending(_ value: PendingDeletions, for userID: UUID) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        AppGroup.defaults.set(data, forKey: deletionKey(for: userID))
    }
}

/// A deletion this device made, remembered until it is undone.
///
/// Local only, never a wire type. Durable and never pruned by time or by a
/// sync, because it is what makes an undo an exact inverse rather than a
/// best effort.
struct ShiftTombstone: Codable, Equatable {
    var deletedAt: Date
    /// Whether the server accepted the tombstone. This is what decides
    /// whether an undo merely un-queues the legacy source rows or has to
    /// re-push them to un-delete rows the server already tombstoned.
    var flushedToServer: Bool = false

    private enum CodingKeys: String, CodingKey {
        case deletedAt, flushedToServer
    }

    init(deletedAt: Date, flushedToServer: Bool = false) {
        self.deletedAt = deletedAt
        self.flushedToServer = flushedToServer
    }

    /// Hand-written and all-optional, under this file's normative rule. No
    /// shipped build ever wrote this type, so the defaulting branch is
    /// unreachable for any blob that exists today; it is here so that adding
    /// a field later cannot make an existing blob throw, which would take
    /// every queued deletion with it.
    ///
    /// `.distantPast` for a missing date is the deliberate choice over `.now`.
    /// The flush only writes rows where the requested date is at or after the
    /// stored one, so a distant-past tombstone stays queued, retries, and
    /// surfaces to the user. `.now` would instead flush a deletion stamped
    /// with a fabricated time. For a deletion, staying stuck and visible
    /// beats proceeding on an invented value.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt) ?? .distantPast
        flushedToServer = try values.decodeIfPresent(Bool.self, forKey: .flushedToServer) ?? false
    }
}

struct PaydayRPCPayload<T: Encodable>: Encodable {
    let pRows: [T]

    enum CodingKeys: String, CodingKey {
        case pRows = "p_rows"
    }
}

struct PaydayRPCRow<T: Encodable>: Encodable {
    let pRow: T

    enum CodingKeys: String, CodingKey {
        case pRow = "p_row"
    }
}

struct PaydayDeletionParameters: Encodable {
    let ids: [UUID]
    let deletedAt: String

    enum CodingKeys: String, CodingKey {
        case ids = "p_ids"
        case deletedAt = "p_deleted_at"
    }
}
