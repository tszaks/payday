import Foundation

/// Pure timing logic for the designated-work-calendar upgrade to the one
/// smart nudge (SmartNudgeScheduler) — no EventKit here, so it stays
/// deterministic and fully unit-testable. Designate, never decipher: this
/// never looks at an event's title, only its start/end, so it has nothing
/// to say about WHAT a shift is, only WHEN one ends.
enum WorkScheduleNudge {
    struct ScheduledShift: Equatable {
        let start: Date
        let end: Date
    }

    private static let horizonDays = 7
    private static let fireDelayMinutes = 15
    /// An event lasting a full day or more reads as all-day or multi-day on
    /// the calendar, not a shift with a closeout moment — EventKit's own
    /// isAllDay flag is filtered upstream in WorkCalendarStore, but a
    /// duration check here keeps this pure function self-contained and
    /// testable without EventKit.
    private static let maxShiftDuration: TimeInterval = 24 * 60 * 60

    /// The moment the nudge should fire based on the designated calendar,
    /// or nil when the schedule offers nothing usable (caller falls back
    /// to the rhythm heuristic). Overlapping events — e.g. the same double
    /// posted as two blocks — collapse to one fire date, 15 minutes after
    /// the latest end in the cluster.
    static func fireDate(shifts: [ScheduledShift], now: Date, alreadyLoggedToday: Bool, calendar: Calendar = .current) -> Date? {
        guard let horizon = calendar.date(byAdding: .day, value: horizonDays, to: now) else { return nil }

        let qualifying = shifts
            .filter { $0.end > now && $0.end <= horizon && $0.end.timeIntervalSince($0.start) < maxShiftDuration }
            .sorted { $0.start < $1.start }
        guard !qualifying.isEmpty else { return nil }

        let clusterEnds = mergedClusterEnds(of: qualifying)
        for end in clusterEnds.sorted() {
            if alreadyLoggedToday, calendar.isDate(end, inSameDayAs: now) { continue }
            return calendar.date(byAdding: .minute, value: fireDelayMinutes, to: end)
        }
        return nil
    }

    /// Standard interval-merge: shifts are assumed sorted by start. A shift
    /// starting at or before the running cluster's end joins that cluster
    /// instead of starting a new one, and the cluster's end becomes the
    /// later of the two.
    private static func mergedClusterEnds(of sortedShifts: [ScheduledShift]) -> [Date] {
        var ends: [Date] = []
        var currentEnd: Date?
        for shift in sortedShifts {
            if let end = currentEnd, shift.start <= end {
                currentEnd = max(end, shift.end)
            } else {
                if let currentEnd { ends.append(currentEnd) }
                currentEnd = shift.end
            }
        }
        if let currentEnd { ends.append(currentEnd) }
        return ends
    }
}
