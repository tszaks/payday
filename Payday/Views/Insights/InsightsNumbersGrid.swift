import Foundation

/// One tile in Insights' BY THE NUMBERS grid: a green uppercase label and a
/// big value. Built from already-computed figures, so it is on screen at
/// once and never waits on the network.
///
/// `context` is nil unless the tile's figure is on a basis different from
/// the page's, and then it names that basis ("of sales"). Counts, sample
/// notes and coverage fractions do not go here (docs/DESIGN.md rule 13: one
/// number, one label).
struct InsightsNumberTile: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let context: String?
}

/// The 2-column stat grid at the foot of Insights. Rows are built
/// explicitly, not flowed from one array, so that DOUBLE DAY and SOLO DAY
/// always land side by side: they come from one `DoublesSoloFacts`, which
/// `StatsEngine` only builds with both sides present.
///
/// Every tile shows only when its data exists. A person who logs only a
/// date and what the shift paid gets the doubles pair at most, and the page
/// reads as complete without the rest.
enum InsightsNumbersGrid {
    /// A count stops being a warning and starts being noise at this many
    /// shifts. The typical-range rows and the week-ahead rows show a thin
    /// sample's count below it and nothing at or above it (Tyler,
    /// 2026-11-08). The tiles here show no counts at all.
    static let minimumShiftsForFullSample = 8

    /// - Parameters:
    ///   - hourly: `MetricID.hourlyRate` as the ENGINE answered it, from
    ///     `InsightsEarnings.hourlyRate(...)`, never a division here. Nil
    ///     when the engine cannot answer, and then the tile is absent, never
    ///     a fabricated `$0/hr`.
    static func rows(
        for facts: InsightsFacts,
        hourly: InsightsEarnings.HourlyRate?
    ) -> [[InsightsNumberTile]] {
        var rows: [[InsightsNumberTile]] = []

        var rateRow: [InsightsNumberTile] = []
        if let hourly {
            rateRow.append(hourlyTile(hourly))
        }
        if let sales = facts.sales {
            rateRow.append(tipPercentTile(sales))
        }
        if !rateRow.isEmpty { rows.append(rateRow) }

        if let doublesSolo = facts.doublesSolo {
            rows.append([doublesTile(doublesSolo), soloTile(doublesSolo)])
        }

        return rows
    }

    private static func hourlyTile(_ hourly: InsightsEarnings.HourlyRate) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "hourly",
            label: "PER HOUR",
            value: "\(Money.wholeDollarString(fromCents: hourly.rateCents))/hr",
            context: nil
        )
    }

    /// Gross tips over sales: not the page basis (a wage is not a tip), so
    /// it names its own.
    private static func tipPercentTile(_ sales: SalesFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "tipPercent",
            label: "TIP PERCENT",
            value: "\(String(format: "%.1f", sales.overallTipPercent))%",
            context: "of sales"
        )
    }

    /// Per shift on a double day, so it compares with SOLO DAY beside it.
    private static func doublesTile(_ facts: DoublesSoloFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "doubles",
            label: "DOUBLE DAY",
            value: "\(Money.wholeDollarString(fromCents: facts.doublePerShiftCents))/shift",
            context: nil
        )
    }

    /// A solo day is one shift, so the day average already IS the per-shift
    /// figure.
    private static func soloTile(_ facts: DoublesSoloFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "solo",
            label: "SOLO DAY",
            value: "\(Money.wholeDollarString(fromCents: facts.soloAverageCents))/shift",
            context: nil
        )
    }
}
