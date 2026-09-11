import Foundation

/// Turns StatsEngine.PlanForward's plain facts into the PLAN section's
/// copy — deterministic and templated, not narrated by a model, same
/// discipline as RevealCopy. Deliberately outside StatsEngine.swift since
/// the widget target compiles that file alone and has no use for view copy.
enum PlanForwardCopy {
    private static func weekdayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }

    static func headline(for plan: PlanForward) -> String {
        "Next week: about \(Money.wholeDollarString(fromCents: plan.projectedTotalCents))."
    }

    /// One sentence naming every usual night and its price — the first
    /// night spells out its weekday plural ("8 Fridays") so the reader
    /// learns the unit once; the rest just carry their own count.
    static func body(for plan: PlanForward) -> String {
        let nightPhrases = plan.nights.enumerated().map { index, night -> String in
            let name = weekdayName(night.weekday)
            let price = "\(name) about \(Money.wholeDollarString(fromCents: night.averageNetCents))"
            return index == 0 ? "\(price) (\(night.nightCount) \(name)s)" : "\(price) (\(night.nightCount))"
        }
        let nightsWord = plan.nights.count == 1 ? "usual night" : "usual nights"
        let sentence = "\(plan.nights.count) \(nightsWord) - \(nightPhrases.joined(separator: ", "))."

        return sentence
    }
}
