import Foundation

/// What the engine would say about a shift that has not been saved yet.
///
/// ## Why this exists
///
/// `EarningsStore.preview(draft:)` is already the right shape — substitute one
/// `ShiftInput` into the last inputs and re-run the same ledger — but it reads
/// `FetchDescriptor<ShiftRecord>`, and nothing writes `ShiftRecord` on a device
/// until PR 2 S7 lands. So on Tyler's phone `earningsStore.preview(draft:)`
/// substitutes a draft into an EMPTY input set: the draft's own workweek would
/// contain nothing but the draft, and every overtime hour it actually earned
/// would vanish from the header while the saved row (which reads the legacy
/// rows through `LegacySnapshotBridge`) showed them. That is the exact
/// disagreement PR 5 exists to remove, in the one place a person is looking
/// straight at both numbers.
///
/// This is the bridge's `preview(draft:)`: the same substitution, over the
/// legacy rows `LegacySnapshotBridge` already values. **Delete it with the
/// bridge when S7 lands**; the replacement is `earningsStore.preview(draft:)`
/// and nothing above it changes.
///
/// ## The one thing that makes the header equal the saved row
///
/// The draft is not described to the engine in its own dialect. It is written
/// as the `TipEntry` rows the app's writers will persist — `ShiftWriter.insertShift`
/// for a new shift, `commitLiveEdit`/`pruneZeroedRows` for an edit — and then
/// valued through `LegacySnapshotBridge.shiftInput(for:)`: the same function, on
/// the same shaped rows, that the saved shift will go through a second later. So
/// "pre-save equals post-save" is true by construction rather than by two
/// implementations agreeing.
///
/// Both writers, not just the insert. They disagree about one shape and it is a
/// shape people reach: `insertShift` writes no row at all for $0 of tips, while
/// the edit path keeps a single zero-cents anchor row carrying the hours, the
/// tip-out and the punches. Restating only the insert's rule made the preview
/// refuse a shift that exists and the ledger values — see `rows(...)`.
///
/// That matters more than it sounds. A header that recomputed the split itself
/// would have to re-derive the receipt v1/v2 normalization, which
/// `design-lint.sh` rule 12 forbids for a reason: the edit path moves the whole
/// gratuity to the other kind while the read path subtracts it from the owner
/// row only, and the two answers are $22.00 apart on the N4 shape.
/// `TipBreakdown.total(of:)` sees the draft rows exactly as it will see the
/// saved ones, so there is no second rule to keep in step.
///
/// ## What it does NOT carry
///
/// The same two absences as the bridge: no `paychecks` and no `schedule`, so
/// `payPeriod(_:)` is not answerable off a preview snapshot. The log sheet asks
/// `shift(_:)` and `valuation(_:)`, which read neither.
enum ShiftDraftPreview {
    /// The draft's unsaved `TipEntry` rows, in the shape the app's writers
    /// persist them: `ShiftWriter.insertShift` for a new shift, and
    /// `commitLiveEdit` + `pruneZeroedRows` for an edit.
    ///
    /// Un-inserted models: they are never handed to a `ModelContext`, they
    /// exist only so `ShiftDetails.resolve` and `TipBreakdown.total` can read
    /// the draft with the rules they already apply to saved rows.
    ///
    /// - Parameters:
    ///   - recordedAt: the recording time the SAVE will use, because it is a
    ///     tiebreaker in the ledger's within-workweek ordering
    ///     (`CompensationLedger.canonicalKey`) and therefore in the cumulative
    ///     rounding. For a new shift that is `now`; for an edit it is the
    ///     existing shift's own recording time, so substituting the draft does
    ///     not move it in its week.
    static func rows(
        date: Date,
        cashCents: Int,
        creditCents: Int,
        note: String? = nil,
        recordedAt: Date,
        shiftID: UUID,
        hoursWorked: Double?,
        tipOutCents: Int,
        salesCents: Int,
        shiftPeriod: ShiftPeriod?,
        clockIn: Date?,
        clockOut: Date?,
        serverCount: Int?,
        receiptMetrics: ShiftReceiptMetrics?
    ) -> [TipEntry] {
        // Clamped and zero-normalized exactly as saveNew/ShiftWriter do, so
        // the preview is not valuing a shift the save would not write.
        let normalizedDate = Calendar.current.startOfDay(for: min(date, .now))
        var rows: [TipEntry] = []
        if cashCents > 0 {
            rows.append(TipEntry(date: normalizedDate, amountCents: cashCents, kind: .cash, note: note, recordedAt: recordedAt, shiftID: shiftID))
        }
        if creditCents > 0 {
            rows.append(TipEntry(date: normalizedDate, amountCents: creditCents, kind: .credit, note: note, recordedAt: recordedAt, shiftID: shiftID))
        }
        // A shift with details and no money is a REAL persisted shape, so the
        // preview has to be able to value it. `ShiftWriter.insertShift` is not
        // the only writer of these rows: the EDIT path is `commitLiveEdit`,
        // which writes `row.amountCents = cents` and never deletes the anchor,
        // and `pruneZeroedRows` deliberately keeps it ("Every row is zero: keep
        // the anchor"). So a saved shift carrying 10 hours and $0 of tips
        // exists on disk as a single zero-cents row holding every shift-level
        // detail — and without this the preview had no rows at all, which made
        // `draftInput` nil, the snapshot nil, and the sheet's own header render
        // "-" over a shift Dashboard was showing at $100.00 through this very
        // same bridge. Same shift, two surfaces, two answers, and the blank one
        // was the screen you opened to edit it.
        //
        // `.credit` is the kind `ShiftDetails.detailRanked` puts first, so this
        // is the row `ShiftDetails.write` below lands the details on and the
        // row `resolve` reads them back from. The kind changes no figure: a
        // zero-cents row contributes zero to both `TipBreakdown` components and
        // the receipt owner is resolved by payload, not by kind.
        //
        // `shiftPeriod` and `salesCents` deliberately do NOT count as details
        // here. A brand-new sheet opened today already has an inferred
        // `shiftPeriod`, and neither field can move a cents figure, so treating
        // either as substance would put "$0.00 / Total" on an untouched sheet —
        // exactly the zero-standing-for-unknown rule 4 forbids.
        let hasShiftSubstance = hoursWorked != nil
            || tipOutCents > 0
            || clockIn != nil
            || clockOut != nil
            || receiptMetrics != nil
        if rows.isEmpty, hasShiftSubstance {
            rows.append(TipEntry(date: normalizedDate, amountCents: 0, kind: .credit, note: note, recordedAt: recordedAt, shiftID: shiftID))
        }
        ShiftDetails.write(
            hoursWorked: hoursWorked,
            tipOutCents: tipOutCents > 0 ? tipOutCents : nil,
            salesCents: salesCents > 0 ? salesCents : nil,
            shiftPeriod: shiftPeriod,
            clockIn: clockIn,
            clockOut: clockOut,
            serverCount: serverCount,
            receiptMetrics: receiptMetrics,
            into: rows,
            at: recordedAt
        )
        return rows
    }

