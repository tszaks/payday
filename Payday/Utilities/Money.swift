import Foundation

enum Money {
    static func string(fromCents cents: Int) -> String {
        let decimal = Decimal(cents) / 100
        return decimal.formatted(.currency(code: "USD"))
    }

    /// Compact comparison: direction stays readable even in monochrome widgets.
    static func directionalDeltaString(fromCents cents: Int) -> String {
        let magnitude = (Decimal(cents.magnitude) / 100).formatted(.currency(code: "USD"))
        if cents < 0 { return "↓ \(magnitude)" }
        if cents > 0 { return "↑ \(magnitude)" }
        return magnitude
    }

    /// Rounds to the nearest dollar — for tight spaces like the calendar
    /// grid where ".00" just eats space without adding information.
    static func wholeDollarString(fromCents cents: Int) -> String {
        let decimal = Decimal(cents) / 100
        return decimal.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}
