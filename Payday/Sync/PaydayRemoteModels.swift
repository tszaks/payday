import CryptoKit
import Foundation

struct RemoteTipEntry: Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let shiftID: UUID?
    let workDate: String
    let amountCents: Int
    let kind: String
    let note: String?
    let recordedAt: String?
    let isDouble: Bool
    let hoursWorked: Double?
    let tipOutCents: Int?
    let salesCents: Int?
    let shiftPeriod: String?
    let clockIn: String?
    let clockOut: String?
    let serverCount: Int?
    let receiptMetrics: ShiftReceiptMetrics?
    let clientUpdatedAt: String
    let deletedAt: String?
    let serverUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case shiftID = "shift_id"
        case workDate = "work_date"
        case amountCents = "amount_cents"
        case kind
        case note
        case recordedAt = "recorded_at"
        case isDouble = "is_double"
        case hoursWorked = "hours_worked"
        case tipOutCents = "tip_out_cents"
        case salesCents = "sales_cents"
        case shiftPeriod = "shift_period"
        case clockIn = "clock_in"
        case clockOut = "clock_out"
        case serverCount = "server_count"
        case receiptMetrics = "receipt_metrics"
        case clientUpdatedAt = "client_updated_at"
        case deletedAt = "deleted_at"
        case serverUpdatedAt = "updated_at"
    }

    @MainActor
    init(entry: TipEntry, userID: UUID) {
        self.id = entry.id
        self.userID = userID
        self.shiftID = entry.shiftID
        self.workDate = PaydayRemoteDate.day(entry.date)
        self.amountCents = entry.amountCents
        self.kind = entry.kind.rawValue
        self.note = entry.note
        self.recordedAt = entry.recordedAt.map(PaydayRemoteDate.instant)
        self.isDouble = entry.isDouble
        self.hoursWorked = entry.hoursWorked
        self.tipOutCents = entry.tipOutCents
        self.salesCents = entry.salesCents
        self.shiftPeriod = entry.shiftPeriod?.rawValue
        self.clockIn = entry.clockIn.map(PaydayRemoteDate.instant)
        self.clockOut = entry.clockOut.map(PaydayRemoteDate.instant)
        self.serverCount = entry.serverCount
        self.receiptMetrics = entry.receiptMetrics
        self.clientUpdatedAt = PaydayRemoteDate.instant(entry.modifiedAt)
        self.deletedAt = nil
        self.serverUpdatedAt = nil
    }

    var businessValue: TipBusinessValue {
        businessValue(workDate: workDate)
    }

    /// The business value with the work day supplied, because the wire value
    /// and the VERSION value are deliberately different renders of the same
    /// stored instant.
    ///
    /// The wire keeps `PaydayRemoteDate.day(entry.date)` — the shipped
    /// rendering, in the device's current calendar — so no row this build
    /// uploads carries a date the shipped build would not have written, from
    /// any time zone on earth. The version uses
    /// `PaydayRemoteDate.stableDay`, which no time-zone change can move, so a
    /// flight cannot put the untouched history into the upload set. Where the
    /// two disagree (see `stableDay` for the two offsets), the row uploads
    /// once with content identical to what the server already holds; it can
    /// never upload a shifted date.
    func businessValue(workDate: String) -> TipBusinessValue {
        TipBusinessValue(
            id: id,
            shiftID: shiftID,
            workDate: workDate,
            amountCents: amountCents,
            kind: kind,
            note: note,
            recordedAt: PaydayRemoteDate.canonicalInstant(recordedAt),
            isDouble: isDouble,
            hoursWorked: hoursWorked,
            tipOutCents: tipOutCents,
            salesCents: salesCents,
            shiftPeriod: shiftPeriod,
            clockIn: PaydayRemoteDate.canonicalInstant(clockIn),
            clockOut: PaydayRemoteDate.canonicalInstant(clockOut),
            serverCount: serverCount,
            receiptMetrics: receiptMetrics
        )
    }

    /// A stable digest of exactly the fields this row uploads, and of nothing
    /// else — see `PaydayRowFingerprint` for why the sync layer versions rows
    /// by content instead of by clock.
    ///
    /// On a row decoded from the server this is the right digest as written:
    /// `workDate` is the day string the server holds. A row built from a local
    /// `TipEntry` must instead digest the zone-independent
    /// `contentFingerprint(workDate:)`, which is what `PaydayRowFingerprint`
    /// does.
    var contentFingerprint: String {
        get throws { try PaydayMigrationHash.fingerprint(businessValue) }
    }

    func contentFingerprint(workDate: String) throws -> String {
        try PaydayMigrationHash.fingerprint(businessValue(workDate: workDate))
    }

    /// This row reduced to what the one-time fingerprint seeding has to judge:
    /// its content, and the two clocks that say whether this device has ever
    /// seen that content. See `PaydaySyncState.seededVersions`.
    var seedingRow: PaydaySyncState.SeedingServerRow {
        get throws {
            PaydaySyncState.SeedingServerRow(
                id: id,
                contentFingerprint: try contentFingerprint,
                clientUpdatedAt: clientUpdatedAt,
                serverUpdatedAt: serverUpdatedAt,
                isDeleted: deletedAt != nil
            )
        }
    }
}

