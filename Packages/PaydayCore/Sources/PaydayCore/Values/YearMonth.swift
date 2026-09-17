import Foundation

/// A calendar month, the unit the Calendar screen and month tiles query by.
public struct YearMonth: Hashable, Comparable, Codable, Sendable {
    public let year: Int
    /// 1...12
    public let month: Int

    public init(year: Int, month: Int) {
        precondition((1...12).contains(month), "month must be 1...12, got \(month)")
        self.year = year
        self.month = month
    }

    /// The month containing `day`.
    public init(_ day: CivilDay) {
        self.year = day.year
        self.month = day.month
    }

    /// 28...31, leap years respected.
    public var dayCount: Int { CivilDay.daysInMonth(year: year, month: month) }

    public var firstDay: CivilDay { CivilDay(year: year, month: month, day: 1) }
    public var lastDay: CivilDay { CivilDay(year: year, month: month, day: dayCount) }

    /// First through last day of the month, inclusive.
    public var range: DayRange { DayRange(start: firstDay, end: lastDay) }

    public var next: YearMonth {
        month == 12 ? YearMonth(year: year + 1, month: 1) : YearMonth(year: year, month: month + 1)
    }

    public var previous: YearMonth {
        month == 1 ? YearMonth(year: year - 1, month: 12) : YearMonth(year: year, month: month - 1)
    }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    // MARK: Codable (validated)

    private enum CodingKeys: String, CodingKey { case year, month }

    /// Decoding validates `month` and throws instead of trapping, so a bad
    /// snapshot, fixture, or server payload is a `DecodingError`, not a crash
    /// on the first `dayCount`/`range` access. Mirrors `CivilDay`.
    /// Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decode(Int.self, forKey: .month)
        guard (1...12).contains(month) else {
            throw DecodingError.dataCorruptedError(forKey: .month, in: container,
                debugDescription: "month must be 1...12, got \(month)")
        }
        self.year = year
        self.month = month
    }
}
