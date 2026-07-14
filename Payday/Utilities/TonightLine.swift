import Foundation

/// The Dashboard's one context-aware sentence, composed from facts the
/// engines already computed. Pure so the "which line tonight?" decision is
/// unit-testable; the view just renders whatever this returns.
enum TonightLine {
    /// - Returns: the line to show between the hero card and the Shifts
    ///   list, or nil when there's nothing worth saying (not a usual work
    ///   night, nothing logged, or the payday moment owns the slot).
    static func compose(
        rhythm: WorkRhythm,
        tonightRevealText: String?,
        isPaydayMoment: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String? {
        // The payday moment is the bigger statement; don't compete with it.
        if isPaydayMoment { return nil }

        if let tonightRevealText {
            return tonightRevealText
        }

        let weekday = calendar.component(.weekday, from: now)
        guard rhythm.usualWeekdays.contains(weekday) else { return nil }

        let dayName = calendar.weekdaySymbols[weekday - 1]
        guard let hour = rhythm.typicalLogHour,
              let at = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)
        else {
            return "\(dayName) shift tonight."
        }
        let hourText = at.formatted(.dateTime.hour())
        return "\(dayName) shift tonight. You usually log around \(hourText)."
    }
}
