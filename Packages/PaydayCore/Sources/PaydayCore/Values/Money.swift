import Foundation

/// The first symbol to live in PaydayCore (PR 0 of the earnings-engine
/// consolidation — see docs/METRICS.md and docs/CI.md). PaydayCore is a
/// pure-Foundation package: it must never import SwiftUI, SwiftData, UIKit,
/// or WidgetKit, so it can be linked identically into the app process and
/// the widget extension process and, eventually, tested headless with
/// `swift test` and no simulator.
public enum Money {
    public static func string(fromCents cents: Int) -> String {
        let decimal = Decimal(cents) / 100
        return decimal.formatted(.currency(code: "USD"))
    }

    /// Compact comparison: direction stays readable even in monochrome widgets.
    public static func directionalDeltaString(fromCents cents: Int) -> String {
        let magnitude = (Decimal(cents.magnitude) / 100).formatted(.currency(code: "USD"))
        if cents < 0 { return "↓ \(magnitude)" }
        if cents > 0 { return "↑ \(magnitude)" }
        return magnitude
    }

    /// Rounds to the nearest dollar — for tight spaces like the calendar
    /// grid where ".00" just eats space without adding information.
    public static func wholeDollarString(fromCents cents: Int) -> String {
        let decimal = Decimal(cents) / 100
        return decimal.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}
