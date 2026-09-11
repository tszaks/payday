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

    struct Snapshot: Codable, Equatable {
        var tipEntryIDs: Set<UUID>
        var paycheckIDs: Set<UUID>
        var migrationVerified: Bool
        var tipClientUpdatedAt: [UUID: String]
        var paycheckClientUpdatedAt: [UUID: String]
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
            case settingsClientUpdatedAt
            case tipServerCursor
            case paycheckServerCursor
            case settingsServerUpdatedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            tipEntryIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .tipEntryIDs) ?? []
            paycheckIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .paycheckIDs) ?? []
            migrationVerified = try values.decodeIfPresent(Bool.self, forKey: .migrationVerified) ?? false
            tipClientUpdatedAt = try values.decodeIfPresent([UUID: String].self, forKey: .tipClientUpdatedAt) ?? [:]
            paycheckClientUpdatedAt = try values.decodeIfPresent([UUID: String].self, forKey: .paycheckClientUpdatedAt) ?? [:]
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

    static func localRowChangedDuringSync(
        id: UUID,
        currentClientUpdatedAt: String,
        capturedClientUpdatedAt: [UUID: String]
    ) -> Bool {
        capturedClientUpdatedAt[id] != currentClientUpdatedAt
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
