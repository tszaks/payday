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
    var anchorPayday: Date
    /// Which weekday the calendar grid starts on (Gregorian: 1 = Sunday …
    /// 7 = Saturday). Optional so schedules saved before this existed decode
    /// to nil and fall back to the device locale's default.
    var firstWeekday: Int?

    /// Resolved calendar week-start, defaulting to the device locale.
    var resolvedFirstWeekday: Int {
        firstWeekday ?? Calendar.current.firstWeekday
    }

    /// Harmless stand-in used only for a transient render if the schedule is
    /// nil while a period-driven view is briefly still mounted (e.g. DEBUG
    /// clear-all). RootView switches to first-run setup on the next update.
    static let fallback = PaySchedule(frequency: .biweekly, anchorPayday: .now)
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
    /// preceding payday through the next payday, inclusive of both ends.
    func period(containing date: Date) -> PayPeriod {
        let end = payday(onOrAfter: date)
        let previous = payday(strictlyBefore: end)
        let start = addDays(1, to: previous)
        return PayPeriod(start: startOfDay(start), end: startOfDay(end))
    }

    /// The next payday strictly after the given date.
    func nextPayday(after date: Date) -> Date {
        payday(onOrAfter: addDays(1, to: startOfDay(date)))
    }

    /// Whole days remaining from `date` until the end of the period containing it.
    func daysRemaining(from date: Date) -> Int {
        let d = startOfDay(date)
        let end = period(containing: d).end
        return calendar.dateComponents([.day], from: d, to: end).day ?? 0
    }

    // MARK: Payday lookup, dispatched by frequency

    private func payday(onOrAfter date: Date) -> Date {
        let d = startOfDay(date)
        switch schedule.frequency {
        case .weekly: return periodicPayday(onOrAfter: d, stepDays: 7)
        case .biweekly: return periodicPayday(onOrAfter: d, stepDays: 14)
        case .monthly: return monthlyPayday(onOrAfter: d)
        case .twiceMonthly: return twiceMonthlyPayday(onOrAfter: d)
        }
    }

    private func payday(strictlyBefore date: Date) -> Date {
        let d = addDays(-1, to: startOfDay(date))
        switch schedule.frequency {
        case .weekly: return periodicPayday(onOrBefore: d, stepDays: 7)
        case .biweekly: return periodicPayday(onOrBefore: d, stepDays: 14)
        case .monthly: return monthlyPayday(onOrBefore: d)
        case .twiceMonthly: return twiceMonthlyPayday(onOrBefore: d)
        }
    }

    // MARK: Weekly / biweekly — fixed interval anchored on schedule.anchorPayday

    private func periodicPayday(onOrAfter date: Date, stepDays: Int) -> Date {
        let anchor = startOfDay(schedule.anchorPayday)
        let diff = daysBetween(anchor, date)
        let n = ceilDiv(diff, stepDays)
        return addDays(n * stepDays, to: anchor)
    }

    private func periodicPayday(onOrBefore date: Date, stepDays: Int) -> Date {
        let anchor = startOfDay(schedule.anchorPayday)
        let diff = daysBetween(anchor, date)
        let n = floorDiv(diff, stepDays)
        return addDays(n * stepDays, to: anchor)
    }

    // MARK: Monthly — same day-of-month as the anchor, clamped to short months.
    // Calendar's own byAdding(.month) does NOT clamp (Jan 31 + 1 month rolls
    // into March), so month-end clamping is done by hand here.

    private func monthlyPayday(onOrAfter date: Date) -> Date {
        let anchorDay = calendar.component(.day, from: startOfDay(schedule.anchorPayday))
        let candidate = clampedDay(anchorDay, inMonthOf: date)
        if candidate >= date { return candidate }
        return clampedDay(anchorDay, inMonthOf: addMonths(1, to: date))
    }

    private func monthlyPayday(onOrBefore date: Date) -> Date {
        let anchorDay = calendar.component(.day, from: startOfDay(schedule.anchorPayday))
        let candidate = clampedDay(anchorDay, inMonthOf: date)
        if candidate <= date { return candidate }
        return clampedDay(anchorDay, inMonthOf: addMonths(-1, to: date))
    }

    // MARK: Twice monthly — fixed paydays on the 15th and the last day of every month.

    private func twiceMonthlyPayday(onOrAfter date: Date) -> Date {
        let fifteenth = clampedDay(15, inMonthOf: date)
        if date <= fifteenth { return fifteenth }
        let lastDay = lastDayOfMonth(containing: date)
        if date <= lastDay { return lastDay }
        return clampedDay(15, inMonthOf: addMonths(1, to: date))
    }

    private func twiceMonthlyPayday(onOrBefore date: Date) -> Date {
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
