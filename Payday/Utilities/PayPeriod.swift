import Foundation

enum PayFrequency: String, CaseIterable, Identifiable, Hashable, Codable {
    case weekly
    case biweekly
    case twiceMonthly
    case monthly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Every two weeks"
        case .twiceMonthly: "Twice a month"
        case .monthly: "Monthly"
        }
    }
}

struct PaySchedule: Codable, Equatable {
    var frequency: PayFrequency
    /// The last DAY OF WORK in a known pay period — not the day the paycheck
    /// arrives. Most payroll has a lag between the two (e.g. a period ending
    /// Sunday might not get paid until the following Friday); anchoring
    /// period math on the payday itself would silently misplace every period
    /// boundary by that same lag. See payDelayDays.
    var anchorPeriodEnd: Date
    /// Days between a period's last day of work and the paycheck for it
    /// landing. Optional so schedules saved before this existed decode to a
    /// safe 0 (the old, lag-unaware behavior) rather than failing to decode.
    var payDelayDays: Int?
    /// Which weekday the calendar grid starts on (Gregorian: 1 = Sunday …
    /// 7 = Saturday). Optional so schedules saved before this existed decode
    /// to nil and fall back to the device locale's default.
    var firstWeekday: Int?

    /// Resolved calendar week-start, defaulting to the device locale.
    var resolvedFirstWeekday: Int {
        firstWeekday ?? Calendar.current.firstWeekday
    }

    /// Resolved pay delay, defaulting to 0 (paid the same day the period ends).
    var resolvedPayDelayDays: Int {
        payDelayDays ?? 0
    }

    /// Harmless stand-in used only for a transient render if the schedule is
    /// nil while a period-driven view is briefly still mounted (e.g. DEBUG
    /// clear-all). RootView switches to first-run setup on the next update.
    static let fallback = PaySchedule(frequency: .biweekly, anchorPeriodEnd: .now)
}

struct PayPeriod: Hashable {
    let start: Date
    let end: Date
}

/// All pay-period date math lives here and nowhere else. Pure and stateless
/// aside from the schedule + calendar it was built with, so it is trivial to
/// unit test without touching SwiftData, UserDefaults, or "now".
struct PayPeriodCalculator {
    let schedule: PaySchedule
    private let calendar: Calendar

    init(schedule: PaySchedule, calendar: Calendar = .current) {
        self.schedule = schedule
        var cal = calendar
        cal.timeZone = TimeZone.current
        self.calendar = cal
    }

    // MARK: Public API

    /// The pay period that a given date falls inside: the day after the
    /// preceding period's last day through this period's last day, inclusive
    /// of both ends.
    func period(containing date: Date) -> PayPeriod {
        let end = periodEnd(onOrAfter: date)
        let previous = periodEnd(strictlyBefore: end)
        let start = addDays(1, to: previous)
        return PayPeriod(start: startOfDay(start), end: startOfDay(end))
    }

    /// The next period-end boundary strictly after the given date.
    func nextPeriodEnd(after date: Date) -> Date {
        periodEnd(onOrAfter: addDays(1, to: startOfDay(date)))
    }

    /// When the paycheck for this period actually lands — the period's last
    /// day of work plus the payroll lag. Distinct from `period.end` itself:
    /// that's the last day worked, not the day the money arrives.
    func payDate(for period: PayPeriod) -> Date {
        addDays(schedule.resolvedPayDelayDays, to: period.end)
    }

    /// How far through the period a date is, day-granular, in 0...1.
    /// The first day already shows visible progress (1/n, never 0) and the
    /// last day is exactly 1 — the Dashboard's progress track renders this,
    /// so "payday is today" must read as a full bar, not an almost-full one.
    func progress(through date: Date, in period: PayPeriod) -> Double {
        let totalDays = (calendar.dateComponents([.day], from: period.start, to: period.end).day ?? 0) + 1
        guard totalDays > 0 else { return 1 }
        let elapsed = (calendar.dateComponents([.day], from: period.start, to: startOfDay(date)).day ?? 0) + 1
        return Double(min(max(elapsed, 0), totalDays)) / Double(totalDays)
    }

    /// Whole days remaining from `date` until the end of the period containing it.
    func daysRemaining(from date: Date) -> Int {
        let d = startOfDay(date)
        let end = period(containing: d).end
        return calendar.dateComponents([.day], from: d, to: end).day ?? 0
    }

    // MARK: Period-end lookup, dispatched by frequency

