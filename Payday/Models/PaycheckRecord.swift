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

    // Capture-only for now, same treatment as TipEntry's serverCount — on
    // record, exportable someday, no engine analysis yet. Plain optionals
    // like hoursWorked/tipOutCents: "not entered" and "entered as zero" must
    // stay distinguishable facts, never a defaulted non-optional.

    /// The rate printed on the stub — may differ from the Settings wage;
    /// that difference is future signal, never reconciled here.
    var hourlyRateCents: Int?

    /// Tips the employer still owes / held back, not on this check.
    var owedTipsCents: Int?

    /// Stub gross.
    var grossPayCents: Int?

    /// What actually hit the account.
    var netPayCents: Int?

    init(
        id: UUID = UUID(),
        periodStart: Date,
        periodEnd: Date,
        paidTipsCents: Int,
        note: String? = nil,
        hourlyRateCents: Int? = nil,
        owedTipsCents: Int? = nil,
        grossPayCents: Int? = nil,
        netPayCents: Int? = nil
    ) {
        self.id = id
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.paidTipsCents = paidTipsCents
        self.note = note
        self.hourlyRateCents = hourlyRateCents
        self.owedTipsCents = owedTipsCents
        self.grossPayCents = grossPayCents
        self.netPayCents = netPayCents
    }
}
