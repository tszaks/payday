import Foundation

/// Turns StatsEngine.PlanForward's plain facts into the PLAN section's
/// copy — deterministic and templated, not narrated by a model, same
/// discipline as RevealCopy. Deliberately outside StatsEngine.swift since
/// the widget target compiles that file alone and has no use for view copy.
///
/// **The basis of the figure it prints is the page's**, declared once by
/// `InsightsBasis.note` above it: `PlanForward.projectedTotalCents` is a sum
/// of `PlanForward.Night.averageNetCents`, each of which is a weekday's mean
/// per-shift take on whatever basis `StatsEngine.cents(of:)` was given
/// (`docs/METRICS.md` [IL-24], [IL-25]). This file does no arithmetic of its
/// own: it reads one already-computed integer and formats it.
///
/// `body(for:)` used to live here too and is deleted ([ID-01]). It wrote the
/// same per-night figures into one run-on sentence — "Friday about $180 (8
/// Fridays), Saturday about $210 (7)" — while `InsightsView.planNightRow`
/// renders each night as its own row with its own sample count, which is what
/// ships. It had no caller outside its own test, so it was a second formatter
/// for [IL-25]'s figure and nothing else.
enum PlanForwardCopy {
    static func headline(for plan: PlanForward) -> String {
        "Next week: about \(Money.wholeDollarString(fromCents: plan.projectedTotalCents))."
    }
}
