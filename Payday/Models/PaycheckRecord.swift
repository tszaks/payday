import Foundation
import SwiftData

@Model
final class PaycheckRecord {
    var id: UUID
    var periodStart: Date
    var periodEnd: Date
    var paidTipsCents: Int
    var note: String?

    init(id: UUID = UUID(), periodStart: Date, periodEnd: Date, paidTipsCents: Int, note: String? = nil) {
        self.id = id
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.paidTipsCents = paidTipsCents
        self.note = note
    }
}
