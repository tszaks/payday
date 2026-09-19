import Foundation

/// A calendar date with no time and no time zone: the "work day" a shift is
/// attributed to, the day a pay period ends, the `asOf` clamp.
///
/// PaydayCore does money math on civil days, never on `Date`, so that a device
/// travelling between time zones cannot move a shift into a different week
/// (see the plan's Design 1, "Frozen payroll timezone"). The only place a
/// `Date` becomes a `CivilDay` is `init(_:in:)`, which takes an explicit
/// `TimeZone` and never consults `Calendar.current`.
///
/// Weekday and day arithmetic use a proleptic Gregorian day-number algorithm
/// (Howard Hinnant's `days_from_civil` / `civil_from_days`), so results are
/// identical on every platform and independent of locale, calendar
/// preferences, or the process's current time zone.
///
/// `Codable` as the ISO string `"YYYY-MM-DD"`, which is also the fixture
/// format and the manifest encoding.
public struct CivilDay: Hashable, Comparable, Codable, Sendable {
    public let year: Int
    /// 1...12
    public let month: Int
    /// 1...31, valid for `month` in `year`.
    public let day: Int

    /// Builds a day from components. Traps on an out-of-range component; use
    /// `init?(year:month:day:)` (the failable variant) for untrusted input.
    public init(year: Int, month: Int, day: Int) {
        precondition(CivilDay.isValid(year: year, month: month, day: day),
                     "CivilDay \(year)-\(month)-\(day) is not a valid Gregorian date")
        self.year = year
        self.month = month
        self.day = day
    }

    /// Failable component initializer. Returns nil unless `month` is 1...12
    /// and `day` is within that month for that year (leap years respected).
    public init?(validating year: Int, month: Int, day: Int) {
        guard CivilDay.isValid(year: year, month: month, day: day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The civil day `date` falls on in `timeZone`, by Gregorian components.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year!, month: components.month!, day: components.day!)
    }

    /// Midnight at the start of this civil day in `timeZone`, the exact
    /// inverse of `init(_:in:)`.
    ///
    /// It exists for the surfaces that have to hand a civil day to something
    /// that only speaks `Date`: Swift Charts' x-axis, `Calendar`-based
    /// formatting, `.dateTime` format styles. Those are PRESENTATION
    /// consumers, and the round trip through a `Date` is the last thing that
    /// happens before pixels. Nothing in the engine calls this — a wage that
    /// went through a `Date` would be a wage a travelling device could move.
    ///
    /// Never optional: `DateComponents` with a valid Gregorian year, month
    /// and day always resolves, and the `.distantPast` fallback would be a
    /// silently wrong x-position rather than a visible failure.
    public func date(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// Parses exactly `"YYYY-MM-DD"` (four-digit year, zero-padded month and
    /// day, ASCII digits and hyphens). Anything else returns nil.
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(validating: year, month: month, day: day)
    }

    /// `"YYYY-MM-DD"`, zero-padded.
    public var iso: String {
        func pad(_ value: Int, _ width: Int) -> String {
            let raw = String(value)
            return raw.count >= width ? raw : String(repeating: "0", count: width - raw.count) + raw
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    // MARK: Arithmetic

    /// Days since 1970-01-01 (negative before it). Proleptic Gregorian.
    /// "Aug 31". For copy that has to NAME a day rather than count one.
    ///
    /// Built from a table rather than a `DateFormatter` because this type is
    /// a civil day, not an instant: handing it to a formatter means choosing
    /// a time zone, and the whole point of `CivilDay` is that there is not
    /// one to choose. English-only, matching the rest of the copy layer.
    public var shortLabel: String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard month >= 1, month <= 12 else { return iso }
        return "\(months[month - 1]) \(day)"
    }

    public var dayNumber: Int {
        CivilDay.dayNumber(year: year, month: month, day: day)
    }

    /// The day `days` after this one (negative moves backwards).
    public func adding(days: Int) -> CivilDay {
        CivilDay(dayNumber: dayNumber + days)
    }

    /// `to.dayNumber - from.dayNumber`: positive when `to` is later.
    public static func daysBetween(_ from: CivilDay, _ to: CivilDay) -> Int {
        to.dayNumber - from.dayNumber
    }

    /// 1 = Sunday ... 7 = Saturday (the `Calendar` convention), computed from
    /// the day number: 1970-01-01 was a Thursday (5).
    public var weekday: Int {
        let z = dayNumber
        return ((z % 7) + 7 + 4) % 7 + 1
    }

    /// The most recent day (this one included) whose `weekday` equals
    /// `weekday`. With `2` (Monday) this is the Monday-start workweek that
    /// contains the day; with `1` (Sunday) the Sunday-start one.
    public func startOfWorkweek(startingOn weekday: Int) -> CivilDay {
        precondition((1...7).contains(weekday), "weekday must be 1 (Sunday) ... 7 (Saturday)")
        let delta = (self.weekday - weekday + 7) % 7
        return adding(days: -delta)
    }

    /// The earliest day on or after this one whose `weekday` equals
    /// `weekday`: this day itself when it is already a workweek start, the
    /// next one otherwise. Settings snaps a chosen policy date with this, so
    /// a `PayrollCalendarPolicy` can never take effect mid-week.
    public func nextStartOfWorkweek(startingOn weekday: Int) -> CivilDay {
        precondition((1...7).contains(weekday), "weekday must be 1 (Sunday) ... 7 (Saturday)")
        let delta = (weekday - self.weekday + 7) % 7
        return adding(days: delta)
    }

    /// Whether `year` is a Gregorian leap year.
    public var isLeapYear: Bool { CivilDay.isLeapYear(year) }

    /// 0001-01-01: earlier than any real record. Used as the `effectiveFrom`
    /// of a policy that has "always" applied.
    public static let distantPast = CivilDay(year: 1, month: 1, day: 1)
    /// 9999-12-31.
    public static let distantFuture = CivilDay(year: 9999, month: 12, day: 31)

    public static func < (lhs: CivilDay, rhs: CivilDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: Codable (ISO string)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = CivilDay(iso: raw) else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Expected YYYY-MM-DD, got \(raw)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }

    // MARK: Proleptic Gregorian algorithms

    /// Builds the day at `dayNumber` days since 1970-01-01.
    public init(dayNumber: Int) {
        let (y, m, d) = CivilDay.civil(fromDayNumber: dayNumber)
        self.year = y
        self.month = m
        self.day = d
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    /// Number of days in `month` of `year`.
    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: preconditionFailure("month must be 1...12, got \(month)")
        }
    }

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        return day <= daysInMonth(year: year, month: month)
    }

    /// Hinnant `days_from_civil`.
    static func dayNumber(year y0: Int, month m: Int, day d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Hinnant `civil_from_days`.
    static func civil(fromDayNumber z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

extension CivilDay: CustomStringConvertible {
    public var description: String { iso }
}
