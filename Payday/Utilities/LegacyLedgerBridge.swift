import Foundation

/// The one adapter from the legacy `TipEntry` representation to
/// `CompensationLedger`'s inputs, so `WageEstimate` and `PeriodIncome` can be
/// thin wrappers over the engine instead of two more copies of the wage
/// arithmetic. Both of those types are deleted in PR 8 once every consumer
/// reads `EarningsSnapshot` directly (PR 5), and this bridge goes with them.
///
/// It exists because the pre-PaydayCore surfaces are handed `[[TipEntry]]`
/// and a plain `Int?` rate, not policies. Rather than let them keep doing
/// their own `rate * hours` in `Double`, the bridge synthesizes the two
/// policies those inputs imply and lets the ledger do the arithmetic. The
/// policies are synthetic but not fabricated: the rate is the one the caller
/// already had, the workweek start is the one the app was already bucketing
/// by, and both take effect in the distant past because the caller has no
/// history to express.
enum LegacyLedgerBridge {
    /// The synthetic policy pair a legacy caller's `(rate, weekday, zone)`
    /// implies. Ids are content-derived so two calls with the same inputs
    /// produce the same policy, which keeps `ShiftValuation` comparable
    /// across calls.
    static func policies(
        rateCents: Int?,
        payrollTimeZone: TimeZone,
        workweekStartWeekday: Int
    ) -> (rates: [PayRatePolicy], calendars: [PayrollCalendarPolicy]) {
        let weekday = PayrollCalendarPolicy.weekdayRange.contains(workweekStartWeekday) ? workweekStartWeekday : 1
        let calendar = PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("legacy/bridge/calendar/\(weekday)/\(payrollTimeZone.identifier)"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: weekday,
            payrollTimeZone: payrollTimeZone
        )
        guard let rateCents, rateCents > 0 else { return ([], [calendar]) }
        let rate = PayRatePolicy(
            id: PolicyMigration.deterministicID("legacy/bridge/rate/\(rateCents)"),
            effectiveFrom: .distantPast,
            hourlyRateCents: rateCents,
            provenance: .confirmed
        )
        return ([rate], [calendar])
    }

    /// One `ShiftInput` per shift group, carrying only what a WAGE needs:
    /// the work day, the canonical minutes, and the ordering keys.
    ///
    /// The tip components are deliberately left at zero. `WageEstimate` and
    /// `PeriodIncome` are wage-only by contract — their callers add the tip
    /// side themselves from `TipBreakdown` — and receipt v1/v2 normalization
    /// belongs to PR 2's `ShiftInputAdapter`, which is the one place allowed
    /// to decide what part of a stored amount was voluntary. Restating that
    /// rule here would make a second answer to the same question.
    ///
    /// The group's canonical hours come from `ShiftDetails.resolve` (a
    /// shift's hours count once however many rows its closeout took), and its
    /// work day is the earliest row's civil day in the PAYROLL zone, never
    /// the device's.
    static func shiftInputs(from shiftGroups: [[TipEntry]], payrollTimeZone: TimeZone) -> [ShiftInput] {
        shiftGroups.compactMap { group in
            guard let earliest = group.map(\.date).min() else { return nil }
            let details = ShiftDetails.resolve(from: group)
            let day = CivilDay(earliest, in: payrollTimeZone)
            return ShiftInput(
                id: group.compactMap(\.shiftID).first
                    ?? PolicyMigration.deterministicID("legacy/bridge/shift/\(day.iso)/\(group.map(\.id.uuidString).sorted().joined(separator: "/"))"),
                workDay: day,
                period: tag(for: details.shiftPeriod),
                recordedAt: group.compactMap(\.recordedAt).min(),
                voluntaryCashCents: 0,
                voluntaryCreditCents: 0,
                gratuityFeesCents: 0,
                tipOutCents: nil,
                minutesWorked: details.hoursWorked.map(WorkedMinutes.minutes(fromHours:))
            )
        }
    }

    /// Values `shiftGroups` through the real ledger.
    static func valuations(
        shiftGroups: [[TipEntry]],
        rateCents: Int?,
        payrollTimeZone: TimeZone,
        workweekStartWeekday: Int
    ) -> [ShiftValuation] {
        let (rates, calendars) = policies(
            rateCents: rateCents,
            payrollTimeZone: payrollTimeZone,
            workweekStartWeekday: workweekStartWeekday
        )
        return CompensationLedger.value(
            shiftInputs(from: shiftGroups, payrollTimeZone: payrollTimeZone),
            rates: rates,
            calendars: calendars
        )
    }

    private static func tag(for period: ShiftPeriod?) -> ShiftPeriodTag? {
        switch period {
        case .lunch: return .lunch
        case .dinner: return .dinner
        case nil: return nil
        }
    }
}
