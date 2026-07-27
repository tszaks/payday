/// The seven cards of LogTipSheet's creation-mode deck, in the fixed order
/// they page through. Pure — no SwiftUI — so the order and titles are
/// unit-testable independent of the view that renders them.
enum CardFlowStep: Int, CaseIterable, Identifiable {
    case tips
    case shift
    case times
    case tipOut
    case sales
    case servers
    case note

    var id: Int { rawValue }

    /// The small-caps kicker printed at the top of the card.
    var kicker: String {
        switch self {
        case .tips: "TIPS"
        case .shift: "SHIFT"
        case .times: "TIMES"
        case .tipOut: "TIP-OUT"
        case .sales: "SALES"
        case .servers: "SERVERS"
        case .note: "NOTE"
        }
    }

    /// Sentence-case title used in the VoiceOver group label ("Tips, card 1
    /// of 7") — the kicker itself is styled for sighted display, not speech.
    var accessibilityTitle: String {
        switch self {
        case .tips: "Tips"
        case .shift: "Shift"
        case .times: "Times"
        case .tipOut: "Tip-out"
        case .sales: "Sales"
        case .servers: "Servers"
        case .note: "Note"
        }
    }
}
