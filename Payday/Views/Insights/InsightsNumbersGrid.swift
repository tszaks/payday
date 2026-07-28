import Foundation

/// One tile in Insights' Numbers grid — a green uppercase label, a big
/// value, and a short context line. Built straight off InsightsFacts, never
/// off narration, so it's on screen instantly and never waits on the
/// network.
struct InsightsNumberTile: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let context: String
}

/// The flat 2-column stat grid that replaced Insights' content-dump prose.
/// Rows are computed explicitly, not flowed from one long array, because
/// the LUNCH/DINNER and DOUBLES/SOLO pairs must land side by side and a
/// flowing grid can't guarantee that: any independent single tile ahead of
/// a pair (hourly, say, when tip percent isn't available) would shift
/// parity and split the pair across two rows. Each pair is safe as its own
/// row anyway, since it's sourced from one InsightsFacts sub-struct that
/// StatsEngine only ever populates with both sides present (see
/// lunchDinnerFacts/doublesSoloFacts's own guards).
enum InsightsNumbersGrid {
    /// Matches the early-read hedge InsightsService's prompt enforces for
    /// narration, applied here too since the grid makes the same claims.
    private static let earlyReadSuffix = " · early read"
    /// A tile's own sample count stops earning a place in its caption once
    /// it clears this bar — below it, the count IS the honesty signal
    /// (design law: every number states its basis when the basis is thin)
    /// and must survive; at or above it, restating "across 160 shifts" on
    /// every tile just repeats the same fact and says nothing new. Same
    /// calibration as StatsEngine.MoveThresholds.minimumShiftsForAnnualizedImpact,
    /// applied here to captions instead of Moves' dollar projections.
    private static let minimumShiftsForFullSample = 8

    static func rows(for facts: InsightsFacts) -> [[InsightsNumberTile]] {
        var rows: [[InsightsNumberTile]] = []

        var rateRow: [InsightsNumberTile] = []
        if let rate = facts.rate {
            rateRow.append(hourlyTile(rate))
        }
        if let sales = facts.sales {
            rateRow.append(tipPercentTile(sales))
        }
        if !rateRow.isEmpty { rows.append(rateRow) }

        if let lunchDinner = facts.lunchDinner {
            rows.append([lunchTile(lunchDinner), dinnerTile(lunchDinner)])
        }

        if let doublesSolo = facts.doublesSolo {
            rows.append([doublesTile(doublesSolo), soloTile(doublesSolo)])
        }

        if let cashWeekday = facts.cashWeekday {
            rows.append([cashNightsTile(cashWeekday)])
        }

        if let startTime = facts.startTime {
            rows.append([startTimesTile(startTime)])
        }

        return rows
    }

