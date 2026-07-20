import Foundation

/// Math for estimating a tipped employee's base wages — as opposed to tips —
/// on a paycheck. This is an ESTIMATE shown alongside tip totals only; it is
/// never folded into tip income, the hero take-home, charts, or $/hr
/// insights, which all stay tips-only.
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

    /// Compact hour label for inline captions ("41.5h"), quarter-hour
    /// precision matching LogTipSheet's own hours display, trailing zeros
    /// trimmed.
    static func hoursLabel(_ hours: Double) -> String {
        var formatted = String(format: "%.2f", (hours * 4).rounded() / 4)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return "\(formatted)h"
    }
}
