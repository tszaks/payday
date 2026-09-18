import CryptoKit
import Foundation

enum PaydayRemoteDate {
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let standardFormatter = ISO8601DateFormatter()

    /// The one calendar `stableDay` renders in. Fixed at UTC on purpose: see
    /// `stableDay`.
    nonisolated(unsafe) private static let fixedDayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// The calendar day a stored date names, as a pure function of the instant
    /// — it does not depend on where the device is now. Used for VERSIONING a
    /// local row, never for the wire value (see `RemoteTipEntry.businessValue`
    /// for why those are deliberately separate).
    ///
    /// Every date this app persists is local midnight in whatever zone the row
    /// was written in: `Calendar.current.startOfDay(...)` in ShiftWriter,
    /// LogTipSheet and `PayPeriodCalculator.period(containing:)`, or
    /// `parseDay` (which lands on local midnight too) on reconcile. Rendering
    /// such an instant back through `Calendar.current` is only correct while
    /// the device stays in the zone that wrote it: seen from any zone further
    /// west, midnight belongs to the PREVIOUS day. That is fatal for a version
    /// — `work_date` is inside the row's content fingerprint — because it
    /// would move every fingerprint in the history the first time the device
    /// flew west and put the whole history in the upload set with no user
    /// edit.
    ///
    /// No function of the instant alone can recover the intended day
    /// everywhere: inhabited UTC offsets span 25 hours (-11 through +14), so
    /// two different days collide. Midnight on Sep 5 in Kiritimati (UTC+14)
    /// and midnight on Sep 4 in Honolulu (UTC-10) are the SAME instant, and
    /// nothing stored in the row says which zone wrote it. So this picks a
    /// 24-hour window and names it: anchoring 13.5 hours past the stored
    /// instant and rendering in UTC returns the intended day for every offset
    /// in (UTC-10:30, UTC+13:30] — the Americas through New Zealand in summer
    /// time — with half an hour of slack at each edge for zones whose DST
    /// transition happens at midnight, where `startOfDay` lands at 01:00.
    ///
    /// Outside that window (UTC-11 and UTC+14, jointly under 60,000 people)
    /// this names the adjacent day. That costs a row one redundant upload of
    /// unchanged content on the seeding sync and nothing after, because the
    /// wire value is rendered separately and stays correct. A genuine date
    /// edit is a full 24 hours away, so it moves the digest from every zone.
    static func stableDay(_ date: Date) -> String {
        day(date.addingTimeInterval(13.5 * 3_600), calendar: fixedDayCalendar)
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    static func instant(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    static func parseDay(_ value: String, calendar: Calendar = .current) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func parseInstant(_ value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
    }

    static func canonicalInstant(_ value: String?) -> String? {
        value.flatMap(parseInstant).map(instant)
    }
}

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
        get throws { try PaydayMigrationHash.value(businessValue) }
    }

    func contentFingerprint(workDate: String) throws -> String {
        try PaydayMigrationHash.value(businessValue(workDate: workDate))
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
        get throws { try PaydayMigrationHash.value(businessValue) }
    }

    func contentFingerprint(periodStart: String, periodEnd: String) throws -> String {
        try PaydayMigrationHash.value(
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
        case clientUpdatedAt = "client_updated_at"
        case serverUpdatedAt = "updated_at"
    }

    @MainActor
    init(
        userID: UUID,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore
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
}

enum PaydayMigrationHash {
    static func value<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(value))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