    /// The id an EDIT has to substitute its draft under: the id the HISTORY
    /// snapshot keys that shift by.
    ///
    /// A pure function of the anchor row, so the sheet can seed it in `init`
    /// and be correct on its FIRST body pass, with no dependence on a @Query
    /// having loaded. Get it wrong and `EarningsInputs.substituting(_:)` finds
    /// no match and APPENDS: the shift being edited then exists twice in its
    /// own workweek, doubling its hours and handing the draft overtime it did
    /// not earn.
    ///
    /// For a legacy row with no `shiftID` the answer is
    /// `ShiftDays.deterministicShiftID(for:)`, which is what
    /// `ShiftDays.groupedByShift` (and therefore `LegacySnapshotBridge`) falls
    /// back to, and what `MigrationRunner.backfillShiftIDs` will eventually
    /// write onto the row. One rule, three places, already agreed.
    static func editDraftShiftID(for entry: TipEntry, calendar: Calendar = .current) -> UUID {
        entry.shiftID ?? ShiftDays.deterministicShiftID(for: entry.date, calendar: calendar)
    }

    /// One `ShiftInput` for the draft, through the bridge's own per-shift rule.
    ///
    /// Nil when the draft has no rows at all (nothing typed yet), which is a
    /// draft the save would refuse too.
    static func draftInput(rows: [TipEntry], shiftID: UUID, payrollTimeZone: TimeZone) -> ShiftInput? {
        guard let day = rows.map(\.date).min() else { return nil }
        return LegacySnapshotBridge.shiftInput(
            for: (day: day, shiftID: shiftID, items: rows),
            payrollTimeZone: payrollTimeZone
        )
    }

