import Foundation

/// The Dashboard's dataset: ONE snapshot and the ONE shift grouping whose
/// `shiftID`s index it.
///
/// ## Why it exists — two measured defects, both about doing this twice
///
/// **The grouping calendar.** `DashboardView.body` built its snapshot with
/// `LegacySnapshotBridge.snapshot(entries:)`, the convenience overload whose
/// `ShiftDays.groupedByShift` call takes the DEFAULT `Calendar.current` —
/// the DEVICE's zone. `DashboardFacts.init` then grouped the same rows again
/// with `PayrollCalendar.gridCalendar(in: payrollTimeZone)` — the FROZEN
/// payroll zone — and looked the results up by those ids. For a legacy
/// `TipEntry` with `shiftID == nil` the fallback id is
/// `ShiftDays.deterministicShiftID(for:calendar:)`, which is
/// `calendar.startOfDay(...)`-derived, so the two minted DIFFERENT ids for
/// any row whose civil day differs between the zones and
/// `snapshot.valuation(id)` missed outright.
///
/// MEASURED (device zone `America/New_York`, payroll zone
/// `Pacific/Pago_Pago`, one nil-`shiftID` row on 2026-10-06 02:00, 8h at
/// $10/hr): view id `5AAC5D00-0000-0000-C124-000000000000`, adapter id
/// `5AAC5D00-0000-0000-C024-000000000000`, `rowValuationFound = false`,
/// `heroCents = 18000`. The hero printed $180.00 and the only shift row
/// under it printed the unavailable placeholder. It also silently killed
/// `tonightLine`. Invisible to every test, because `PaydayTestZone.payroll`
/// equals `TimeZone.current` on the simulator.
///
/// The fix is not "pass the calendar at both call sites": two groupings that
/// have to agree is the defect. There is one grouping per render now, here,
/// and both the snapshot and `DashboardFacts` are built from it.
///
/// **The `asOf` cutoff.** The snapshot used to be built with `asOf: now`, so
/// the to-date clamp was a property of the DATASET. History builds its own
/// with `asOf: .distantFuture` (`HistoryEarnings.build`, group 2.4) because
/// History has never applied a to-date cutoff. MEASURED on the merged tree:
/// the same current period read 40400 on Dashboard and 79800 on the History
/// row and in period detail, all three labelled "You kept", with DIFFERENT
/// stamp digests — provably two datasets, which is the one thing the adapter
/// contract's rule 3 exists to prevent.
///
/// So the dataset is unclamped and the narrower scope is an ARGUMENT at the
/// query site: `snapshot.range(heroRange, asOf: CivilDay(now, ...))` in
/// `DashboardFacts`, for the hero only. One shared stamp, so a disagreement
/// between two screens stays diffable, and Dashboard's cutoff is something
/// it declares rather than something baked into its copy of the data — and
/// declares on screen too, via `DashboardFacts.heroDeferredShiftCount`.
///
/// ## The same shape as `HistoryEarnings.Build`, on purpose
///
/// Group 2.4 wrote that type for the same reason on the same day. The two
/// are a snapshot plus its grouping, built from `PolicyStore.policies` whole
/// with the grid calendar in the frozen payroll zone, and they should become
/// ONE shared builder in a wave-0 follow-up merged alone rather than a third
/// copy invented by the next screen. They are kept separate today only
/// because the plan's rule is that a shared change does not get made twice
/// by two parallel workers; this one is flagged for the coordinator.
///
/// **This is the PR 2 slice S7 swap point.** When something finally writes
/// `ShiftRecord` locally, `build` becomes `earningsStore.snapshot` and
/// nothing above it changes.
enum DashboardEarnings {
    /// - Parameters:
    ///   - entries: every local `TipEntry`, not the period's slice. The
    ///     ledger allocates the overtime threshold across the complete
    ///     workweek of the shifts it is handed, so a fourteen-day slice
    ///     cannot price the forty-first hour of a week that began before day
    ///     one ([SC-01]; MEASURED at $50.00 of lost overtime in
    ///     `DashboardStraddlingWorkweekTests`).
    ///   - policies: `PolicyStore.policies`, whole. Never a scalar rate and
    ///     never a scalar weekday — wave 0 measured $520.00/`.complete`
    ///     against the correct $440.00/`.estimated` when a scalar rate became
    ///     a `.distantPast` confirmed policy, and two screens bucketing
    ///     overtime into different weeks when one of them read the
    ///     pay-period GRID's weekday. The engine does the effective dating.
    ///   - calendar: the GRID calendar, in the frozen payroll zone
    ///     (`PayrollCalendar.gridCalendar(in:)`). It groups and it bounds
    ///     periods; it prices nothing.
    /// The shift-representation dataset.
    ///
    /// The swap this type's header promised: "`LegacySnapshotBridge` and not
    /// `earningsStore.snapshot`: nothing writes `ShiftRecord` on a device
    /// until PR 2 slice S7 ... the swap is inside `DashboardEarnings.build`."
    /// This is that swap, and it keeps the snapshot and the rows on the SAME
    /// representation so the hero cannot sit over rows drawn from the other
    /// one.
    /// **The one entry point.** Both representations in, one resolved
    /// dataset out; see `ShiftRepresentation`.
    @MainActor
    static func build(
        entries: [TipEntry],
        records: [ShiftRecord],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        calendar: Calendar,
        representation: ShiftRepresentation = .automatic
    ) -> Dataset {
        representation.usesRecords
            ? build(records: records, policies: policies, payrollTimeZone: payrollTimeZone)
            : build(entries: entries, policies: policies, payrollTimeZone: payrollTimeZone, calendar: calendar)
    }

