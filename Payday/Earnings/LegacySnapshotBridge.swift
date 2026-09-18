import Foundation

/// A REAL `EarningsSnapshot` built from the legacy `TipEntry` representation.
///
/// ## Why this exists, and when it dies
///
/// PR 5's contract (`SnapshotFacts.swift`) is that every screen adapter takes
/// an `EarningsSnapshot`. The obvious source is `EarningsStore`, and that is
/// where wave 1 will get it. It cannot be the source today: the store reads
/// `FetchDescriptor<ShiftRecord>`, and **nothing writes `ShiftRecord` on a
/// device yet** — PR 2 slices S5 through S8 (the one-shot conversion and the
/// shift sync leg) are still open, and a grep for `ShiftRecord(` outside
/// `PaydayTests/` returns nothing. So `earningsStore.snapshot` on Tyler's
/// phone is an empty snapshot, and a screen migrated onto it would show a
/// person with years of shifts a blank page.
///
/// This bridge closes that gap without weakening the shape. It is not a
/// second engine and it is not a mock: it builds `EarningsInputs` and calls
/// `EarningsSnapshot.build`, so the output is the same `CompensationLedger`
/// valuation, the same `SnapshotStamp`, the same `Completeness`, and the same
/// queries the store's snapshot answers. The only difference is which table
/// the rows were read out of.
///
/// **Delete it when PR 2 S7 lands.** The replacement is one line per screen:
/// `LegacySnapshotBridge.snapshot(...)` becomes `earningsStore.snapshot`, and
/// nothing below that line changes, which is exactly what wave 0 was for.
///
/// ## The one judgement it makes, and why it is not a new one
///
/// `ShiftInput` wants voluntary cash, voluntary credit, and gratuity kept
/// apart. Splitting a stored `TipEntry.amountCents` into those three is a
/// receipt-normalization decision, and `LegacyLedgerBridge`'s header
/// deliberately refuses to make it ("receipt v1/v2 normalization belongs to
/// PR 2's `ShiftInputAdapter`, which is the one place allowed to decide what
/// part of a stored amount was voluntary").
///
/// This bridge does not make it either. It takes `TipBreakdown.total(of:)`
/// verbatim — the app's single existing answer, the one every screen already
/// renders and the one `private.derive_shifts` was written to match. So the
/// bridge restates no rule; it only moves an answer that already exists into
/// the engine's input shape.
enum LegacySnapshotBridge {
    /// One snapshot over the caller's OWN shift grouping.
    ///
    /// - Parameters:
    ///   - shifts: `ShiftDays.groupedByShift(...)` output. The group's
    ///     `shiftID` becomes `ShiftInput.id` verbatim, so a row can look its
    ///     own valuation up by the same id it renders under. (Not
    ///     `LegacyLedgerBridge.shiftInput`'s id, which falls back to a
    ///     different deterministic UUID for a nil-`shiftID` group and would
    ///     therefore miss.)
    ///   - rateCents: the legacy `baseHourlyWageCents`, or nil when the wage
    ///     feature is off. Nil produces a snapshot with
    ///     `wageFeatureEnabled == false`, which is what makes every figure
    ///     read "Tips" rather than "Total".
    ///   - payrollTimeZone: the FROZEN payroll zone from `PolicyStore`, never
    ///     `TimeZone.current` at the call site.
    ///   - asOf: today, for the period-to-date clamp. The caller's `now`.
    ///
    /// Returns nil only when the inputs cannot be canonically fingerprinted
    /// (`InputManifest.ValidationError`). That is a refusal, not a crash: a
    /// snapshot with no honest digest is a dataset nothing else can be
    /// compared against, and rule 4 says the screen renders placeholders
    /// rather than zeros for it.
    static func snapshot(
        shifts: [(day: Date, shiftID: UUID, items: [TipEntry])],
        rateCents: Int?,
        payrollTimeZone: TimeZone,
        workweekStartWeekday: Int,
        asOf: Date
    ) -> EarningsSnapshot? {
        let (rates, calendars) = LegacyLedgerBridge.policies(
            rateCents: rateCents,
            payrollTimeZone: payrollTimeZone,
            workweekStartWeekday: workweekStartWeekday
        )
        let inputs = EarningsInputs(
            shifts: shifts.compactMap { shiftInput(for: $0, payrollTimeZone: payrollTimeZone) },
            rates: rates,
            calendars: calendars,
            asOf: CivilDay(asOf, in: payrollTimeZone)
        )
        return try? EarningsSnapshot.build(inputs)
    }

    /// One group's `ShiftInput`: the caller's id, the legacy bridge's work
    /// day / minutes / ordering, and `TipBreakdown`'s split of the money.
    static func shiftInput(
        for group: (day: Date, shiftID: UUID, items: [TipEntry]),
        payrollTimeZone: TimeZone
    ) -> ShiftInput? {
        guard var input = LegacyLedgerBridge.shiftInput(from: group.items, payrollTimeZone: payrollTimeZone) else {
            return nil
        }
        // The caller's id, so `snapshot.valuation(group.shiftID)` hits.
        input.id = group.shiftID
        let breakdown = TipBreakdown.total(of: group.items)
        input.voluntaryCashCents = breakdown.cashCents
        input.voluntaryCreditCents = breakdown.creditCents
        input.gratuityFeesCents = breakdown.gratuityFeesCents
        // nil rather than 0 when nothing was tipped out: the engine reads nil
        // as 0 cents, and "not entered" and "entered as zero" are different
        // facts that only nil keeps apart.
        input.tipOutCents = breakdown.tipOutCents == 0 ? nil : breakdown.tipOutCents
        return input
    }

    /// The same thing from ungrouped entries, for a caller that has not
    /// grouped yet. Grouping is `ShiftDays.groupedByShift`, the app's one
    /// grouping rule.
    static func snapshot(
        entries: [TipEntry],
        rateCents: Int?,
        payrollTimeZone: TimeZone,
        workweekStartWeekday: Int,
        asOf: Date
    ) -> EarningsSnapshot? {
        snapshot(
            shifts: ShiftDays.groupedByShift(
                entries,
                shiftID: \.shiftID,
                date: \.date,
                period: \.shiftPeriod
            ),
            rateCents: rateCents,
            payrollTimeZone: payrollTimeZone,
            workweekStartWeekday: workweekStartWeekday,
            asOf: asOf
        )
    }
}
