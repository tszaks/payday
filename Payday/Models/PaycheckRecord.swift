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

    // MARK: - What used to be computed here, and why nothing is
    //
    // This model carried `reconciledPaidTipsCents`, a computed property that
    // returned the ±100c inference from the stub's gross equation INSTEAD of
    // the stored tips line, and every in-app reader took it: the periods
    // list's delta, period detail's "check paid", and this record's own
    // editor prefill — so opening the sheet and tapping Save wrote the
    // inference over the person's own figure. `MetricID.observedPaidTips` is
    // "the stub field exactly as stored, no inference applied anywhere it is
    // read, exported, or synced", and fixture P1 lists every one of those
    // reads as a wrong answer (10050 where the stub said 10000).
    //
    // The inference lives on `PaycheckReconciler.proposal(for:)` now,
    // labelled "Looks like $100.50 (accept?)" and applied only when a person
    // taps it in `PaycheckEntrySheet`.
    //
    // Nothing derived replaced it, deliberately. A corrected figure this
    // model exposes is a figure four surfaces will read, which is the whole
    // history above; the stored fields below are the observation, and
    // whoever needs to compare them builds one
    // `PaycheckReconciler.Observation` at the point of use.

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
