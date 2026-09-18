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
/// queries the store's snapshot answers.
///
/// **Delete it when PR 2 S7 lands.** The replacement is one line per screen:
/// `LegacySnapshotBridge.snapshot(shifts:policies:...)` becomes
/// `earningsStore.snapshot`.
///
/// ## What differs from `EarningsStore`, exactly
///
/// Only the SHIFT TABLE, and two absences. The policies are the user's own
/// (see below), so the rate history, the workweek history and the frozen
/// payroll zone are identical to the store's. What the bridge does not carry:
///
/// - **No `paychecks` and no `schedule`.** `EarningsInputs` accepts both and
///   `EarningsStore` supplies them from `PaycheckRecord` and `PayScheduleStore`.
///   The bridge omits them, so `snapshot.payPeriod(_:)` and any
///   reconciliation query answer over a period the caller has to bound
///   itself. Every wave-0 consumer asks `day(_:)`, `range(_:)` or
///   `valuation(_:)`, which do not read either.
/// - **The caller's `asOf`, not `now()`.** Period detail deliberately passes
///   `.distantFuture` so a future day of the current period still renders as
///   its own labelled slot.
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
///
/// ## It values with the USER'S policies, never a synthesized pair
///
/// This is the fix for a measured defect in wave 0's first cut, and it is
/// the reason the parameter is `CompensationPolicies` and not an `Int?` rate
/// plus an `Int` weekday.
///
/// That first cut handed `LegacyLedgerBridge.policies` one scalar rate, which
/// turns into a single `PayRatePolicy` at `effectiveFrom: .distantPast` with
/// `provenance: .confirmed`. MEASURED on the simulator (two 8h shifts, $10/h
/// until 2026-06-01 then $20/h): the synthesized pair priced the March shift
/// at 16000c and reported the year as $520.00, state `.complete`, caption
/// nil; the same shifts under `PolicyStore`'s real history give 8000c,
/// $440.00, `.estimated`, and the caption "Wages estimated from your current
/// rate". So every pre-raise shift was repriced at today's rate on every
/// migrated surface, and `.estimated` was unreachable — which made
/// `CompletenessCopy.caption(.estimated)` dead code in production even though
/// `PayrollSettingsSection` ships a "Rate changed on…" control that writes
/// exactly that history.
///
/// One consequence worth knowing, because it is the honest engine answer and
/// not a bug: with **no calendar policy on file** the ledger has no workweek
/// to allocate into, so every wage reads `.unavailable(.noCalendarPolicy)`.
/// `PolicyStore.runMigrationsIfNeeded` always creates one, and
/// `PaydayCloudGate` calls it on launch and after every sync, so this is
/// reachable only in the async hop before that first adoption on a single
/// launch. `EarningsStore` answers identically there, which is the point:
/// the bridge must not invent a policy the store would not have.
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
    ///   - policies: `PolicyStore.policies`, whole and unmodified — the real
    ///     effective-dated rate and workweek history. The ONE policy source
    ///     for the whole app: passing anything else here is how two screens
    ///     came to bucket overtime by two different workweeks.
    ///   - payrollTimeZone: the FROZEN payroll zone, which is
    ///     `PolicyStore.payrollTimeZone` (`policies.payrollTimeZone ?? .current`)
    ///     and never `TimeZone.current` at the call site. It is a parameter
    ///     rather than derived because the caller has already grouped its
    ///     rows by civil day in this zone and the two must be the same zone.
    ///   - asOf: the period-to-date clamp. Usually the caller's `now`.
    ///
    /// Returns nil only when the inputs cannot be canonically fingerprinted
    /// (`InputManifest.ValidationError`). That is a refusal, not a crash: a
    /// snapshot with no honest digest is a dataset nothing else can be
    /// compared against, and rule 4 says the screen renders placeholders
    /// rather than zeros for it.
    static func snapshot<Row: LegacyShiftRow>(
        shifts: [(day: Date, shiftID: UUID, items: [Row])],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        asOf: Date
    ) -> EarningsSnapshot? {
        let inputs = EarningsInputs(
            shifts: shifts.compactMap { shiftInput(for: $0, payrollTimeZone: payrollTimeZone) },
            rates: policies.rates,
            calendars: policies.calendars,
            asOf: CivilDay(asOf, in: payrollTimeZone)
        )
        return try? EarningsSnapshot.build(inputs)
    }

    /// One group's `ShiftInput`: the caller's id, the legacy bridge's work
    /// day / minutes / ordering, and `TipBreakdown`'s split of the money.
    static func shiftInput<Row: LegacyShiftRow>(
        for group: (day: Date, shiftID: UUID, items: [Row]),
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
    static func snapshot<Row: LegacyShiftRow>(
        entries: [Row],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        asOf: Date
    ) -> EarningsSnapshot? {
        snapshot(
            shifts: ShiftDays.groupedByShift(
                entries,
                shiftID: \.shiftID,
                date: \.date,
                period: \.shiftPeriod
            ),
            policies: policies,
            payrollTimeZone: payrollTimeZone,
            asOf: asOf
        )
    }
}
