import Foundation

/// Single source of truth for splitting a set of shift entries into voluntary
/// cash/credit tips, employee gratuity/fees, tip-out, and net earnings. Pure
/// and standalone so views never re-derive the split inline and it stays
/// unit-testable.
///
/// Toast reports mandatory gratuity as non-tip employee income. Payday keeps
/// that category separate for payroll reconciliation, while treating it as
/// tip-like earnings in operational analytics because it replaces the normal
/// guest tip. `grossTotalCents` remains the voluntary portion for the stub's
/// Tips line; `earnedBeforeTipOutCents` is the effective tip earnings total.
/// A tip-out is money that passed through the server to bussers/bar/runners,
/// so it is subtracted once from the combined shift earnings.
struct TipBreakdown: Equatable {
    var cashCents: Int
    var creditCents: Int
    var tipOutCents: Int
    var gratuityFeesCents: Int

    init(cashCents: Int, creditCents: Int, tipOutCents: Int, gratuityFeesCents: Int = 0) {
        self.cashCents = cashCents
        self.creditCents = creditCents
        self.tipOutCents = tipOutCents
        self.gratuityFeesCents = gratuityFeesCents
    }

    /// Gross voluntary tips only. Mandatory gratuity is intentionally separate.
    var grossTotalCents: Int { cashCents + creditCents }

    /// Effective tip earnings before tip-out: voluntary tips plus auto-grat.
    var earnedBeforeTipOutCents: Int { grossTotalCents + gratuityFeesCents }

    /// Net shift earnings: voluntary tips + employee gratuity/fees - tip-out.
    var netTotalCents: Int { earnedBeforeTipOutCents - tipOutCents }

    static let zero = TipBreakdown(cashCents: 0, creditCents: 0, tipOutCents: 0)

    static func total(of entries: [TipEntry]) -> TipBreakdown {
        let shifts = ShiftDays.groupedByShift(
            entries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod
        )

        return shifts.reduce(into: .zero) { result, shift in
            let details = ShiftDetails.resolve(from: shift.items)
            let credit = shift.items.first { $0.kind == .credit }
            let cash = shift.items.first { $0.kind == .cash }
            let metricsOwner = credit?.receiptMetrics != nil ? credit : (cash?.receiptMetrics != nil ? cash : nil)

            for entry in shift.items {
                // Receipt metrics describe the whole closeout and belong to
                // one canonical entry. Apply legacy combined-tip
                // normalization only to that owner; a duplicated payload on
                // a corrupted secondary row must not subtract gratuity twice.
                let metrics = entry.id == metricsOwner?.id ? details.receiptMetrics : nil
                let voluntaryCents = metrics?.voluntaryTipsCents(fromStoredAmount: entry.amountCents) ?? entry.amountCents
                switch entry.kind {
                case .cash: result.cashCents += voluntaryCents
                case .credit: result.creditCents += voluntaryCents
                }
            }

            result.tipOutCents += details.tipOutCents ?? 0
            result.gratuityFeesCents += details.receiptMetrics?.employeeGratuityFeesCents ?? 0
        }
    }
}
