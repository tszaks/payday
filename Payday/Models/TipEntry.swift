import Foundation
import SwiftData

@Model
final class TipEntry {
    var id: UUID
    var date: Date
    var amountCents: Int
    var note: String?

    init(id: UUID = UUID(), date: Date, amountCents: Int, note: String? = nil) {
        self.id = id
        self.date = date
        self.amountCents = amountCents
        self.note = note
    }
}
