import Foundation

enum Money {
    static func string(fromCents cents: Int) -> String {
        let decimal = Decimal(cents) / 100
        return decimal.formatted(.currency(code: "USD"))
    }
}
