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
    /// Local mutation timestamp used to order offline writes while existing
    /// device data is imported into Supabase. Advanced by `init` and by
    /// `touch()` — never by a property observer.
    var modifiedAt: Date = Date.now
    var note: String?

    // Capture-only for now, same treatment as TipEntry's serverCount — on
    // record, exportable someday, no engine analysis yet. Plain optionals
    // like hoursWorked/tipOutCents: "not entered" and "entered as zero" must
    // stay distinguishable facts, never a defaulted non-optional.

    /// The rate printed on the stub — may differ from the Settings wage;
    /// that difference is future signal, never reconciled here. Retired
    /// from the entry sheet's UI (2026-07-27, superseded by the wages/
    /// gross/net audit fields below) but kept on the model — a deployed
    /// CloudKit record type can't drop a field, and legacy records still
    /// carry this.
    var hourlyRateCents: Int?

    /// Tips the employer still owes / held back, not on this check. Retired
    /// from the entry sheet's UI (2026-07-27) for the same CloudKit-schema-
    /// stability reason as hourlyRateCents.
    var owedTipsCents: Int?

    /// Stub gross.
    var grossPayCents: Int?

    /// What actually hit the account.
    var netPayCents: Int?

    /// Base pay for the period, as printed on the stub — the audit's
    /// ground truth is PeriodIncome's computed wages, this is what the
    /// employer actually paid.
    var regularWagesCents: Int?

    /// Overtime pay for the period, as printed on the stub.
    var overtimeWagesCents: Int?

    /// Gratuity owed on the stub, separate from tips.
    var gratuityCents: Int?

    /// Taxes withheld, as printed on the stub.
    var taxesCents: Int?

    /// Repairs only cent-level OCR drift that the complete earnings equation
    /// can prove. The stored value remains reviewable; opening and saving the
    /// editor persists the reconciled value.
    var reconciledPaidTipsCents: Int {
        Self.reconciledTipsCents(
            tipsCents: paidTipsCents,
            regularWagesCents: regularWagesCents,
            overtimeWagesCents: overtimeWagesCents,
            gratuityCents: gratuityCents,
            grossPayCents: grossPayCents
        )
    }

    static func reconciledTipsCents(
        tipsCents: Int,
        regularWagesCents: Int?,
        overtimeWagesCents: Int?,
        gratuityCents: Int?,
        grossPayCents: Int?
    ) -> Int {
        guard let regularWagesCents, let grossPayCents else { return tipsCents }
        let inferredTipsCents = grossPayCents
            - regularWagesCents
            - (overtimeWagesCents ?? 0)
            - (gratuityCents ?? 0)
        let correctionCents = inferredTipsCents - tipsCents
        guard inferredTipsCents >= 0,
              correctionCents != 0,
              abs(correctionCents) <= 100
        else { return tipsCents }
        return inferredTipsCents
    }

    init(
        id: UUID = UUID(),
        periodStart: Date,
        periodEnd: Date,
        paidTipsCents: Int,
        note: String? = nil,
        hourlyRateCents: Int? = nil,
        owedTipsCents: Int? = nil,
        grossPayCents: Int? = nil,
        netPayCents: Int? = nil,
        regularWagesCents: Int? = nil,
        overtimeWagesCents: Int? = nil,
        gratuityCents: Int? = nil,
        taxesCents: Int? = nil
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
        self.regularWagesCents = regularWagesCents
        self.overtimeWagesCents = overtimeWagesCents
        self.gratuityCents = gratuityCents
        self.taxesCents = taxesCents
    }

    /// Advances `modifiedAt`, the clock the sync layer uploads as
    /// `client_updated_at`. Call it from every write path that changes a
    /// synced field on an existing record.
    ///
    /// This replaced twelve `didSet { modifiedAt = .now }` observers on this
    /// model that never ran, for the reason measured and written up on
    /// `TipEntry.touch(at:)`: SwiftData's `@Model` macro rewrites a stored
    /// property into computed accessors, so a `didSet` on one is dead code.
    /// Do not restore them.
    func touch(at date: Date = .now) {
        modifiedAt = date
    }
}
