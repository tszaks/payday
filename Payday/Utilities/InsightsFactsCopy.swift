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
        return sections
    }

    private static func overallSnapshot(_ facts: InsightsFacts) -> InsightSection {
        let body = "You made \(Money.string(fromCents: facts.totalCents)) across \(facts.shiftCount) shifts, averaging \(Money.string(fromCents: facts.averagePerShiftCents)) per shift."
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
}
