import Foundation

/// Decides whether the Dashboard's payday card should show right now, for
/// which finished period, and in which of its two moments. Pure and stateless
/// so the timing rule is unit-testable without SwiftData, the view, or "now".
///
/// The rule, in plain terms: a finished period gets the card TWICE.
///
/// 1. `.periodClosed` — the day or two after the last shift. The period is
///    done and the check is on its way. Never on a day still workable; with a
///    payroll lag that means the day AFTER the last shift, lingering a day or
///    two, capped so it doesn't camp on screen all the way to payday.
///
/// 2. `.checkDay` — the day the money actually lands. This is the whole point
///    of the app (verify the check against what was logged), and it used to be
///    the one day the card was guaranteed to be GONE: with a 5-day lag the
///    linger window closed on day 2 and nothing came back, so on payday itself
///    the app named Payday said nothing about payday (Tyler, 2026-08-03:
///    "it's worth showing that card again on pay day").
///
/// The gap between the two stays empty on purpose. A card that sits there for
/// five days is furniture; one that returns the morning the money arrives is a
/// prompt. Each moment is dismissed independently — closing the period summary
/// on Monday is not a decision about Friday's paycheck.
///
/// With no payroll lag the two collapse onto the same day, and `.checkDay`
/// wins: if the money is there, verifying it outranks announcing the close.
enum PaydayMoment {
    enum Phase: String, Equatable {
        case periodClosed
        case checkDay
    }

    struct Moment: Equatable {
        let period: PayPeriod
        let phase: Phase
    }

    /// The finished period whose card should show now and which moment it is,
    /// or nil if none applies.
    ///
    /// - Parameters:
    ///   - now: the current moment.
    ///   - calculator: the pay-period math for the person's schedule.
    ///   - dismissedClosedEnd: the `end` of a period whose CLOSE summary was
    ///     dismissed; that period's `.periodClosed` moment is suppressed.
    ///   - dismissedCheckEnd: the `end` of a period whose PAYDAY card was
    ///     dismissed; that period's `.checkDay` moment is suppressed.
    ///   - lingerDays: how many days past the last shift the close summary
    ///     stays (capped at payday). Two days ≈ "shows Monday and Tuesday" for
    ///     a Sunday close.
    static func moment(
        now: Date,
        calculator: PayPeriodCalculator,
        dismissedClosedEnd: Date? = nil,
        dismissedCheckEnd: Date? = nil,
        lingerDays: Int = 2,
        calendar: Calendar = .current
    ) -> Moment? {
        var cal = calendar
        cal.timeZone = .current
        let today = cal.startOfDay(for: now)
        let current = calculator.period(containing: now)
        let dayBefore = cal.date(byAdding: .day, value: -1, to: current.start) ?? current.start
        let prior = calculator.period(containing: dayBefore)
        let hasDelay = calculator.schedule.resolvedPayDelayDays > 0

        /// The single day the check for this period lands.
        func isCheckDay(_ period: PayPeriod) -> Bool {
            cal.isDate(cal.startOfDay(for: calculator.payDate(for: period)), inSameDayAs: today)
        }

        /// The days the close summary is allowed to show. With a lag: the day
        /// after the last shift, up to `lingerDays` later but never past
        /// payday. With no lag: the last shift day only.
        func closeWindow(_ period: PayPeriod) -> ClosedRange<Date> {
            let end = cal.startOfDay(for: period.end)
            guard hasDelay else { return end...end }
            let lower = cal.date(byAdding: .day, value: 1, to: end) ?? end
            let payDate = cal.startOfDay(for: calculator.payDate(for: period))
            let cap = cal.date(byAdding: .day, value: lingerDays, to: end) ?? end
            let upper = min(payDate, cap)
            return lower...max(lower, upper)
        }

        func isDismissed(_ date: Date?, _ period: PayPeriod) -> Bool {
            guard let date else { return false }
            return cal.isDate(date, inSameDayAs: period.end)
        }

        // Check day is tested first so a no-lag schedule (where both moments
        // land on the same date) reports the more useful of the two. The
        // current period is tested before the one before it: with a lag the
        // dashboard has already rolled to the new period by the time either
        // moment fires, so `prior` is the usual match.
        for candidate in [current, prior] where isCheckDay(candidate) {
            guard !isDismissed(dismissedCheckEnd, candidate) else { continue }
            return Moment(period: candidate, phase: .checkDay)
        }
        for candidate in [current, prior] where closeWindow(candidate).contains(today) {
            guard !isDismissed(dismissedClosedEnd, candidate) else { continue }
            return Moment(period: candidate, phase: .periodClosed)
        }
        return nil
    }
}
