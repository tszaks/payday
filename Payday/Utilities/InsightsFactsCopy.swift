import Foundation

/// Turns InsightsFacts straight into sections with zero AI involvement —
/// the fallback for hardware that can't run Foundation Models. Per
/// PRODUCT.md: "Insights shows the stats-engine facts without narration
/// (which must stand alone anyway)." Deterministic and fully testable,
/// same spirit as RevealCopy.
///
/// Kept out of StatsEngine.swift (App-target only, unlike that file) since
/// it depends on InsightSection, which lives next to the OpenAI-calling
/// code in InsightsService.swift — the widget extension shares the engine
/// but never needs Insights.
enum InsightsFactsCopy {
    static func sections(for facts: InsightsFacts) -> [InsightSection] {
        var sections: [InsightSection] = [overallSnapshot(facts), topEarningDays(facts), cashVsCredit(facts)]
        if let lunchDinner = facts.lunchDinner {
            sections.append(lunchVsDinner(lunchDinner))
        }
        if let doublesSolo = facts.doublesSolo {
            sections.append(doublesVsSolo(doublesSolo))
        }
        if let rate = facts.rate {
            sections.append(hourlyRate(rate))
        }
        if let sales = facts.sales {
            sections.append(tipPercent(sales))
        }
        return sections
    }

    private static func overallSnapshot(_ facts: InsightsFacts) -> InsightSection {
        var body = "You made \(Money.string(fromCents: facts.totalCents)) across \(facts.shiftCount) shifts, averaging \(Money.string(fromCents: facts.averagePerShiftCents)) per shift."
        // The total above is already net — say so whenever a tip-out
        // actually moved it, never silently.
        if facts.totalTipOutCents > 0 {
            body += " That's after \(Money.string(fromCents: facts.totalTipOutCents)) in tip-outs."
        }
        return InsightSection(title: "Overall Snapshot", body: body)
    }

    private static func topEarningDays(_ facts: InsightsFacts) -> InsightSection {
        let lines = facts.topDays.map { "\(Money.string(fromCents: $0.cents)) on \($0.date.formatted(.dateTime.month(.wide).day()))" }
        let body = lines.isEmpty ? "Not enough shifts yet to call out a top day." : "Your best days: " + lines.joined(separator: ", ") + "."
        return InsightSection(title: "Top Earning Days", body: body)
    }

    private static func cashVsCredit(_ facts: InsightsFacts) -> InsightSection {
        let body = "You made \(Money.string(fromCents: facts.creditCents)) from credit tips versus \(Money.string(fromCents: facts.cashCents)) from cash."
        return InsightSection(title: "Cash vs Credit", body: body)
    }

    private static func lunchVsDinner(_ facts: LunchDinnerFacts) -> InsightSection {
        let body = "Dinner shifts brought in \(Money.string(fromCents: facts.dinnerCents)) across \(facts.dinnerShiftCount) shifts. Lunch shifts brought in \(Money.string(fromCents: facts.lunchCents)) across \(facts.lunchShiftCount) shifts."
        return InsightSection(title: "Lunch vs Dinner", body: body)
    }

    private static func doublesVsSolo(_ facts: DoublesSoloFacts) -> InsightSection {
        let body = "Double shifts averaged \(Money.string(fromCents: facts.doubleAverageCents)) across \(facts.doubleCount) shifts. Solo shifts averaged \(Money.string(fromCents: facts.soloAverageCents)) across \(facts.soloCount) shifts."
        return InsightSection(title: "Doubles vs Solo", body: body)
    }

    private static func nightsPhrase(_ count: Int) -> String {
        count == 1 ? "1 night" : "\(count) nights"
    }

    private static func hourlyRate(_ facts: RateFacts) -> InsightSection {
        var body = "You're averaging \(Money.wholeDollarString(fromCents: Int((facts.overallDollarsPerHour * 100).rounded())))/hr across \(facts.nightsWithHours) shifts with hours logged."
        if let bestWeekday = facts.bestWeekday, let bestRate = facts.bestWeekdayDollarsPerHour, let count = facts.bestWeekdayNightCount {
            let weekdayName = Calendar.current.weekdaySymbols[bestWeekday - 1]
            body += " \(weekdayName) pays best at \(Money.wholeDollarString(fromCents: Int((bestRate * 100).rounded())))/hr across \(nightsPhrase(count))."
        }
        return InsightSection(title: "Your Hourly Rate", body: body)
    }

    private static func tipPercent(_ facts: SalesFacts) -> InsightSection {
        var body = "You're averaging \(String(format: "%.1f", facts.overallTipPercent))% of sales across \(facts.nightsWithSales) shifts with sales logged."
        if let bestWeekday = facts.bestWeekday, let bestPercent = facts.bestWeekdayTipPercent, let count = facts.bestWeekdayNightCount {
            let weekdayName = Calendar.current.weekdaySymbols[bestWeekday - 1]
            body += " \(weekdayName) tips best at \(String(format: "%.1f", bestPercent))% across \(nightsPhrase(count))."
        }
        return InsightSection(title: "Tip Percent", body: body)
    }
}
