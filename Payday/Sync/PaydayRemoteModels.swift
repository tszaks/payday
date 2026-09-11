import CryptoKit
import Foundation

enum PaydayRemoteDate {
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let standardFormatter = ISO8601DateFormatter()

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

enum PaydayMigrationHash {
    static func value<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(value))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
