import Foundation

/// An inclusive span of civil days, `start...end`. Every query in the engine
/// (month, pay period, year to date, arbitrary range) resolves to one of
/// these before any shift is selected.
///
/// A range whose `end` is before its `start` is empty: `count == 0` and
/// `contains` is always false. That is what `clamped(to:)` produces when the
/// `asOf` day precedes the range, so "a future pay period viewed today" is a
/// legal, empty selection rather than a trap.
public struct DayRange: Hashable, Codable, Sendable {
    public let start: CivilDay
    public let end: CivilDay

    public init(start: CivilDay, end: CivilDay) {
        self.start = start
        self.end = end
    }

    /// A single-day range.
    public init(day: CivilDay) {
        self.start = day
        self.end = day
    }

    public var isEmpty: Bool { end < start }

    /// Number of days in the range, 0 when empty.
    public var count: Int {
        isEmpty ? 0 : CivilDay.daysBetween(start, end) + 1
    }

    public func contains(_ day: CivilDay) -> Bool {
        !isEmpty && start <= day && day <= end
    }

    /// The same range with `end = min(end, asOf)`. This is the `asOf` rule
    /// every period-to-date query applies (mirroring `StatsEngine
    /// .periodToDateTotal`), and it applies to tips AND wages alike.
    public func clamped(to asOf: CivilDay) -> DayRange {
        DayRange(start: start, end: min(end, asOf))
    }

    /// Every day in the range, in order. Empty when `isEmpty`.
    public var days: [CivilDay] {
        guard !isEmpty else { return [] }
        return (0..<count).map { start.adding(days: $0) }
    }
}

extension DayRange: CustomStringConvertible {
    public var description: String { "\(start.iso)...\(end.iso)" }
}
