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
        var tipContentFingerprint: [UUID: String]
        var paycheckContentFingerprint: [UUID: String]
        var versioningScheme: Int
        var settingsClientUpdatedAt: String?
        var tipServerCursor: ServerCursor?
        var paycheckServerCursor: ServerCursor?
        var settingsServerUpdatedAt: String?

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
            settingsServerUpdatedAt: String? = nil
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
        }
    }

    private static func key(for userID: UUID) -> String {
        "com.szakacsmedia.payday.supabaseSync.\(userID.uuidString.lowercased())"
    }

    private struct PendingDeletions: Codable {
        var tipEntries: [UUID: Date] = [:]
        var paychecks: [UUID: Date] = [:]
    }

    private static let currentUserKey = "com.szakacsmedia.payday.supabaseCurrentUserID"

    private static func deletionKey(for userID: UUID) -> String {
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

    static func save(
        userID: UUID,
        tipEntryIDs: Set<UUID>,
        paycheckIDs: Set<UUID>,
        migrationVerified: Bool,
        tipClientUpdatedAt: [UUID: String] = [:],
        paycheckClientUpdatedAt: [UUID: String] = [:],
        tipContentFingerprint: [UUID: String] = [:],
        paycheckContentFingerprint: [UUID: String] = [:],
        settingsClientUpdatedAt: String? = nil,
        tipServerCursor: ServerCursor? = nil,
        paycheckServerCursor: ServerCursor? = nil,
        settingsServerUpdatedAt: String? = nil
    ) {
        let snapshot = Snapshot(
            tipEntryIDs: tipEntryIDs,
            paycheckIDs: paycheckIDs,
            migrationVerified: migrationVerified,
            tipClientUpdatedAt: tipClientUpdatedAt,
            paycheckClientUpdatedAt: paycheckClientUpdatedAt,
            tipContentFingerprint: tipContentFingerprint,
            paycheckContentFingerprint: paycheckContentFingerprint,
            versioningScheme: currentVersioningScheme,
            settingsClientUpdatedAt: settingsClientUpdatedAt,
            tipServerCursor: tipServerCursor,
            paycheckServerCursor: paycheckServerCursor,
            settingsServerUpdatedAt: settingsServerUpdatedAt
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            AppGroup.defaults.set(data, forKey: key(for: userID))
        }
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