    @MainActor
    static func build(
        records: [ShiftRecord],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone
    ) -> Dataset {
        let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
        let snapshot = try? EarningsSnapshot.build(EarningsInputs(
            shifts: adapted.inputs,
            rates: policies.rates,
            calendars: policies.calendars,
            // Unclamped, the same decision the legacy build makes below: the
            // to-date cutoff is the HERO's scope, not the dataset's.
            asOf: CivilDay(.distantFuture, in: payrollTimeZone),
            unreadableReceiptShiftIDs: adapted.unreadableReceiptShiftIDs
        ))
        return Dataset(
            snapshot: snapshot,
            shiftDays: [],
            shiftRecordDays: records,
            tipRecords: StatsRecordAdapter.tipRecords(from: records)
        )
    }

    static func build(
        entries: [TipEntry],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        calendar: Calendar
    ) -> Dataset {
        let shiftDays = ShiftDays.groupedByShift(
            entries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod,
            calendar: calendar
        )
        return Dataset(
            snapshot: LegacySnapshotBridge.snapshot(
                shifts: shiftDays,
                policies: policies,
                payrollTimeZone: payrollTimeZone,
                // Unclamped, matching History, Calendar and the log
                // preview. The to-date cutoff is the HERO's scope, not the
                // dataset's; see the type header.
                asOf: .distantFuture
            ),
            shiftDays: shiftDays,
            shiftRecordDays: [],
            tipRecords: entries.map(TipRecord.init)
        )
    }

    /// A snapshot and the grouping whose `shiftID`s index it.
    ///
    /// Internal rather than private for the reason `DashboardFacts` is: the
    /// plan's completion rule 2 is "its parity test passes against the real
    /// adapter, not a helper", and a test that rebuilds this by hand is a
    /// test that can share the view's mistake. `DashboardParityTests` calls
    /// `build` and hands `Dataset` straight to `DashboardFacts`, which is
    /// exactly what `DashboardView.body` does.
    struct Dataset {
        /// Nil only when the inputs could not be canonically fingerprinted,
        /// which is a refusal and renders as unavailable, never as `$0.00`.
        let snapshot: EarningsSnapshot?
        /// Newest day first, lunch before dinner — `ShiftDays`' order, which
        /// is what the rows render in.
        let shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])]
        /// The same rows in the shift representation. Exactly one of the two
        /// is populated, because `build` chooses a source rather than merging.
        let shiftRecordDays: [ShiftRecord]
        /// The `StatsEngine` input, already flattened out of whichever
        /// representation built this dataset — `StatsRecordAdapter`'s rows on
        /// the records arm, `TipRecord.init` over the entries on the legacy
        /// arm. Rows rather than the raw models, so **no consumer can tell
        /// which representation is underneath**: `DashboardFacts` used to
        /// flatten `allShifts` itself, which read as correct on both arms but
        /// silently fed the pace comparison an empty history the moment an
        /// account flipped — the same starvation class `InsightsEarnings
        /// .Dataset.tipRecords` exists to prevent.
        let tipRecords: [TipRecord]
    }
}
