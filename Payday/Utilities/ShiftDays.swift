import Foundation

/// Day-grouping and human labels for the Dashboard's Shifts list. A shift is
/// a day worked, not a row — one night is often two TipEntry rows (cash +
/// credit), and showing it as two events doubles the visual noise. Pure and
/// generic so it's testable without SwiftData.
enum ShiftDays {
    /// Groups items into calendar days, newest day first. Items within a day
    /// keep their given order.
    static func groupedByDay<T>(_ items: [T], date: (T) -> Date, calendar: Calendar = .current) -> [(day: Date, items: [T])] {
        var order: [Date] = []
        var buckets: [Date: [T]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order
            .sorted(by: >)
            .map { (day: $0, items: buckets[$0] ?? []) }
    }

    /// The label a person would use for the day: "Tonight", "Yesterday",
    /// a bare weekday inside the last week, then "Friday, Jul 11".
    /// The year is deliberately never shown — it's always this one.
    static func humanLabel(for day: Date, relativeTo now: Date = .now, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0

        switch daysAgo {
        case 0: return "Tonight"
        case 1: return "Yesterday"
        case 2...6: return day.formatted(.dateTime.weekday(.wide))
        default: return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }
}
