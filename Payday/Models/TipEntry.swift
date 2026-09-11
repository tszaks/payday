import Foundation
import SwiftData

/// How a tip came in. Cash is walked with the same night; credit/card tips
/// are what land on the paycheck stub — that distinction drives the paycheck
/// comparison and the cash-vs-credit breakdowns.
enum TipKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case cash
    case credit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cash: "Cash"
        case .credit: "Credit"
        }
    }
}

/// Which half of the day a shift fell in — the defining period of one
/// closeout. Captured explicitly at log time now; nil means never set
/// (legacy rows), which the engine only ever fills in with the same-day
/// recordedAt proxy, never guesses at directly. A double day is simply two
/// shifts, e.g. a lunch shift plus a dinner shift.
enum ShiftPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case lunch
    case dinner

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        }
    }
}

@Model
final class TipEntry {
    // CloudKit requires every attribute to be optional or have a default —
    // its record model has no concept of a required field. These three
    // were always required in practice (the init below still sets them on
    // every real insert); the defaults only matter for CloudKit's schema
    // validation and for synthesizing a value if a sync ever raced a write.
    var id: UUID = UUID()
    var date: Date = Date.now { didSet { modifiedAt = .now } }
    var amountCents: Int = 0 { didSet { modifiedAt = .now } }
    /// Local mutation timestamp used only to order offline writes during the
    /// CloudKit-to-Supabase transition. Supabase's updated_at remains the
    /// authoritative server timestamp after a write is accepted.
    var modifiedAt: Date = Date.now
    var note: String? { didSet { modifiedAt = .now } }
    // Stored as an OPTIONAL raw string, not a defaulted enum: existing
    // on-device rows created before this field have no value, and SwiftData
    // lightweight migration fills a missing optional with nil cleanly —
    // whereas a non-optional enum would crash trying to cast nil to TipKind.
    private var kindRaw: String? { didSet { modifiedAt = .now } }

    /// Wall-clock moment the tip was logged (used as a lunch-vs-dinner proxy).
    /// Optional so legacy rows migrate cleanly to nil — they simply show no
    /// time and are skipped by the time-of-day analytics.
    var recordedAt: Date? { didSet { modifiedAt = .now } }

    /// Vestigial: doubles are now emergent from shiftID grouping (a day with
    /// 2+ distinct shiftIDs). Retained only for CloudKit schema stability and
    /// interop with older app versions still writing it — a deployed CloudKit
    /// record type can't drop a field. Never read in product logic anymore.
    var isDouble: Bool = false { didSet { modifiedAt = .now } }

    /// Groups the rows of ONE closeout (a single shift's cash + credit).
    /// A "shift" is all rows sharing this id; a day is a collection of
    /// shifts; a "double" is emergent (a day with 2+ distinct shiftIDs).
    /// Optional like shiftPeriodRaw: legacy rows migrate to nil, and a
    /// one-time backfill (MigrationRunner) fills them. UUID is a first-class
    /// CloudKit attribute type, so no raw-string trick is needed here.
    var shiftID: UUID? { didSet { modifiedAt = .now } }

    /// Non-optional view of the tip kind; legacy entries with no stored
    /// value read as cash.
    var kind: TipKind {
        get { kindRaw.flatMap(TipKind.init(rawValue:)) ?? .cash }
        set { kindRaw = newValue.rawValue }
    }

    /// Hours worked this shift, half-hour granularity is plenty.
    /// Optional and meant to stay that way — "not entered" and "worked
    /// zero hours" must stay distinguishable, so this is never a defaulted
    /// non-optional. $/hr facts only ever compute over nights that HAVE
    /// this; never fabricated for the rest.
    var hoursWorked: Double? { didSet { modifiedAt = .now } }

    /// What got tipped out to bussers/bar/runners this shift, in cents.
    /// Optional for the same reason as hours — "no tip-out logged" and
    /// "tipped out zero" are different facts. When present, NET (gross
    /// minus this) becomes the number this app reports for that night;
    /// see PRODUCT.md's net-vs-gross section.
    var tipOutCents: Int? { didSet { modifiedAt = .now } }

