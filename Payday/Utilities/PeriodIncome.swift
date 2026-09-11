import Foundation

/// Base-wage + overtime math that becomes part of period INCOME (hero,
/// drawer, period detail, periods list) — unlike WageEstimate, which provides
/// per-shift wage math. It lives entirely on the wages side of the ledger and
/// is added by callers; it is never folded into either voluntary tips or
/// Toast employee gratuity.
enum PeriodIncome {
    struct Wages {
        let regularCents: Int
        let overtimeCents: Int
        let hours: Double
        let overtimeHours: Double

        var totalCents: Int { regularCents + overtimeCents }
    }

    /// Wages for a set of entries, overtime computed per CALENDAR WORKWEEK
    /// rather than per pay period: a shift's hours belong to the week its
    /// day falls in (Calendar.current, firstWeekday overridden when given),
    /// and hours beyond 40 in that week pay 1.5x — matching how overtime is
    /// actually calculated on a paycheck, regardless of where the pay
    /// period's own boundaries fall. Hours are the shift's one canonical
    /// value (ShiftDetails.resolve), never summed per-row. Returns nil when
    /// no rate is set or no hours were logged — like WageEstimate, an
    /// estimate is never fabricated from a fallback.
    static func wages(
        entries: [TipEntry],
        wageCentsPerHour: Int?,
        firstWeekday: Int? = nil,
        calendar sourceCalendar: Calendar = .current
    ) -> Wages? {
        guard let wageCentsPerHour else { return nil }

        var calendar = sourceCalendar
        if let firstWeekday { calendar.firstWeekday = firstWeekday }

        let shifts = ShiftDays.groupedByShift(entries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)

        var weekHours: [Date: Double] = [:]
        for shift in shifts {
            let hours = ShiftDetails.resolve(from: shift.items).hoursWorked ?? 0
            guard hours > 0 else { continue }
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: shift.day)?.start ?? shift.day
            weekHours[weekStart, default: 0] += hours
        }

        let totalHours = weekHours.values.reduce(0, +)
        guard totalHours > 0 else { return nil }

        var regularCents = 0
        var overtimeCents = 0
        var totalOvertimeHours = 0.0

        for hours in weekHours.values {
            let regularHours = min(hours, 40)
            let overtimeHours = max(0, hours - 40)
            regularCents += Int((Double(wageCentsPerHour) * regularHours).rounded())
            overtimeCents += Int((Double(wageCentsPerHour) * 1.5 * overtimeHours).rounded())
            totalOvertimeHours += overtimeHours
        }

        return Wages(regularCents: regularCents, overtimeCents: overtimeCents, hours: totalHours, overtimeHours: totalOvertimeHours)
    }
}