struct TipBusinessValue: Codable, Equatable, Sendable {
    let id: UUID
    let shiftID: UUID?
    let workDate: String
    let amountCents: Int
    let kind: String
    let note: String?
    let recordedAt: String?
    let isDouble: Bool
    let hoursWorked: Double?
    let tipOutCents: Int?
    let salesCents: Int?
    let shiftPeriod: String?
    let clockIn: String?
    let clockOut: String?
    let serverCount: Int?
    let receiptMetrics: ShiftReceiptMetrics?
}

struct RemotePaycheckRecord: Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let periodStart: String
    let periodEnd: String
    let paidTipsCents: Int
    let note: String?
    let hourlyRateCents: Int?
    let owedTipsCents: Int?
    let grossPayCents: Int?
    let netPayCents: Int?
    let regularWagesCents: Int?
    let overtimeWagesCents: Int?
    let gratuityCents: Int?
    let taxesCents: Int?
    let clientUpdatedAt: String
    let deletedAt: String?
    let serverUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case paidTipsCents = "paid_tips_cents"
        case note
        case hourlyRateCents = "hourly_rate_cents"
        case owedTipsCents = "owed_tips_cents"
        case grossPayCents = "gross_pay_cents"
        case netPayCents = "net_pay_cents"
        case regularWagesCents = "regular_wages_cents"
        case overtimeWagesCents = "overtime_wages_cents"
        case gratuityCents = "gratuity_cents"
        case taxesCents = "taxes_cents"
        case clientUpdatedAt = "client_updated_at"
        case deletedAt = "deleted_at"
        case serverUpdatedAt = "updated_at"
    }

    @MainActor
    init(record: PaycheckRecord, userID: UUID) {
        self.id = record.id
        self.userID = userID
        self.periodStart = PaydayRemoteDate.day(record.periodStart)
        self.periodEnd = PaydayRemoteDate.day(record.periodEnd)
        self.paidTipsCents = record.paidTipsCents
        self.note = record.note
        self.hourlyRateCents = record.hourlyRateCents
        self.owedTipsCents = record.owedTipsCents
        self.grossPayCents = record.grossPayCents
        self.netPayCents = record.netPayCents
        self.regularWagesCents = record.regularWagesCents
        self.overtimeWagesCents = record.overtimeWagesCents
        self.gratuityCents = record.gratuityCents
        self.taxesCents = record.taxesCents
        self.clientUpdatedAt = PaydayRemoteDate.instant(record.modifiedAt)
        self.deletedAt = nil
        self.serverUpdatedAt = nil
    }

    var businessValue: PaycheckBusinessValue {
        businessValue(periodStart: periodStart, periodEnd: periodEnd)
    }

    /// See `RemoteTipEntry.businessValue(workDate:)`.
    func businessValue(periodStart: String, periodEnd: String) -> PaycheckBusinessValue {
        PaycheckBusinessValue(
            id: id,
            periodStart: periodStart,
            periodEnd: periodEnd,
            paidTipsCents: paidTipsCents,
            note: note,
            hourlyRateCents: hourlyRateCents,
            owedTipsCents: owedTipsCents,
            grossPayCents: grossPayCents,
            netPayCents: netPayCents,
            regularWagesCents: regularWagesCents,
            overtimeWagesCents: overtimeWagesCents,
            gratuityCents: gratuityCents,
            taxesCents: taxesCents
        )
    }

    /// See `RemoteTipEntry.contentFingerprint`.
    var contentFingerprint: String {
        get throws { try PaydayMigrationHash.fingerprint(businessValue) }
    }

    func contentFingerprint(periodStart: String, periodEnd: String) throws -> String {
        try PaydayMigrationHash.fingerprint(
            businessValue(periodStart: periodStart, periodEnd: periodEnd)
        )
    }

    /// See `RemoteTipEntry.seedingRow`.
    var seedingRow: PaydaySyncState.SeedingServerRow {
        get throws {
            PaydaySyncState.SeedingServerRow(
                id: id,
                contentFingerprint: try contentFingerprint,
                clientUpdatedAt: clientUpdatedAt,
                serverUpdatedAt: serverUpdatedAt,
                isDeleted: deletedAt != nil
            )
        }
    }
}

