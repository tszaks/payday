import Foundation

/// Period-level wage math (hero, drawer, period detail, periods list) for the
/// surfaces that have not moved to `EarningsSnapshot` yet. As of PR 3 it is a
/// thin wrapper over `CompensationLedger`; PR 5 migrates the callers and PR 8
/// deletes this type.
///
/// It lives entirely on the wages side of the ledger and is added by callers;
/// it is never folded into either voluntary tips or Toast employee gratuity.
enum PeriodIncome {
    struct Wages {
        let regularCents: Int
        let overtimeCents: Int
        let hours: Double
        let overtimeHours: Double

        var totalCents: Int { regularCents + overtimeCents }
    }

    /// Wages for a set of entries, with overtime computed per WORKWEEK rather
    /// than per pay period: a shift's hours belong to the week its work day
    /// falls in, and hours past the threshold pay 1.5x — matching how
    /// overtime is actually calculated on a paycheck, regardless of where the
    /// pay period's own boundaries fall.
    ///
    /// Every cent here now comes from `CompensationLedger`, so the per-shift
    /// figures on a row and this period total are slices of the same
    /// allocation and cannot disagree. Hours are the shift's one canonical
    /// value (`ShiftDetails.resolve`), never summed per row. Returns nil when
    /// no rate is set or no hours were logged — an estimate is never
    /// fabricated from a fallback.
    ///
    /// - Parameters:
    ///   - payrollTimeZone: the FROZEN payroll zone from the calendar policy.
    ///     Required: it decides which civil day, and therefore which
    ///     workweek, a late shift belongs to, and reading the device's zone
    ///     let a flight move hours across the overtime threshold.
    ///   - firstWeekday: the workweek start to bucket by. Still a parameter
    ///     because the callers are pre-policy surfaces; PR 5 replaces it with
    ///     `PayrollCalendarPolicy.workweekStartWeekday`, which is the thing
    ///     that actually owns overtime (Design 1, "Severing calendar from
    ///     payroll").
    static func wages(
        payrollTimeZone: TimeZone,
        entries: [TipEntry],
        wageCentsPerHour: Int?,
        firstWeekday: Int? = nil,
        calendar sourceCalendar: Calendar = .current
    ) -> Wages? {
        guard let wageCentsPerHour, wageCentsPerHour > 0 else { return nil }

        var calendar = sourceCalendar
        calendar.timeZone = payrollTimeZone
        if let firstWeekday { calendar.firstWeekday = firstWeekday }

        let shifts = ShiftDays.groupedByShift(
            entries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod, calendar: calendar
        )
        let valuations = LegacyLedgerBridge.valuations(
            shiftGroups: shifts.map(\.items),
            rateCents: wageCentsPerHour,
            payrollTimeZone: payrollTimeZone,
            workweekStartWeekday: firstWeekday ?? calendar.firstWeekday
        )

        let totalMinutes = valuations.compactMap(\.minutesWorked).reduce(0, +)
        guard totalMinutes > 0 else { return nil }

        let components = valuations.reduce(EarningsComponents.zero) { $0 + $1.components }
        let overtimeMinutes = valuations.reduce(0) { $0 + $1.wage.components.overtimeMinutes }

        return Wages(
            regularCents: components.regularWagesCents,
            overtimeCents: components.overtimeWagesCents,
            hours: WorkedMinutes.hours(fromMinutes: totalMinutes),
            overtimeHours: WorkedMinutes.hours(fromMinutes: overtimeMinutes)
        )
    }
}
