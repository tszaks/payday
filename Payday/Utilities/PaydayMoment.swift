import Foundation

/// Decides whether the Dashboard's "period complete" moment should show right
/// now, and for which finished period. Pure and stateless so the timing rule
/// is unit-testable without SwiftData, the view, or "now".
///
/// The rule, in plain terms: the moment belongs to a period whose last shift
/// has already passed and whose paycheck is still on its way — never to a day
/// the person can still work. With a payroll lag (a period closing Sunday,
/// paid the following Friday) that means it appears the day AFTER the last
/// shift and lingers only a day or two, capped so it never drags all the way
/// to payday. With no lag it shows on the last day itself, since there's no
/// gap to wait through. A period the person has dismissed never comes back.
enum PaydayMoment {
    /// The just-finished period whose completion summary should show now, or
    /// nil if none applies.
    ///
    /// - Parameters:
    ///   - now: the current moment.
    ///   - calculator: the pay-period math for the person's schedule.
    ///   - dismissedEnd: the `end` of a period the person closed the card on;
    ///     that period is suppressed.
    ///   - lingerDays: how many days past the last shift the moment stays
    ///     (capped at payday). Two days ≈ "shows Monday and Tuesday" for a
    ///     Sunday close.
    static func finishedPeriod(
        now: Date,
        calculator: PayPeriodCalculator,
        dismissedEnd: Date? = nil,
        lingerDays: Int = 2,
        calendar: Calendar = .current
    ) -> PayPeriod? {
        var cal = calendar
        cal.timeZone = .current
        let today = cal.startOfDay(for: now)
        let current = calculator.period(containing: now)
        let dayBefore = cal.date(byAdding: .day, value: -1, to: current.start) ?? current.start
        let prior = calculator.period(containing: dayBefore)
        let hasDelay = calculator.schedule.resolvedPayDelayDays > 0

        // The days on which a finished period's card is allowed to show. With a
        // lag: the day after its last shift, up to `lingerDays` later but never
        // past payday. With no lag: the last shift day only.
        func window(_ period: PayPeriod) -> ClosedRange<Date> {
            let end = cal.startOfDay(for: period.end)
            guard hasDelay else { return end...end }
            let lower = cal.date(byAdding: .day, value: 1, to: end) ?? end
            let payDate = cal.startOfDay(for: calculator.payDate(for: period))
            let cap = cal.date(byAdding: .day, value: lingerDays, to: end) ?? end
            let upper = min(payDate, cap)
            return lower...max(lower, upper)
        }

        // Check the current period first (covers the no-lag, last-day case),
        // then the one just before it (covers the lag window, by which point
        // the dashboard has already rolled to the new period).
        for candidate in [current, prior] where window(candidate).contains(today) {
            if let dismissedEnd, cal.isDate(dismissedEnd, inSameDayAs: candidate.end) {
                return nil
            }
            return candidate
        }
        return nil
    }
}