struct PaycheckBusinessValue: Codable, Equatable, Sendable {
    let id: UUID
    let periodStart: String
    let periodEnd: String
    let paidTipsCents: Int
    let note: String?
    let hourlyRateCents: Int?
    let owedTipsCents: Int?
    let grossPayCents: Int?
    let netPayCents: Int?
    let regularWagesCents: Int?
    let overtimeWagesCents: Int?
    let gratuityCents: Int?
    let taxesCents: Int?
}

struct RemoteUserSettings: Codable, Sendable {
    let userID: UUID
    let firstName: String?
    let baseHourlyWageCents: Int?
    let payFrequency: String?
    let anchorPeriodEnd: String?
    let payDelayDays: Int?
    let firstWeekday: Int?
    let smartNudgeEnabled: Bool
    let paydayReminderEnabled: Bool
    let moveLedger: [String: String]
    /// Rate and payroll-calendar history (PaydayCore `CompensationPolicies`).
    ///
    /// Optional because null on the server means "the client that last wrote
    /// this row does not know about policies" — Payday 1.0, which is already
    /// shipped — rather than "this user has no policies". `apply` treats nil
    /// and empty the same way: leave whatever the device already has alone.
    /// The `upsert_user_settings` RPC coalesces a null back to the stored
    /// value for the same reason.
    let compensationPolicies: CompensationPolicies?
    let clientUpdatedAt: String
    let serverUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case firstName = "first_name"
        case baseHourlyWageCents = "base_hourly_wage_cents"
        case payFrequency = "pay_frequency"
        case anchorPeriodEnd = "anchor_period_end"
        case payDelayDays = "pay_delay_days"
        case firstWeekday = "first_weekday"
        case smartNudgeEnabled = "smart_nudge_enabled"
        case paydayReminderEnabled = "payday_reminder_enabled"
        case moveLedger = "move_ledger"
        case compensationPolicies = "compensation_policies"
        case clientUpdatedAt = "client_updated_at"
        case serverUpdatedAt = "updated_at"
    }

    @MainActor
    init(
        userID: UUID,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore
    ) {
        let schedule = scheduleStore.schedule
        self.userID = userID
        self.firstName = preferencesStore.firstName
        self.baseHourlyWageCents = preferencesStore.baseHourlyWageCents
        self.payFrequency = schedule?.frequency.rawValue
        self.anchorPeriodEnd = schedule.map { PaydayRemoteDate.day($0.anchorPeriodEnd) }
        self.payDelayDays = schedule?.payDelayDays
        self.firstWeekday = schedule?.firstWeekday
        self.smartNudgeEnabled = preferencesStore.isSmartNudgeEnabled
        self.paydayReminderEnabled = preferencesStore.isPaydayReminderEnabled
        self.moveLedger = moveLedgerStore.firstShownAt.mapValues(PaydayRemoteDate.instant)
        // Sent even when empty so a device that has genuinely cleared its
        // policies can say so; only NIL means "I do not know about policies".
        self.compensationPolicies = policyStore.policies
        self.clientUpdatedAt = PaydayRemoteDate.instant(PaydaySettingsSyncClock.modifiedAt)
        self.serverUpdatedAt = nil
    }
}

struct RemoteMigrationReceipt: Encodable, Sendable {
    let userID: UUID
    let deviceID: UUID
    let schemaVersion: Int
    let tipEntryCount: Int
    let paycheckRecordCount: Int
    let tipEntryHash: String
    let paycheckRecordHash: String
    let verifiedAt: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
        case schemaVersion = "schema_version"
        case tipEntryCount = "tip_entry_count"
        case paycheckRecordCount = "paycheck_record_count"
        case tipEntryHash = "tip_entry_hash"
        case paycheckRecordHash = "paycheck_record_hash"
        case verifiedAt = "verified_at"
    }
}

