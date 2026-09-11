import Foundation

/// Math for estimating a tipped employee's base wages — as opposed to tips —
/// on a paycheck. It is never classified as voluntary tips or employee
/// gratuity; callers add it only on surfaces that intentionally show total
/// shift or pay-period income.
enum WageEstimate {
    /// Estimated pre-tax wages for a set of shifts: wage rate x the hours
    /// actually logged (ShiftDetails' one-canonical-value-per-shift rule).
    /// Returns nil when the rate isn't set or no hours were logged — an
    /// estimate is never fabricated from a fallback.
    static func cents(wageCentsPerHour: Int?, hours: Double) -> Int? {
        guard let wageCentsPerHour, hours > 0 else { return nil }
        return Int((Double(wageCentsPerHour) * hours).rounded())
    }

    /// Total logged hours for grouped shifts (sum of each shift's canonical
    /// hoursWorked via ShiftDetails.resolve) — a shift's hours count once no
    /// matter how many TipEntry rows (cash + credit) made up its closeout.
    static func loggedHours(shiftGroups: [[TipEntry]]) -> Double {
        shiftGroups.reduce(0) { $0 + (ShiftDetails.resolve(from: $1).hoursWorked ?? 0) }
    }

    /// The LogTipSheet header total: cash + credit, net of tip-out, plus
    /// this shift's base-rate wages (rate x hoursWorked — never OT, which
    /// only exists weekly). The one place that math lives, so it's testable
    /// independent of the view.
    static func shiftTotalCents(cashCents: Int, creditCents: Int, tipOutCents: Int, wageCentsPerHour: Int?, hoursWorked: Double?) -> Int {
        let wage = hoursWorked.flatMap { cents(wageCentsPerHour: wageCentsPerHour, hours: $0) } ?? 0
        return cashCents + creditCents - tipOutCents + wage
    }

    /// Sum of each shift's INDIVIDUALLY ROUNDED base-rate wage cents across a
    /// set of shift groups — the one pattern every day/period wage-inclusive
    /// surface (CalendarView tiles, PeriodDetailView's chart, DayDetailSheet's
    /// day total) must use so it agrees with the sum of those same shifts'
    /// own per-shift wage figures (ShiftDayRow, the sheet header). Rounding
    /// once off the combined hours instead (loggedHours(...) then a single
    /// cents(...) call) can land a cent off that sum — e.g. a 4.25h shift and
    /// a 5.5h shift at $2.83/hr: round(283*4.25) + round(283*5.5) = 2760¢,
    /// but round(283*9.75) = 2759¢.
    static func centsSummedPerShift(shiftGroups: [[TipEntry]], wageCentsPerHour: Int?) -> Int {
        guard let wageCentsPerHour else { return 0 }
        return shiftGroups.reduce(0) { total, group in
            let hours = ShiftDetails.resolve(from: group).hoursWorked ?? 0
            guard hours > 0 else { return total }
            return total + (cents(wageCentsPerHour: wageCentsPerHour, hours: hours) ?? 0)
        }
    }

    /// Exact hour label ("6h 23m") for every user-facing hours display —
    /// the one shared implementation LogTipSheet and every wage caption in
    /// the app reads, so a shift's length is never shown two different ways.
    /// Minutes are omitted only when they're exactly zero ("6h"), never
    /// rounded away otherwise: a punch is literal (Tyler's law).
    static func hoursLabel(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let wholeHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(wholeHours)h" : "\(wholeHours)h \(minutes)m"
    }
}
