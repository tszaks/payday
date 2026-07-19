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
        if let startTime = facts.startTime {
            sections.append(startTimes(startTime))
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

    /// Never "credit was the larger share" — that's true for nearly every
    /// server and says nothing. The useful fact is the cash share and what
    /// the split means: cash went home night-of, credit rides the paycheck.
    private static func cashVsCredit(_ facts: InsightsFacts) -> InsightSection {
        let grossCents = facts.cashCents + facts.creditCents
        let body: String
        if grossCents <= 0 {
            body = "No cash or credit tips logged in this window yet."
        } else if facts.cashCents == 0 {
            body = "All \(Money.string(fromCents: facts.creditCents)) of your tips came in on cards, so all of it arrives on your paycheck."
        } else if facts.creditCents == 0 {
            body = "All \(Money.string(fromCents: facts.cashCents)) of your tips came in cash, taken home the nights you earned it."
        } else {
            let cashPercent = Int((Double(facts.cashCents) / Double(grossCents) * 100).rounded())
            body = "About \(cashPercent)% of your tips came in cash: \(Money.string(fromCents: facts.cashCents)) you took home night-of. The other \(Money.string(fromCents: facts.creditCents)) came in on cards and lands on your paycheck."
        }
        return InsightSection(title: "Cash vs Credit", body: body)
    }

    /// Per-shift averages, never raw totals — the shift counts differ, and
    /// "dinner out-earned lunch 4 to 1" off totals is the wrong conclusion
    /// when per-shift it's 2 to 1.
    private static func lunchVsDinner(_ facts: LunchDinnerFacts) -> InsightSection {
        let lunchAvg = facts.lunchShiftCount > 0 ? facts.lunchCents / facts.lunchShiftCount : 0
        let dinnerAvg = facts.dinnerShiftCount > 0 ? facts.dinnerCents / facts.dinnerShiftCount : 0
        let body = "Dinner averaged \(Money.string(fromCents: dinnerAvg)) per shift across \(shiftsPhrase(facts.dinnerShiftCount)). Lunch averaged \(Money.string(fromCents: lunchAvg)) per shift across \(shiftsPhrase(facts.lunchShiftCount))."
        return InsightSection(title: "Lunch vs Dinner", body: body)
    }

    /// A double day out-earning a single shift is arithmetic, not a finding —
    /// the honest comparison is per shift.
    private static func doublesVsSolo(_ facts: DoublesSoloFacts) -> InsightSection {
        var body = "A double day brought in \(Money.string(fromCents: facts.doubleAverageCents)) on average across \(facts.doubleCount == 1 ? "1 day" : "\(facts.doubleCount) days"), which works out to \(Money.string(fromCents: facts.doublePerShiftCents)) per shift. Single-shift days averaged \(Money.string(fromCents: facts.soloAverageCents))."
        if facts.doublePerShiftCents > 0, facts.soloAverageCents > 0, facts.doublePerShiftCents < facts.soloAverageCents {
            body += " Per shift, your singles are actually out-earning your doubles so far."
        }
        return InsightSection(title: "Doubles vs Solo", body: body)
    }

    private static func shiftsPhrase(_ count: Int) -> String {
        count == 1 ? "1 shift" : "\(count) shifts"
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

    /// We only ever know a shift's total, never how pay was distributed
    /// within it — so this is honestly a shift-vs-shift comparison by start
    /// hour, never a claim about a specific minute (see StartTimeFacts).
    private static func startTimes(_ facts: StartTimeFacts) -> InsightSection {
        let body = "Shifts starting around \(hourLabel(facts.bestStartHour)) average \(Money.wholeDollarString(fromCents: Int((facts.bestDollarsPerHour * 100).rounded())))/hr across \(nightsPhrase(facts.bestShiftCount)). Shifts starting around \(hourLabel(facts.worstStartHour)) average \(Money.wholeDollarString(fromCents: Int((facts.worstDollarsPerHour * 100).rounded())))/hr across \(nightsPhrase(facts.worstShiftCount))."
        return InsightSection(title: "Start Times", body: body)
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