/// The local row version the sync layer compares: a content fingerprint, not
/// a timestamp.
///
/// A timestamp version can only work if every write path remembers to advance
/// it. Shipped Payday proved that is not a promise code can keep — fifteen
/// `didSet` observers were supposed to advance `TipEntry.modifiedAt` and none
/// of them ever fired (see `TipEntry.touch(at:)`), so an acknowledged row's
/// version never moved and a correction to it could never re-enter the upload
/// set. A fingerprint moves on its own: a missed `touch()` costs nothing,
/// because the digest is computed from the values themselves.
///
/// The digest covers exactly the fields that get uploaded, via the same
/// `Remote*` mapping the uploader uses, so it cannot drift out of step with
/// what is actually sent. `user_id` is constant for an account, `deleted_at`
/// is always nil on an upload and `updated_at` is the server's, so none of
/// them belong here — and `client_updated_at` is deliberately excluded,
/// because a fingerprint containing its own clock would move whenever the
/// clock moved and never when only content did, which is the failure being
/// replaced. `client_updated_at` stays a real advancing timestamp on the wire
/// anyway: it is how two writers are ordered, it is what the agent API reads
/// and stamps, and it is the only value a future conflict predicate could
/// gate on. It is NOT such a gate today — the deployed
/// `upsert_tip_entries`/`upsert_paycheck_records`
/// (supabase/migrations/20260904134500_harden_sync_ordering_and_agent_recovery.sql)
/// carry no clock predicate at all, only `user_id = auth.uid()`, so every
/// upload this client sends is accepted unconditionally. Which is exactly why
/// the upload set has to be right before it leaves the device: see
/// `PaydaySyncState.seededVersions`.
///
/// Order-independent: `PaydayMigrationHash` encodes with `.sortedKeys`, which
/// applies at every nesting level, so the digest depends on field values and
/// never on declaration or dictionary order.
///
/// Every input is a pure function of stored values, and that is load-bearing,
/// not incidental. `work_date` (and a paycheck's `period_start`/`period_end`)
/// go into the digest through `PaydayRemoteDate.stableDay`, which ignores the
/// device's current time zone precisely so that a flight cannot move a
/// version: rendering the stored local-midnight instant in the current
/// calendar instead would have put the whole history in the upload set the
/// first time Tyler flew west, and the deployed `upsert_tip_entries` has no
/// clock predicate to reject any of it. The instant fields (`recorded_at`,
/// `clock_in`, `clock_out`) are ISO-8601 UTC, zone-independent already.
enum PaydayRowFingerprint {
    /// `user_id` is not part of `businessValue`, so the digest does not depend
    /// on it. This placeholder only satisfies the initializer for callers that
    /// fingerprint a local row without an authenticated session in hand.
    private static let placeholderUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The day components come from `PaydayRemoteDate.stableDay` rather than
    /// from the row's own wire value, so the device's current time zone cannot
    /// move a version. See `RemoteTipEntry.businessValue(workDate:)`.
    @MainActor
    static func value(_ entry: TipEntry) throws -> String {
        try RemoteTipEntry(entry: entry, userID: placeholderUserID)
            .contentFingerprint(workDate: PaydayRemoteDate.stableDay(entry.date))
    }

    @MainActor
    static func value(_ record: PaycheckRecord) throws -> String {
        try RemotePaycheckRecord(record: record, userID: placeholderUserID)
            .contentFingerprint(
                periodStart: PaydayRemoteDate.stableDay(record.periodStart),
                periodEnd: PaydayRemoteDate.stableDay(record.periodEnd)
            )
    }

    @MainActor
    static func values(_ entries: [TipEntry]) throws -> [UUID: String] {
        try Dictionary(uniqueKeysWithValues: entries.map { try ($0.id, value($0)) })
    }

    @MainActor
    static func values(_ records: [PaycheckRecord]) throws -> [UUID: String] {
        try Dictionary(uniqueKeysWithValues: records.map { try ($0.id, value($0)) })
    }

    @MainActor
    static func value(_ record: ShiftRecord) throws -> String {
        try RemoteShift(record: record, userID: placeholderUserID)
            .contentFingerprint(workDate: PaydayRemoteDate.stableDay(record.workDate))
    }

    @MainActor
    static func values(_ records: [ShiftRecord]) throws -> [UUID: String] {
        try Dictionary(uniqueKeysWithValues: records.map { try ($0.id, value($0)) })
    }
}

