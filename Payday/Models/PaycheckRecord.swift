import Foundation
import SwiftData

@Model
final class PaycheckRecord {
    // Same CloudKit-driven default-value pass as TipEntry — every attribute
    // needs a default since CloudKit's record model has no required fields.
    var id: UUID = UUID()
    var periodStart: Date = Date.now
    var periodEnd: Date = Date.now
    var paidTipsCents: Int = 0
    var note: String?

    init(id: UUID = UUID(), periodStart: Date, periodEnd: Date, paidTipsCents: Int, note: String? = nil) {
        self.id = id
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.paidTipsCents = paidTipsCents
        self.note = note
    }
}