    /// The snapshot the app would hold if `draft` were saved.
    ///
    /// `entries` is the live legacy history (the sheet's `allEntries`). The
    /// draft replaces the shift sharing its `shiftID` — the edit case — or is
    /// appended when it is new, which is `EarningsInputs.substituting(_:)`, the
    /// same substitution `EarningsStore.preview(draft:)` performs.
    ///
    /// Nil when the draft is empty, or when the inputs cannot be canonically
    /// fingerprinted. Both are refusals, and rule 4 says the screen renders a
    /// placeholder for them rather than a zero.
    /// The civil days that can move the draft's own figure: its OWN workweek,
    /// and nothing else.
    ///
    /// `CompensationLedger.evaluate` buckets by `(calendar policy, workweek
    /// start)` and values each bucket independently, and the boundary rule
    /// makes a workweek spanning two calendar policies unrepresentable. So a
    /// shift's valuation is a pure function of its workweek's shifts and the
    /// policies — no shift outside that week can change it.
    ///
    /// This is a WINDOW ON THE INPUTS, never a restatement of a money rule.
    /// The weekday comes from `policies.calendar(on:)`, the effective-dated
    /// lookup the ledger itself uses (never `latestCalendar`, which is
    /// `calendars.last` and can be a QUEUED FUTURE policy), and
    /// `startOfWorkweek(startingOn:)` is the engine's own function. That it
    /// changes no figure is measured, not argued:
    /// `LogShiftPreviewWindowTests` asserts the windowed preview and a preview
    /// over the whole history produce the identical figure, label and caption.
    ///
    /// Why bother: MEASURED at 0.245s to build a preview over a 10,000-row
    /// history, and this path runs on every keystroke, not once per render. The
    /// window takes it to 0.001s. Nil when no calendar policy is in effect on
    /// the draft's day, in which case the ledger has no workweek to allocate
    /// into and reports `.unavailable(.noCalendarPolicy)` for every wage — the
    /// whole history is then no more informative than the draft alone, so the
    /// caller passes everything and the answer is the same either way.
    static func workweek(containing day: CivilDay, policies: CompensationPolicies) -> DayRange? {
        guard let calendar = policies.calendar(on: day) else { return nil }
        let start = day.startOfWorkweek(startingOn: calendar.workweekStartWeekday)
        return DayRange(start: start, end: start.adding(days: 6))
    }