enum PaydayMigrationHash {
    static func value<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(value))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The row-version form of `value`: the same digest, cut to its first 64
    /// bits, because a checkpoint persists one of these per row into the
    /// app-group `UserDefaults` and re-encodes the whole blob on every sync.
    ///
    /// The comparison is always same-id-to-same-id — "is this row's content
    /// still what the server acknowledged?" — so the only collision that could
    /// matter is between two versions of ONE row, over the handful of edits a
    /// row ever receives. Never used for the migration receipt hashes the
    /// server stores and compares; those stay full width.
    static func fingerprint<T: Encodable>(_ value: T) throws -> String {
        String(try Self.value(value).prefix(16))
    }
}

// MARK: - Shifts (PR 2 slice S6)

/// One `public.shifts` row on the wire.
///
/// The encode side names ONLY the columns `private.write_shifts` reads, and
/// that omission is load-bearing rather than tidiness. Four columns on this
/// table are server-authored and a client must never be able to set them:
///
/// - `source` and `legacy_entry_ids` are the rollback query. `source =
///   'migration'` plus provenance is how an operator finds every row a
///   conversion derived, so a client that could write `source` could make
///   rollback either miss a conversion artifact or tombstone a shift the user
///   authored.
/// - `native_modified_at` is the fold's precedence rule
///   (`private.shift_is_open_to_fold` reads exactly it). A client that could
///   write it could reopen a shift a human edited to being repriced by a
///   conversion, or freeze one that should still convert.
/// - `deleted_at` is one-way on the write path. A write never resurrects a
///   tombstone; only `restore_shifts` does, and only one it did not create as
///   `'converted'`. Omitting it here enforces that in the client too, so the
///   rule holds even if someone later hands a tombstoned row to `upsertShifts`.
///
/// `public.shifts` grants no direct INSERT or UPDATE for the same reason, so
/// these are refused at two layers, not one.
struct RemoteShift: Codable, Equatable, Sendable {
    let id: UUID
    let userID: UUID
    let workDate: String
    let shiftPeriod: String?
    let cashTipsCents: Int
    let creditTipsCents: Int
    let tipOutCents: Int?
    let salesCents: Int?
    let hoursWorked: Double?
    let clockIn: String?
    let clockOut: String?
    let serverCount: Int?
    let receiptMetrics: ShiftReceiptMetrics?
    let note: String?
    let recordedAt: String?
    let clientUpdatedAt: String

    // Server-authored. Decoded, never encoded. See the type's documentation.
    let source: String?
    let legacyEntryIDs: [UUID]?
    let nativeModifiedAt: String?
    let deletedAt: String?
    let deletedReason: String?
    let gratuityFeesCents: Int?
    let nonWageEarningsCents: Int?
    let version: Int?
    let serverUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case workDate = "work_date"
        case shiftPeriod = "shift_period"
        case cashTipsCents = "cash_tips_cents"
        case creditTipsCents = "credit_tips_cents"
        case tipOutCents = "tip_out_cents"
        case salesCents = "sales_cents"
        case hoursWorked = "hours_worked"
        case clockIn = "clock_in"
        case clockOut = "clock_out"
        case serverCount = "server_count"
        case receiptMetrics = "receipt_metrics"
        case note
        case recordedAt = "recorded_at"
        case clientUpdatedAt = "client_updated_at"
        case source
        case legacyEntryIDs = "legacy_entry_ids"
        case nativeModifiedAt = "native_modified_at"
        case deletedAt = "deleted_at"
        case deletedReason = "deleted_reason"
        case gratuityFeesCents = "gratuity_fees_cents"
        case nonWageEarningsCents = "non_wage_earnings_cents"
        case version
        case serverUpdatedAt = "updated_at"
    }

    /// Exactly the keys `private.write_shifts` reads. Anything else it ignores
    /// by construction, but sending a server-authored column would still be a
    /// lie about intent, so none is encoded.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workDate, forKey: .workDate)
        try container.encode(shiftPeriod, forKey: .shiftPeriod)
        try container.encode(cashTipsCents, forKey: .cashTipsCents)
        try container.encode(creditTipsCents, forKey: .creditTipsCents)
        try container.encode(tipOutCents, forKey: .tipOutCents)
        try container.encode(salesCents, forKey: .salesCents)
        try container.encode(hoursWorked, forKey: .hoursWorked)
        try container.encode(clockIn, forKey: .clockIn)
        try container.encode(clockOut, forKey: .clockOut)
        try container.encode(serverCount, forKey: .serverCount)
        try container.encode(receiptMetrics, forKey: .receiptMetrics)
        try container.encode(note, forKey: .note)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }

    /// True when a conversion derived this row and a human has since edited it.
    /// This is the set a rollback would silently discard, because rollback
    /// reads `public.tip_entries` again and a PR-2 build's edit never writes
    /// back there. Surfaced so it can be counted before anyone pulls that
    /// lever, not discovered afterwards.
    var isEditedConversionArtifact: Bool {
        source == "migration" && nativeModifiedAt != nil
    }
}

