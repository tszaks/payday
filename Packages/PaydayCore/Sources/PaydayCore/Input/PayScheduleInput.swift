import Foundation

/// The pay schedule as the engine needs it: enough to lay out pay periods
/// and to fingerprint in the `InputManifest`. `frequency` is the raw string
/// of the app's `PayFrequency` (`weekly`, `biweekly`, `twiceMonthly`,
/// `monthly`) so the package does not have to own that enum until
/// `PayPeriodCalculator` moves in (PR 3).
///
/// `firstWeekday` is grid-only: it decides how the Calendar draws its
/// weeks. Overtime bucketing is owned by `PayrollCalendarPolicy
/// .workweekStartWeekday` (Design 1, "Severing calendar from payroll"), so
/// the W3 fixture flips this value and asserts nothing moves.
public struct PayScheduleInput: Hashable, Codable, Sendable {
    public var frequency: String
    public var anchorPeriodEnd: CivilDay
    /// Days from a period's end to its pay date.
    public var payDelayDays: Int
    /// 1 = Sunday ... 7 = Saturday; nil means "follow the device locale".
    public var firstWeekday: Int?

    public init(frequency: String, anchorPeriodEnd: CivilDay, payDelayDays: Int, firstWeekday: Int? = nil) {
        self.frequency = frequency
        self.anchorPeriodEnd = anchorPeriodEnd
        self.payDelayDays = payDelayDays
        self.firstWeekday = firstWeekday
    }
}
