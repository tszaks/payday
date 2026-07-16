import Foundation

/// Single source of truth for splitting a set of tip entries into cash vs
/// credit, tip-out, and net. Pure and standalone so views never re-derive the
/// split inline and it stays unit-testable.
///
/// Net (`netTotalCents`) is the number the app shows as income everywhere:
/// a tip-out is money that passed through the server to bussers/bar/runners,
/// not earnings, so it never counts toward "what you made." Gross cash/credit
/// stay available for the reference subtitle and for the paycheck comparison
/// (a stub reports gross credit tips, a separate question from income).
struct TipBreakdown: Equatable {
    var cashCents: Int
    var creditCents: Int
    var tipOutCents: Int

    /// Gross: what came in before tipping out.
    var grossTotalCents: Int { cashCents + creditCents }

    /// Net: what you actually kept. The income number.
    var netTotalCents: Int { grossTotalCents - tipOutCents }

    static let zero = TipBreakdown(cashCents: 0, creditCents: 0, tipOutCents: 0)

    static func total(of entries: [TipEntry]) -> TipBreakdown {
        entries.reduce(into: .zero) { result, entry in
            switch entry.kind {
            case .cash: result.cashCents += entry.amountCents
            case .credit: result.creditCents += entry.amountCents
            }
            result.tipOutCents += entry.tipOutCents ?? 0
        }
    }
}
