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

@Model
final class TipEntry {
    var id: UUID
    var date: Date
    var amountCents: Int
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

    /// User-declared, never inferred: whether this was a double (worked two
    /// shifts that day). A Bool with a default lightweight-migrates cleanly,
    /// unlike the enum trick above — legacy rows just read false.
    var isDouble: Bool = false

    /// Non-optional view of the tip kind; legacy entries with no stored
    /// value read as cash.
    var kind: TipKind {
        get { kindRaw.flatMap(TipKind.init(rawValue:)) ?? .cash }
        set { kindRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), date: Date, amountCents: Int, kind: TipKind = .cash, note: String? = nil, recordedAt: Date? = nil, isDouble: Bool = false) {
        self.id = id
        self.date = date
        self.amountCents = amountCents
        self.kindRaw = kind.rawValue
        self.note = note
        self.recordedAt = recordedAt
        self.isDouble = isDouble
    }
}
