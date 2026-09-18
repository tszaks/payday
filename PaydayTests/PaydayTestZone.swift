import Foundation

/// The payroll time zone the suites state explicitly.
///
/// `StatsEngine` and `PayPeriodCalculator` used to force `TimeZone.current`
/// onto whatever calendar they were handed, so every existing expectation in
/// these suites was written against the device's zone. `payroll` is that same
/// zone, named, so those expectations still measure what they always measured
/// while the production call sites now pass the FROZEN payroll zone from the
/// calendar policy instead.
///
/// Reach for `newYork`/`honolulu` when a test is specifically about travel:
/// the point of the frozen zone is that two different device zones produce
/// identical numbers, which needs two named zones to say.
enum PaydayTestZone {
    /// The zone the legacy expectations in these suites were written in.
    static let payroll = TimeZone.current

    static let newYork = TimeZone(identifier: "America/New_York")!
    static let honolulu = TimeZone(identifier: "Pacific/Honolulu")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
}