    private static func hourlyTile(_ rate: RateFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "hourly",
            label: "HOURLY",
            value: "\(Money.wholeDollarString(fromCents: Int((rate.overallDollarsPerHour * 100).rounded())))/hr",
            context: hedged("", count: rate.nightsWithHours, countPhrase: "across \(shiftsPhrase(rate.nightsWithHours))")
        )
    }

    private static func tipPercentTile(_ sales: SalesFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "tipPercent",
            label: "TIP PERCENT",
            value: "\(String(format: "%.1f", sales.overallTipPercent))%",
            context: hedged("of sales", count: sales.nightsWithSales, countPhrase: shiftsPhrase(sales.nightsWithSales))
        )
    }

    /// Per-shift average, never the raw total — the shift counts differ
    /// between lunch and dinner, same rule InsightsFactsCopy follows.
    private static func lunchTile(_ facts: LunchDinnerFacts) -> InsightsNumberTile {
        let average = facts.lunchCents / facts.lunchShiftCount
        return InsightsNumberTile(
            id: "lunch",
            label: "LUNCH",
            value: "\(Money.wholeDollarString(fromCents: average))/shift",
            context: hedged("", count: facts.lunchShiftCount, countPhrase: shiftsPhrase(facts.lunchShiftCount))
        )
    }

    private static func dinnerTile(_ facts: LunchDinnerFacts) -> InsightsNumberTile {
        let average = facts.dinnerCents / facts.dinnerShiftCount
        return InsightsNumberTile(
            id: "dinner",
            label: "DINNER",
            value: "\(Money.wholeDollarString(fromCents: average))/shift",
            context: hedged("", count: facts.dinnerShiftCount, countPhrase: shiftsPhrase(facts.dinnerShiftCount))
        )
    }

    private static func doublesTile(_ facts: DoublesSoloFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "doubles",
            label: "DOUBLES",
            value: "\(Money.wholeDollarString(fromCents: facts.doublePerShiftCents))/shift",
            context: hedged("", count: facts.doubleCount, countPhrase: doubleDaysPhrase(facts.doubleCount))
        )
    }

    /// A solo day is one shift, so the day average already IS the per-shift
    /// figure — no division needed, unlike doublePerShiftCents above.
    private static func soloTile(_ facts: DoublesSoloFacts) -> InsightsNumberTile {
        InsightsNumberTile(
            id: "solo",
            label: "ONE SHIFT",
            value: "\(Money.wholeDollarString(fromCents: facts.soloAverageCents))/shift",
            context: hedged("", count: facts.soloCount, countPhrase: daysPhrase(facts.soloCount))
        )
    }

    /// The one cash fact Insights ever shows — a weekday that runs
    /// meaningfully more cash than the rest of the week (see
    /// StatsEngine.CashWeekdayFacts). Never a cash-vs-credit split.
    private static func cashNightsTile(_ facts: CashWeekdayFacts) -> InsightsNumberTile {
        let weekdayName = Calendar.current.weekdaySymbols[facts.weekday - 1]
        return InsightsNumberTile(
            id: "cashNights",
            label: "CASH NIGHTS",
            value: "\(Int(facts.sharePercent.rounded()))%",
            context: "of \(weekdayName) tips are cash · \(weekdayPhrase(facts.nightCount, name: weekdayName))"
        )
    }

    private static func weekdayPhrase(_ count: Int, name: String) -> String {
        count == 1 ? "1 \(name)" : "\(count) \(name)s"
    }

    private static func startTimesTile(_ facts: StartTimeFacts) -> InsightsNumberTile {
        let bestRate = Money.wholeDollarString(fromCents: Int((facts.bestDollarsPerHour * 100).rounded()))
        let worstRate = Money.wholeDollarString(fromCents: Int((facts.worstDollarsPerHour * 100).rounded()))
        let sampleCount = min(facts.bestShiftCount, facts.worstShiftCount)
        return InsightsNumberTile(
            id: "startTimes",
            label: "START TIMES",
            value: "\(bestRate)/hr at \(hourLabel(facts.bestStartHour))",
            context: hedged("vs \(worstRate)/hr at \(hourLabel(facts.worstStartHour))", count: sampleCount, countPhrase: shiftsPhrase(sampleCount))
        )
    }

    /// Builds a tile's caption from a non-count context (e.g. "of sales",
    /// or "" when a tile has nothing else to say) and the count phrase that
    /// backs it. Below minimumShiftsForFullSample, the count phrase
    /// survives (further flagged as an early read below 3); at or above
    /// it, only the non-count context remains.
    private static func hedged(_ nonCountContext: String, count: Int, countPhrase: String) -> String {
        guard count < minimumShiftsForFullSample else { return nonCountContext }
        let withCount = nonCountContext.isEmpty ? countPhrase : "\(nonCountContext) · \(countPhrase)"
        return count < 3 ? withCount + earlyReadSuffix : withCount
    }

    private static func shiftsPhrase(_ count: Int) -> String {
        count == 1 ? "1 shift" : "\(count) shifts"
    }

    private static func daysPhrase(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    private static func doubleDaysPhrase(_ count: Int) -> String {
        count == 1 ? "1 double day" : "\(count) double days"
    }

    /// Same locale-respecting rendering as StatsEngine's own hourLabel — an
    /// actual Date at that hour, formatted by Date.FormatStyle rather than
    /// hand-rolled am/pm math.
    private static func hourLabel(_ hour: Int) -> String {
        let calendar = Calendar.current
        let anchored = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return anchored.formatted(.dateTime.hour())
    }
}
