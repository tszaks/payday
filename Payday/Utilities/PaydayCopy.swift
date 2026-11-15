import Foundation

/// Shared tense-honest copy for payday-related dates, so the "is this in the
/// future?" rule lives in exactly one place and can never fork between the
/// periods list and period detail screens.
enum PaydayCopy {
    /// "Payday · Wed, Jul 29" while the money hasn't landed yet (today or a
    /// future date), "Paid Jul 24" once it has — never "Paid" ahead of time.
    static func payDateText(payDate: Date, relativeTo now: Date = .now, timeZone: TimeZone) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let isUpcoming = calendar.startOfDay(for: payDate) >= calendar.startOfDay(for: now)
        if isUpcoming {
            return "Payday · \(payDate.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day()))"
        }
        return "Paid \(payDate.formatted(Date.FormatStyle(timeZone: timeZone).month(.abbreviated).day()))"
    }
}