    /// There is deliberately no `asOf` parameter. The draft's own figure is
    /// never a period-to-date total, and a shift dated today can sit after
    /// `now` in the payroll zone; clamping would make the draft unselectable
    /// and the header would read as unavailable while the person typed into it.
    /// `EarningsSnapshot`'s own asOf rule exempts `day(_:)` and `shift(_:)` for
    /// the same reason.
    /// - Parameter window: the civil days to feed the ledger, defaulting to the
    ///   draft's own workweek. Pass nil to value the WHOLE history, which is
    ///   what `LogShiftPreviewWindowTests` does to prove the two agree.
    static func snapshot(
        draft: ShiftInput?,
        entries: [TipEntry],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        windowed: Bool = true
    ) -> EarningsSnapshot? {
        guard let draft else { return nil }
        let window = windowed ? workweek(containing: draft.workDay, policies: policies) : nil
        let groups = ShiftDays.groupedByShift(
            entries,
            shiftID: \.shiftID,
            date: \.date,
            period: \.shiftPeriod
        )
        let inputs = EarningsInputs(
            shifts: groups.compactMap { group -> ShiftInput? in
                // Filtered on the GROUP's work day, derived the way
                // `LegacyLedgerBridge.shiftInput` derives it (the earliest
                // row's civil day in the PAYROLL zone), so the filter and the
                // valuation cannot disagree about which week a shift is in.
                if let window {
                    guard let earliest = group.items.map(\.date).min(),
                          window.contains(CivilDay(earliest, in: payrollTimeZone))
                    else { return nil }
                }
                return LegacySnapshotBridge.shiftInput(for: group, payrollTimeZone: payrollTimeZone)
            },
            rates: policies.rates,
            calendars: policies.calendars,
            asOf: CivilDay.distantFuture
        )
        return try? EarningsSnapshot.build(inputs.substituting(draft))
    }

    /// The same preview over the new representation.
    ///
    /// The draft still substitutes in by id, so the sheet's own figure is
    /// unchanged; what changes is the HISTORY it sits in. That history is not
    /// decoration here: `revealHistorySnapshot` feeds `StatsEngine`'s reveal
    /// comparison, which is what decides whether tonight is a personal
    /// record. Reading the legacy rows alone on a converted account would
    /// compare tonight against only the shifts logged BEFORE conversion, and
    /// since the deriver never writes a `TipEntry` back, that truncation is
    /// permanent. The reveal would then congratulate someone on a best night
    /// that was not one -- a false claim rather than a wrong total, which is
    /// the reveal's specific way of losing trust.
    @MainActor
    static func snapshot(
        draft: ShiftInput?,
        records: [ShiftRecord],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        windowed: Bool = true
    ) -> EarningsSnapshot? {
        guard let draft else { return nil }
        let window = windowed ? workweek(containing: draft.workDay, policies: policies) : nil
        let adapted = ShiftInputAdapter.adapt(records, calendars: policies.calendars)
        let inputs = EarningsInputs(
            // Filtered on the input's OWN `workDay`, which the adapter
            // already resolved in the payroll zone of the calendar policy
            // effective that day. The legacy arm above has to re-derive that
            // day from the earliest row; here it is already the answer, so
            // the filter and the valuation cannot disagree about the week.
            shifts: adapted.inputs.filter { input in
                guard let window else { return true }
                return window.contains(input.workDay)
            },
            rates: policies.rates,
            calendars: policies.calendars,
            asOf: CivilDay.distantFuture,
            unreadableReceiptShiftIDs: adapted.unreadableReceiptShiftIDs
        )
        return try? EarningsSnapshot.build(inputs.substituting(draft))
    }

    /// **The one entry point.** Takes both representations and resolves which
    /// to read; see `ShiftRepresentation`.
    @MainActor
    static func snapshot(
        draft: ShiftInput?,
        entries: [TipEntry],
        records: [ShiftRecord],
        policies: CompensationPolicies,
        payrollTimeZone: TimeZone,
        windowed: Bool = true,
        representation: ShiftRepresentation = .automatic
    ) -> EarningsSnapshot? {
        representation.usesRecords
            ? snapshot(draft: draft, records: records, policies: policies, payrollTimeZone: payrollTimeZone, windowed: windowed)
            : snapshot(draft: draft, entries: entries, policies: policies, payrollTimeZone: payrollTimeZone, windowed: windowed)
    }
}
