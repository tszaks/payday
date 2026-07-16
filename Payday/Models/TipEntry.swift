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
    var date: Date = Date.now
    var amountCents: Int = 0
    var note: String?
    // Stored as an OPTIONAL raw string, not a defaulted enum: existing
    // on-device rows created before this field have no value, and SwiftData
    // lightweight migration fills a missing optional with nil cleanly —
    // whereas a non-optional enum would crash trying to cast nil to TipKind.
    private var kindRaw: String?

    /// Wall-clock moment the tip was logged (used as a lunch-vs-dinner proxy).
    /// Optional so legacy rows migrate cleanly to nil — they simply show no
    /// time and are skipped by the time-of-day analytics.
    var recordedAt: Date?

    /// Vestigial: doubles are now emergent from shiftID grouping (a day with
    /// 2+ distinct shiftIDs). Retained only for CloudKit schema stability and
    /// interop with older app versions still writing it — a deployed CloudKit
    /// record type can't drop a field. Never read in product logic anymore.
    var isDouble: Bool = false

    /// Groups the rows of ONE closeout (a single shift's cash + credit).
    /// A "shift" is all rows sharing this id; a day is a collection of
    /// shifts; a "double" is emergent (a day with 2+ distinct shiftIDs).
    /// Optional like shiftPeriodRaw: legacy rows migrate to nil, and a
    /// one-time backfill (MigrationRunner) fills them. UUID is a first-class
    /// CloudKit attribute type, so no raw-string trick is needed here.
    var shiftID: UUID?

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
    var hoursWorked: Double?

    /// What got tipped out to bussers/bar/runners this shift, in cents.
    /// Optional for the same reason as hours — "no tip-out logged" and
    /// "tipped out zero" are different facts. When present, NET (gross
    /// minus this) becomes the number this app reports for that night;
    /// see PRODUCT.md's net-vs-gross section.
    var tipOutCents: Int?

    /// Total sales this shift, in cents — lets tip percent (gross tips /
    /// sales) be computed. Optional; only nights that have this get a
    /// tip-percent fact.
    var salesCents: Int?

    /// Clock-in / clock-out for the shift — the input people actually
    /// remember ("I worked 11:30 to 4"), from which hoursWorked is computed
    /// rather than hand-counted. Only the time-of-day component matters
    /// (ShiftTimes measures wrap-aware minutes between the two, so an
    /// overnight closeout works); the stored date part is incidental.
    /// Optional and shift-level like hoursWorked — lives on the one
    /// canonical entry via ShiftDetails, nil for legacy rows.
    var clockIn: Date?
    var clockOut: Date?

    // Same optional-raw-string-to-enum split as kindRaw/kind, but WITHOUT
    // a non-optional fallback: "never set" is a real, meaningful state
    // here (unlike kind, which must always resolve to something), so the
    // accessor stays Optional all the way through.
    private var shiftPeriodRaw: String?

    var shiftPeriod: ShiftPeriod? {
        get { shiftPeriodRaw.flatMap(ShiftPeriod.init(rawValue:)) }
        set { shiftPeriodRaw = newValue?.rawValue }
    }

    /// Gross minus any tip-out — "what you walked with." Equal to
    /// amountCents when there's no tip-out logged for this entry.
    var netCents: Int {
        amountCents - (tipOutCents ?? 0)
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
        clockOut: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.amountCents = amountCents
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
    }
}
