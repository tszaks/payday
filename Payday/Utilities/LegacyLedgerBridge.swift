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
    ///
    /// **Do not reach for this from anything new.** It is rate-BLIND by
    /// construction: one scalar becomes a single `PayRatePolicy` at
    /// `effectiveFrom: .distantPast` with `provenance: .confirmed`, so every
    /// shift ever worked is priced at today's rate and `.estimated` is
    /// unreachable. That is a faithful restatement of what `WageEstimate` and
    /// `PeriodIncome` have always done — those two are the only callers left
    /// and both die in PR 8 — but it is NOT what a new money path should do.
    /// `LegacySnapshotBridge` was briefly built on this and the divergence
    /// was measured: $520.00 / `.complete` here against $440.00 /
    /// `.estimated` through `PolicyStore`'s real history, for two 8h shifts
    /// at $10/h then $20/h. Anything new takes the whole
    /// `CompensationPolicies` value and lets the engine do the effective
    /// dating.
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
    static func shiftInputs<Row: LegacyShiftRow>(from shiftGroups: [[Row]], payrollTimeZone: TimeZone) -> [ShiftInput] {
        shiftGroups.compactMap { shiftInput(from: $0, payrollTimeZone: payrollTimeZone) }
    }

    /// One group's `ShiftInput`, or nil for an empty group (nothing to date
    /// it by). Split out of `shiftInputs(from:)` so a caller can keep its own
    /// per-group alignment — see `wagesCentsPerShift`.
    static func shiftInput<Row: LegacyShiftRow>(from group: [Row], payrollTimeZone: TimeZone) -> ShiftInput? {
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

    /// Values `shiftGroups` through the real ledger.
    static func valuations<Row: LegacyShiftRow>(
        shiftGroups: [[Row]],
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

    /// Each group's OWN wages, in the order the groups arrived, each one its
    /// slice of the same workweek allocation the sum of this array is.
    ///
    /// This exists so a screen cannot disagree with itself. A list of shifts
    /// and the total above it are now two views of one array: the hero is
    /// `reduce(0, +)` of exactly the figures printed on the rows, so
    /// "the day equals the sum of that day's shifts" is arithmetic rather
    /// than a hope. Before PR 3's review this was the P0: the total came from
    /// the ledger's cumulative allocation while every row still did its own
    /// independent rounding, and W1's day read 2759 in the hero and
    /// 1203 + 1557 = 2760 in the rows underneath it.
    ///
    /// A group the ledger cannot value (no entries, no hours, no rate)
    /// contributes 0, which is what the row already showed for those cases.
    static func wagesCentsPerShift<Row: LegacyShiftRow>(
        shiftGroups: [[Row]],
        rateCents: Int?,
        payrollTimeZone: TimeZone,
        workweekStartWeekday: Int
    ) -> [Int] {
        let inputs = shiftGroups.map { shiftInput(from: $0, payrollTimeZone: payrollTimeZone) }
        let (rates, calendars) = policies(
            rateCents: rateCents,
            payrollTimeZone: payrollTimeZone,
            workweekStartWeekday: workweekStartWeekday
        )
        let valuations = CompensationLedger.value(
            inputs.compactMap { $0 },
            rates: rates,
            calendars: calendars
        )
        // The ledger returns its own canonical order, so realign by id
        // rather than by position.
        let wagesByID = Dictionary(
            valuations.map { ($0.id, $0.components.wagesCents) },
            uniquingKeysWith: +
        )
        return inputs.map { input in
            input.flatMap { wagesByID[$0.id] } ?? 0
        }
    }

    private static func tag(for period: ShiftPeriod?) -> ShiftPeriodTag? {
        switch period {
        case .lunch: return .lunch
        case .dinner: return .dinner
        case nil: return nil
        }
    }
}