    /// Total sales this shift, in cents — lets tip percent (gross tips /
    /// sales) be computed. Optional; only nights that have this get a
    /// tip-percent fact.
    var salesCents: Int? { didSet { modifiedAt = .now } }

    /// Clock-in / clock-out for the shift — the input people actually
    /// remember ("I worked 11:30 to 4"), from which hoursWorked is computed
    /// rather than hand-counted. Only the time-of-day component matters
    /// (ShiftTimes measures wrap-aware minutes between the two, so an
    /// overnight closeout works); the stored date part is incidental.
    /// Optional and shift-level like hoursWorked — lives on the one
    /// canonical entry via ShiftDetails, nil for legacy rows.
    var clockIn: Date? { didSet { modifiedAt = .now } }
    var clockOut: Date? { didSet { modifiedAt = .now } }

    /// How many servers were on the floor this shift — capture-only for
    /// now, no engine analysis yet (that comes once there's enough data to
    /// make a floor-size claim honestly). Floor size changes section size
    /// and split economics, so it's worth having on record early. Optional
    /// and shift-level like hoursWorked: "not entered" and "zero servers"
    /// are different facts, and it lives on the one canonical entry via
    /// ShiftDetails, nil for legacy rows.
    var serverCount: Int? { didSet { modifiedAt = .now } }

    /// Detailed printed facts captured from an end-of-shift receipt. Stored
    /// as optional JSON so this private, CloudKit-backed model gains one
    /// additive field instead of a column for every receipt label.
    var receiptMetricsJSON: String? { didSet { modifiedAt = .now } }

    var receiptMetrics: ShiftReceiptMetrics? {
        get {
            guard let receiptMetricsJSON,
                  let data = receiptMetricsJSON.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode(ShiftReceiptMetrics.self, from: data)
        }
        set {
            guard let newValue, !newValue.isEmpty,
                  let data = try? JSONEncoder().encode(newValue)
            else {
                receiptMetricsJSON = nil
                return
            }
            receiptMetricsJSON = String(data: data, encoding: .utf8)
        }
    }

    // Same optional-raw-string-to-enum split as kindRaw/kind, but WITHOUT
    // a non-optional fallback: "never set" is a real, meaningful state
    // here (unlike kind, which must always resolve to something), so the
    // accessor stays Optional all the way through.
    private var shiftPeriodRaw: String? { didSet { modifiedAt = .now } }

    var shiftPeriod: ShiftPeriod? {
        get { shiftPeriodRaw.flatMap(ShiftPeriod.init(rawValue:)) }
        set { shiftPeriodRaw = newValue?.rawValue }
    }

    /// This row's voluntary tips plus any canonical employee gratuity/fees,
    /// minus any canonical tip-out. Shift-level receipt data lives on only
    /// one row, so summing `netCents` across a shift counts it exactly once.
    var netCents: Int {
        (receiptMetrics?.employeeEarningsCents(fromStoredAmount: amountCents) ?? amountCents)
            - (tipOutCents ?? 0)
    }

    init(
        id: UUID = UUID(),
        date: Date,
        amountCents: Int,
        kind: TipKind = .cash,
        note: String? = nil,
        recordedAt: Date? = nil,
        isDouble: Bool = false,
        hoursWorked: Double? = nil,
        tipOutCents: Int? = nil,
        salesCents: Int? = nil,
        shiftPeriod: ShiftPeriod? = nil,
        shiftID: UUID? = nil,
        clockIn: Date? = nil,
        clockOut: Date? = nil,
        serverCount: Int? = nil,
        receiptMetrics: ShiftReceiptMetrics? = nil
    ) {
        self.id = id
        self.date = date
        self.amountCents = amountCents
        self.modifiedAt = recordedAt ?? .now
        self.kindRaw = kind.rawValue
        self.note = note
        self.recordedAt = recordedAt
        self.isDouble = isDouble
        self.hoursWorked = hoursWorked
        self.tipOutCents = tipOutCents
        self.salesCents = salesCents
        self.shiftPeriodRaw = shiftPeriod?.rawValue
        self.shiftID = shiftID
        self.clockIn = clockIn
        self.clockOut = clockOut
        self.serverCount = serverCount
        self.receiptMetrics = receiptMetrics
    }
}