/// What the server did with one requested shift.
///
/// `unknown` exists so a server that grows a new status cannot make an older
/// client throw while decoding its own successful write. The same reason
/// `kindRaw` is a raw string on the local models.
enum ShiftWriteStatus: Equatable, Sendable {
    /// Written. `storedClientUpdatedAt` says what the server actually kept,
    /// which is not necessarily what was sent: a future-dated timestamp is
    /// clamped to the server's clock rather than rejected.
    case stored
    /// Validated but not written. Unreachable against today's schema and kept
    /// so a future trigger that skips a row reports it instead of letting the
    /// client believe the write landed.
    case refused
    /// One row was unusable — no readable id, no work date, or money the
    /// column cannot hold — and only that row was dropped. Never the batch.
    case invalid
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "stored": self = .stored
        case "refused": self = .refused
        case "invalid": self = .invalid
        default: self = .unknown(raw)
        }
    }

    var raw: String {
        switch self {
        case .stored: "stored"
        case .refused: "refused"
        case .invalid: "invalid"
        case .unknown(let value): value
        }
    }

    /// Whether the client may treat the row as synced.
    var isPersisted: Bool { self == .stored }
}

struct ShiftWriteOutcome: Decodable, Equatable, Sendable {
    /// Nil only when the id itself was unreadable, which is the one case the
    /// server cannot name back.
    let shiftID: UUID?
    let status: ShiftWriteStatus
    let storedClientUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case shiftID = "shift_id"
        case status
        case storedClientUpdatedAt = "stored_client_updated_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shiftID = try container.decodeIfPresent(UUID.self, forKey: .shiftID)
        status = ShiftWriteStatus(raw: try container.decode(String.self, forKey: .status))
        storedClientUpdatedAt = try container.decodeIfPresent(String.self, forKey: .storedClientUpdatedAt)
    }

    init(shiftID: UUID?, status: ShiftWriteStatus, storedClientUpdatedAt: String?) {
        self.shiftID = shiftID
        self.status = status
        self.storedClientUpdatedAt = storedClientUpdatedAt
    }
}

/// Deletion and restoration share one outcome shape. Deletion answers
/// `deleted | absent | invalid`; restoration answers
/// `restored | absent | notDeleted | refused`.
enum ShiftLifecycleStatus: Equatable, Sendable {
    case deleted
    case restored
    /// The caller has no shift with that id. Never another account's row:
    /// every RPC here is scoped to `auth.uid()`.
    case absent
    /// The shift exists and was not tombstoned, so there was nothing to undo.
    case notDeleted
    /// A `'converted'` tombstone. It belongs to the fold's own un-delete arm,
    /// and reopening it here would resurrect a shift whose legacy source rows
    /// are gone.
    case refused
    case invalid
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "deleted": self = .deleted
        case "restored": self = .restored
        case "absent": self = .absent
        case "not_deleted": self = .notDeleted
        case "refused": self = .refused
        case "invalid": self = .invalid
        default: self = .unknown(raw)
        }
    }

    var raw: String {
        switch self {
        case .deleted: "deleted"
        case .restored: "restored"
        case .absent: "absent"
        case .notDeleted: "not_deleted"
        case .refused: "refused"
        case .invalid: "invalid"
        case .unknown(let value): value
        }
    }
}

struct ShiftLifecycleOutcome: Decodable, Equatable, Sendable {
    let shiftID: UUID?
    let status: ShiftLifecycleStatus

    enum CodingKeys: String, CodingKey {
        case shiftID = "shift_id"
        case status
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shiftID = try container.decodeIfPresent(UUID.self, forKey: .shiftID)
        status = ShiftLifecycleStatus(raw: try container.decode(String.self, forKey: .status))
    }

    init(shiftID: UUID?, status: ShiftLifecycleStatus) {
        self.shiftID = shiftID
        self.status = status
    }
}

struct PaydayRestoreParameters: Encodable {
    let ids: [UUID]

    enum CodingKeys: String, CodingKey {
        case ids = "p_ids"
    }
}

/// One `{id, deleted_at}` element of `soft_delete_shifts`' payload. A distinct
/// type rather than a dictionary so the key names are checked at compile time.
struct ShiftDeletionRow: Encodable, Equatable, Sendable {
    let id: UUID
    let deletedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case deletedAt = "deleted_at"
    }
}

