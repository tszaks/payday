import Foundation

/// Which query produced an `EarningsResult`.
///
/// The metric registry says every result carries `metric`, `scope`, `asOf`,
/// `manifest`, `engineVersion` and `completeness`. `metric` says *what* the
/// number is; `scope` says *what it is a number for*, so two consumers
/// showing the same cents can prove they asked the same question. A
/// Dashboard hero and a History row that disagree are then a diff of two
/// values (`scope` and `stamp`), not an argument.
///
/// It is NOT the range: `range` on the result is the selection AFTER the
/// `asOf` clamp, while the scope is the question as asked. A month viewed
/// mid-month has `scope == .month(2026-09)` and `range == 09-01...09-17`.
public enum EarningsScope: Hashable, Codable, Sendable {
    /// One shift, by id. Carries no range: a shift is a row, not a span.
    case shift(UUID)
    case day(CivilDay)
    case month(YearMonth)
    /// One pay period, as the civil days the caller's schedule laid out.
    case payPeriod(DayRange)
    case yearToDate(year: Int)
    /// An arbitrary span (charts, insights windows, exports).
    case range(DayRange)
    /// The expected figures for the period a recorded paycheck covers.
    case paycheck(periodEnd: CivilDay)
}
