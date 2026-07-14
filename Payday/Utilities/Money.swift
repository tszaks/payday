import Foundation

enum Money {
    static func string(fromCents cents: Int) -> String {
        let decimal = Decimal(cents) / 100
        return decimal.formatted(.currency(code: "USD"))
    }

    /// Rounds to the nearest dollar — for tight spaces like the calendar
    /// grid where ".00" just eats space without adding information.
    static func wholeDollarString(fromCents cents: Int) -> String {
        let decimal = Decimal(cents) / 100
        return decimal.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}
