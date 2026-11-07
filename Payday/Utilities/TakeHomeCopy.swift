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

    /// Hero: "Check so far · $1,811.34 before tax · about $1,539 after tax".
    static func heroCheckLine(gross: EarningsFigure, net: EarningsFigure) -> String? {
        guard let grossText = gross.text else { return nil }
        var line = "Check so far · \(grossText) before tax"
        if let after = aboutAfterTax(net) { line += " · \(after)" }
        return line
    }

    /// Payday card: "About $1,539 after tax · from 7 stubs", carrying the
    /// figure's whole caption (extrapolation, completeness) after the count.
    static func paydayNetLine(_ net: EarningsFigure) -> String? {
        guard let dollars = wholeDollars(net), let caption = net.caption else { return nil }
        return "About \(dollars) after tax · " + caption.prefix(1).lowercased() + caption.dropFirst()
    }
}

extension DashboardFacts {
    var heroCheckLine: String? { TakeHomeCopy.heroCheckLine(gross: heroCheckGross, net: heroCheckNet) }
    var paydayNetLine: String? { TakeHomeCopy.paydayNetLine(predictedPaycheckNet) }
}