/// One page of shift changes, with the snapshot time that page was read at.
///
/// The timestamp and the rows arrive together because
/// `public.fetch_shift_changes` returns them from one statement. Read
/// separately they are two snapshots, and a transaction committing between the
/// two reads with an earlier `updated_at` would be skipped by the cursor
/// forever. That is the whole reason this type exists rather than a plain
/// array.
struct RemoteShiftPage: Decodable, Sendable {
    let serverNow: String
    let rows: [RemoteShift]

    enum CodingKeys: String, CodingKey {
        case serverNow = "server_now"
        case rows
    }
}

/// The parameters `public.fetch_shift_changes` takes.
struct PaydayShiftFeedParameters: Encodable, Sendable {
    let afterUpdatedAt: String?
    let afterID: UUID?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case afterUpdatedAt = "p_after_updated_at"
        case afterID = "p_after_id"
        case limit = "p_limit"
    }
}

/// A shift reduced to exactly the fields a DEVICE can write.
///
/// Deliberately the same set `RemoteShift.encode(to:)` emits, and for the same
/// reason: the fingerprint's job is to detect a local edit worth uploading, so
/// it must cover everything the device can change and nothing it cannot. If it
/// included a server-authored column, a refold or a conversion on the server
/// would make every affected row look locally edited and re-upload the whole
/// history; if it omitted a writable one, an edit to that field would be
/// invisible to the upload set and silently never sync -- which is exactly the
/// `didSet` failure in a different disguise.
struct ShiftBusinessValue: Codable, Equatable, Sendable {
    let id: UUID
    let workDate: String
    let shiftPeriod: String?
    let cashTipsCents: Int
    let creditTipsCents: Int
    let tipOutCents: Int?
    let salesCents: Int?
    let hoursWorked: Double?
    let clockIn: String?
    let clockOut: String?
    let serverCount: Int?
    let receiptMetrics: ShiftReceiptMetrics?
    let note: String?
    let recordedAt: String?
}

extension RemoteShift {
    /// Built from a local record, for upload.
    ///
    /// `workDate` uses the shipped day rendering so no row this build uploads
    /// carries a date the shipped build would not have written; the VERSION
    /// uses `stableDay` instead, via `contentFingerprint(workDate:)`. See
    /// `RemoteTipEntry.businessValue(workDate:)` for why those two are
    /// deliberately different renders of the same instant.
    @MainActor
    init(record: ShiftRecord, userID: UUID) {
        self.init(
            id: record.id,
            userID: userID,
            workDate: PaydayRemoteDate.day(record.workDate),
            shiftPeriod: record.shiftPeriod?.rawValue,
            cashTipsCents: record.cashTipsCents,
            creditTipsCents: record.creditTipsCents,
            tipOutCents: record.tipOutCents,
            salesCents: record.salesCents,
            hoursWorked: record.hoursWorked,
            clockIn: record.clockIn.map(PaydayRemoteDate.instant),
            clockOut: record.clockOut.map(PaydayRemoteDate.instant),
            serverCount: record.serverCount,
            receiptMetrics: record.receiptMetrics,
            note: record.note,
            recordedAt: record.recordedAt.map(PaydayRemoteDate.instant),
            clientUpdatedAt: PaydayRemoteDate.instant(record.modifiedAt),
            // Server-authored, never sent. Nil here rather than copied from
            // the record, so this initializer cannot become a way to forge
            // provenance on the way out.
            source: nil,
            legacyEntryIDs: nil,
            nativeModifiedAt: nil,
            deletedAt: nil,
            deletedReason: nil,
            gratuityFeesCents: nil,
            nonWageEarningsCents: nil,
            version: nil,
            serverUpdatedAt: nil
        )
    }

    func businessValue(workDate: String) -> ShiftBusinessValue {
        ShiftBusinessValue(
            id: id,
            workDate: workDate,
            shiftPeriod: shiftPeriod,
            cashTipsCents: cashTipsCents,
            creditTipsCents: creditTipsCents,
            tipOutCents: tipOutCents,
            salesCents: salesCents,
            hoursWorked: hoursWorked,
            clockIn: PaydayRemoteDate.canonicalInstant(clockIn),
            clockOut: PaydayRemoteDate.canonicalInstant(clockOut),
            serverCount: serverCount,
            receiptMetrics: receiptMetrics,
            note: note,
            recordedAt: PaydayRemoteDate.canonicalInstant(recordedAt)
        )
    }

