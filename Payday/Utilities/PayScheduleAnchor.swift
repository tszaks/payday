import Foundation
import PaydayCore

/// The primary pay schedule's anchor, between the date pickers, storage and
/// the server.
///
/// A picker shows days on the phone's calendar, and `PayPeriodCalculator`
/// reads the stored anchor as a civil day in the payroll zone. Sunday
/// midnight in New York is Saturday evening in Los Angeles, so storing the
/// phone's midnight would end every period a day early. Every direction
/// moves the civil day across instead, as a job's schedule does
/// (`PaySchedule.init(_:in:primary:)`). In one zone, `stored` is the phone's
/// `startOfDay`.
enum PayScheduleAnchor {
    /// The anchor to store for the day picked on the phone.
    static func stored(picked: Date, payrollTimeZone: TimeZone, phoneTimeZone: TimeZone = .current) -> Date {
        CivilDay(picked, in: phoneTimeZone).date(in: payrollTimeZone)
    }

    /// The date a picker shows for a stored anchor: the same civil day.
    static func shown(stored: Date, payrollTimeZone: TimeZone, phoneTimeZone: TimeZone = .current) -> Date {
        CivilDay(stored, in: payrollTimeZone).date(in: phoneTimeZone)
    }

    /// The day the server holds for a stored anchor: its civil day in the
    /// payroll zone, so every phone that downloads it lays out the same
    /// periods wherever it is.
    static func wireDay(stored: Date, payrollTimeZone: TimeZone) -> String {
        CivilDay(stored, in: payrollTimeZone).iso
    }

    /// The anchor to store for a day the server holds. Nil for anything that
    /// is not a `YYYY-MM-DD` day.
    static func stored(wireDay: String, payrollTimeZone: TimeZone) -> Date? {
        CivilDay(iso: wireDay)?.date(in: payrollTimeZone)
    }
}
