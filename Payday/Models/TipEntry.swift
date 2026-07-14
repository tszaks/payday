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

    /// Non-optional view of the tip kind; legacy entries with no stored
    /// value read as cash.
    var kind: TipKind {
        get { kindRaw.flatMap(TipKind.init(rawValue:)) ?? .cash }
        set { kindRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), date: Date, amountCents: Int, kind: TipKind = .cash, note: String? = nil) {
        self.id = id
        self.date = date
        self.amountCents = amountCents
        self.kindRaw = kind.rawValue
        self.note = note
    }
}
