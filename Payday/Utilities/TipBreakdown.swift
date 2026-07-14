import Foundation

/// Single source of truth for splitting a set of tip entries into cash vs
/// credit vs total. Pure and standalone so views never re-derive the split
/// inline and it stays unit-testable.
struct TipBreakdown: Equatable {
    var cashCents: Int
    var creditCents: Int

    var totalCents: Int { cashCents + creditCents }

    static let zero = TipBreakdown(cashCents: 0, creditCents: 0)

    static func total(of entries: [TipEntry]) -> TipBreakdown {
        entries.reduce(into: .zero) { result, entry in
            switch entry.kind {
            case .cash: result.cashCents += entry.amountCents
            case .credit: result.creditCents += entry.amountCents
            }
        }
    }
}