    var businessValue: ShiftBusinessValue { businessValue(workDate: workDate) }

    /// The right digest for a row decoded FROM the server, whose `workDate` is
    /// already the day string the server holds.
    var contentFingerprint: String {
        get throws { try PaydayMigrationHash.fingerprint(businessValue) }
    }

    func contentFingerprint(workDate: String) throws -> String {
        try PaydayMigrationHash.fingerprint(businessValue(workDate: workDate))
    }
}

/// The account-level conversion record, as the device reads it.
///
/// Decode-only. `public.shift_migration_state` has `sms_read_own` RLS and a
/// `select` grant to `authenticated`, and **no write grant at all** -- only
/// the definer functions write it. So there is no `encode` here and there
/// must never be one: a device asserting its own conversion state is the
/// failure the server-sourced design exists to prevent.
///
/// Four of these columns are the four inputs to
/// `ShiftReadAuthority.isAuthoritative`. The rest of the table is progress
/// and diagnostics the predicate deliberately does not read, which is why
/// this type names the four rather than mirroring the table: a column added
/// later cannot silently change the rule.
struct RemoteShiftMigrationState: Decodable, Equatable, Sendable {
    let userID: UUID
    /// The FIRST conversion instant, never moved by a re-run.
    let migratedAt: String?
    /// Set if the account was rolled back. Authority ends immediately.
    let rollbackAt: String?
    /// Set if the conversion failed its own conservation check.
    let conservationFailedAt: String?
    /// Legacy groups the conversion has not folded yet.
    let remainingGroupCount: Int?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case migratedAt = "migrated_at"
        case rollbackAt = "rollback_at"
        case conservationFailedAt = "conservation_failed_at"
        case remainingGroupCount = "remaining_group_count"
    }

    /// The columns to select. Named explicitly rather than `*` so a column
    /// added to the table does not start arriving unread.
    static let columns = "user_id,migrated_at,rollback_at,conservation_failed_at,remaining_group_count"

    /// A timestamp column that is present but will not parse.
    ///
    /// An error rather than a nil, which is the whole point -- see
    /// `authorityState()`.
    struct UnparseableTimestamp: Error {
        let column: String
        let value: String
    }

    /// The predicate's input, with timestamps parsed once here rather than at
    /// the decision site.
    ///
    /// **Throwing, and that is the fix for a real defect.** The first version
    /// was a computed property doing
    /// `migratedAt.flatMap(PaydayRemoteDate.parseInstant)`, which collapses
    /// two different facts into nil: the column was SQL NULL, and the column
    /// held a string that would not parse.
    ///
    /// `isAuthoritative` opens with `guard state.migratedAt != nil`, so a
    /// parse failure reads as "never converted" -- and on an already-promoted
    /// account that is a DEMOTE. The row EXISTS in that case, so the leg's
    /// absent-row guard does not catch it: that guard closed the ROW-level
    /// collapse and this closes the FIELD-level one.
    ///
    /// The consequence is the severe class. Demoting a promoted account makes
    /// every shift logged SINCE promotion invisible, because those exist only
    /// as `ShiftRecord`s and the legacy view cannot see them -- the
    /// missing-night-looks-like-a-night-not-worked failure
    /// `remainingGroupCount` exists to prevent, arriving through a different
    /// door. And worse than the auth blip in one respect: a format or
    /// precision change on the server would fail to parse on EVERY pass, so
    /// the demotion would be persistent rather than transient.
    ///
    /// Throwing routes it into the leg's existing `catch`, which changes
    /// nothing. So "we failed to read it" and "it isn't set" stay
    /// distinguishable at every level -- the invariant the row-level guard
    /// established, restored at the field level, via the safe path that
    /// already existed rather than a second one.
    func authorityState() throws -> ShiftReadAuthority.State {
        func parse(_ value: String?, _ column: String) throws -> Date? {
            // A genuine SQL NULL. The only thing allowed to mean "absent".
            guard let value else { return nil }
            guard let parsed = PaydayRemoteDate.parseInstant(value) else {
                throw UnparseableTimestamp(column: column, value: value)
            }
            return parsed
        }
        return ShiftReadAuthority.State(
            migratedAt: try parse(migratedAt, "migrated_at"),
            rollbackAt: try parse(rollbackAt, "rollback_at"),
            conservationFailedAt: try parse(conservationFailedAt, "conservation_failed_at"),
            remainingGroupCount: remainingGroupCount
        )
    }
}
