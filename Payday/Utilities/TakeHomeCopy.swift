import Foundation
import PaydayCore

/// The after-tax copy, in one place, so the three surfaces say it the same
/// way: "about", never "will be"; always "from N stubs"; no percentages.
/// Formatting only — every amount comes from an `EarningsFigure`.
enum TakeHomeCopy {
    /// "$1,539" — the net is a prediction, so cents would be false precision.
    static func wholeDollars(_ figure: EarningsFigure) -> String? {
        figure.cents.map(Money.wholeDollarString(fromCents:))
    }

    /// "about $1,539 after tax", or nil when the figure is unavailable.
    static func aboutAfterTax(_ net: EarningsFigure) -> String? {
        wholeDollars(net).map { "about \($0) after tax" }
    }

    /// Breakdown drawer, under the hero's bottom line: "On your check,
    /// before tax  $G" and "After tax, about  $N", the second in whole
    /// dollars (a prediction) with the net figure's own caption ("From N
    /// stubs …"). No rows when the gross is unavailable; no after-tax row
    /// under 2 stubs.
    ///
    /// These two figures used to sit on the hero's FACE as one caption line
    /// ("Check so far · $G before tax · about $N after tax"). With the
    /// period total and the pace line above it, the card carried four
    /// dollar amounts that answered four different questions and read as a
    /// disagreement (Tyler, 2026-11-07: "Too many conflicting numbers here
    /// - gotta keep it clean"). One number per card; the check goes where
    /// the other itemized facts already are. Both labels are the
    /// registry's (`MetricID.allowedLabels`).
    static func checkRows(gross: EarningsFigure, net: EarningsFigure) -> [BreakdownRow] {
        guard let grossCents = gross.cents else { return [] }
        var rows = [BreakdownRow("On your check, before tax", cents: grossCents)]
        if let netCents = net.cents {
            rows.append(BreakdownRow(net.label, cents: netCents, caption: net.caption, wholeDollars: true))
        }
        return rows
    }

    /// Payday card: "About $1,234 after tax · from 7 stubs", carrying the
    /// figure's whole caption (extrapolation, completeness) after the count.
    static func paydayNetLine(_ net: EarningsFigure) -> String? {
        guard let dollars = wholeDollars(net), let caption = net.caption else { return nil }
        return "About \(dollars) after tax · " + caption.prefix(1).lowercased() + caption.dropFirst()
    }
}

extension DashboardFacts {
    var heroCheckRows: [BreakdownRow] { TakeHomeCopy.checkRows(gross: heroCheckGross, net: heroCheckNet) }
    var paydayNetLine: String? { TakeHomeCopy.paydayNetLine(predictedPaycheckNet) }
}