    private func periodEnd(onOrAfter date: Date) -> Date {
        let d = startOfDay(date)
        switch schedule.frequency {
        case .weekly: return periodicBoundary(onOrAfter: d, stepDays: 7)
        case .biweekly: return periodicBoundary(onOrAfter: d, stepDays: 14)
        case .monthly: return monthlyBoundary(onOrAfter: d)
        case .twiceMonthly: return twiceMonthlyBoundary(onOrAfter: d)
        }
    }

    private func periodEnd(strictlyBefore date: Date) -> Date {
        let d = addDays(-1, to: startOfDay(date))
        switch schedule.frequency {
        case .weekly: return periodicBoundary(onOrBefore: d, stepDays: 7)
        case .biweekly: return periodicBoundary(onOrBefore: d, stepDays: 14)
        case .monthly: return monthlyBoundary(onOrBefore: d)
        case .twiceMonthly: return twiceMonthlyBoundary(onOrBefore: d)
        }
    }

    // MARK: Weekly / biweekly — fixed interval anchored on schedule.anchorPeriodEnd

    private func periodicBoundary(onOrAfter date: Date, stepDays: Int) -> Date {
        let anchor = startOfDay(schedule.anchorPeriodEnd)
        let diff = daysBetween(anchor, date)
        let n = ceilDiv(diff, stepDays)
        return addDays(n * stepDays, to: anchor)
    }

    private func periodicBoundary(onOrBefore date: Date, stepDays: Int) -> Date {
        let anchor = startOfDay(schedule.anchorPeriodEnd)
        let diff = daysBetween(anchor, date)
        let n = floorDiv(diff, stepDays)
        return addDays(n * stepDays, to: anchor)
    }

    // MARK: Monthly — same day-of-month as the anchor, clamped to short months.
    // Calendar's own byAdding(.month) does NOT clamp (Jan 31 + 1 month rolls
    // into March), so month-end clamping is done by hand here.

    private func monthlyBoundary(onOrAfter date: Date) -> Date {
        let anchorDay = calendar.component(.day, from: startOfDay(schedule.anchorPeriodEnd))
        let candidate = clampedDay(anchorDay, inMonthOf: date)
        if candidate >= date { return candidate }
        return clampedDay(anchorDay, inMonthOf: addMonths(1, to: date))
    }

    private func monthlyBoundary(onOrBefore date: Date) -> Date {
        let anchorDay = calendar.component(.day, from: startOfDay(schedule.anchorPeriodEnd))
        let candidate = clampedDay(anchorDay, inMonthOf: date)
        if candidate <= date { return candidate }
        return clampedDay(anchorDay, inMonthOf: addMonths(-1, to: date))
    }

    // MARK: Twice monthly — fixed period ends on the 15th and the last day of every month.

    private func twiceMonthlyBoundary(onOrAfter date: Date) -> Date {
        let fifteenth = clampedDay(15, inMonthOf: date)
        if date <= fifteenth { return fifteenth }
        let lastDay = lastDayOfMonth(containing: date)
        if date <= lastDay { return lastDay }
        return clampedDay(15, inMonthOf: addMonths(1, to: date))
    }

    private func twiceMonthlyBoundary(onOrBefore date: Date) -> Date {
        let lastDay = lastDayOfMonth(containing: date)
        if date >= lastDay { return lastDay }
        let fifteenth = clampedDay(15, inMonthOf: date)
        if date >= fifteenth { return fifteenth }
        return lastDayOfMonth(containing: addMonths(-1, to: date))
    }

    // MARK: Calendar helpers

    private func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    private func addDays(_ n: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: n, to: date) ?? date
    }

    private func addMonths(_ n: Int, to date: Date) -> Date {
        // Pivot on day 1 of the month so the intermediate date is always
        // valid, then let the caller re-clamp the target day-of-month.
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let firstOfMonth = calendar.date(from: comps) else { return date }
        return calendar.date(byAdding: .month, value: n, to: firstOfMonth) ?? date
    }

    private func daysBetween(_ from: Date, _ to: Date) -> Int {
        calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// The given day-of-month, clamped to the last real day of that month
    /// (e.g. day 31 in February becomes Feb 28 or 29).
    private func clampedDay(_ day: Int, inMonthOf date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let year = comps.year, let month = comps.month,
              let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else { return date }
        let bounded = min(day, range.count)
        return calendar.date(from: DateComponents(year: year, month: month, day: bounded)) ?? date
    }

    private func lastDayOfMonth(containing date: Date) -> Date {
        clampedDay(31, inMonthOf: date)
    }

    private func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    private func ceilDiv(_ a: Int, _ b: Int) -> Int {
        -floorDiv(-a, b)
    }
}
