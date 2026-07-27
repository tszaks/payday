import Foundation

/// The collapsed details group's one-line summary in LogTipSheet — lets a
/// new-entry sheet fold Date/Shift/Started/Ended/Tip-out into a sentence
/// instead of eight always-open rows, while still saying exactly what's
/// already known. Pure so the "which clauses, in what order" decision is
/// unit-testable independent of the view.
enum ShiftBeliefLine {
    /// - Returns: clauses joined by " · " — the date, then whichever of
    ///   period/punch-range/tip-out are already known. When nothing beyond
    ///   the date is known yet, "add details" stands in for the rest.
    static func compose(
        date: Date,
        shiftPeriod: ShiftPeriod?,
        clockIn: Date?,
        clockOut: Date?,
        tipOutCents: Int,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> String {
        let dateLabel = dateLabel(for: date, calendar: calendar, now: now)

        var clauses: [String] = []
        if let shiftPeriod {
            clauses.append(shiftPeriod.displayName)
        }
        if let clockIn, let clockOut {
            clauses.append(punchRangeClause(clockIn: clockIn, clockOut: clockOut))
        }
        if tipOutCents > 0 {
            clauses.append("\(tippedOutAmount(cents: tipOutCents)) tipped out")
        }

        guard !clauses.isEmpty else { return "\(dateLabel) · add details" }
        return ([dateLabel] + clauses).joined(separator: " · ")
    }

    /// "Today" / "Yesterday" / "Jul 12" — the year is never shown, same
    /// reasoning as ShiftDays.humanLabel: it's always this one.
    private static func dateLabel(for date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "5:02 – 11:41 PM" — each punch formatted with .hour().minute(), the
    /// leading AM/PM dropped when it matches the trailing one (the common
    /// case) so the sentence doesn't repeat itself. Splits on any Unicode
    /// whitespace, not just the ASCII space — the system formatter joins
    /// the time and AM/PM marker with a narrow no-break space.
    private static func punchRangeClause(clockIn: Date, clockOut: Date) -> String {
        let style = Date.FormatStyle.dateTime.hour().minute()
        let startParts = clockIn.formatted(style).split(whereSeparator: \.isWhitespace)
        let endParts = clockOut.formatted(style).split(whereSeparator: \.isWhitespace)
        // Rejoined with a plain ASCII space regardless — the system
        // formatter can join the time and AM/PM marker with a narrow
        // no-break space instead.
        let normalizedEnd = endParts.joined(separator: " ")
        if startParts.count > 1, startParts.last == endParts.last {
            let trimmedStart = startParts.dropLast().joined(separator: " ")
            return "\(trimmedStart) – \(normalizedEnd)"
        }
        return "\(startParts.joined(separator: " ")) – \(normalizedEnd)"
    }

    /// Whole dollars when the amount is an even dollar figure, cents otherwise.
    private static func tippedOutAmount(cents: Int) -> String {
        cents % 100 == 0 ? Money.wholeDollarString(fromCents: cents) : Money.string(fromCents: cents)
    }
}
