import Foundation

/// What the engine would say about a shift that has not been saved yet.
///
/// ## Why this exists
///
/// `EarningsStore.preview(draft:)` is the same shape — substitute one
/// `ShiftInput` into the last inputs and re-run the same ledger — but the
/// log sheet needs its draft valued against the rows on THIS screen, with
/// the draft's own workweek windowed for keystroke cost. This is that
/// substitution, one step upstream.
///
/// ## The one thing that makes the header equal the saved row
///
/// The draft is not described to the engine in its own dialect. It is built
/// as the `ShiftRecord` the save will write — `ShiftCommands.create`'s raw
/// fields for a new shift, `commitLiveEdit`'s `applyEarnings` fold for an
/// edit — and then adapted through `ShiftInputAdapter`, the same function
/// the saved record goes through a second later. So "pre-save equals
/// post-save" is true by construction rather than by two implementations
/// agreeing. A header that recomputed the split itself would have to
/// re-derive the receipt v1/v2 normalization, which `design-lint.sh` rule
/// 12 forbids.
///
/// ## What it does NOT carry
///
/// No `paychecks` and no `schedule`, so `payPeriod(_:)` is not answerable
/// off a preview snapshot. The log sheet asks `shift(_:)` and
/// `valuation(_:)`, which read neither.
enum ShiftDraftPreview {
    /// The draft's `ShiftInput`, built the way the save will build it.
    ///
    /// The fields are written onto a transient `ShiftRecord` -- never
    /// handed to a `ModelContext` -- and then adapted through
    /// `ShiftInputAdapter`, so the preview values the draft under exactly
    /// the rules the saved record will be read back under.
    ///
    /// - Parameters:
    ///   - recordedAt: the recording time the SAVE will use, because it is a
    ///     tiebreaker in the ledger's within-workweek ordering
    ///     (`CompensationLedger.canonicalKey`) and therefore in the cumulative
    ///     rounding. For a new shift that is `now`; for an edit it is the
    ///     existing shift's own recording time, so substituting the draft does
    ///     not move it in its week.
    ///   - normalizeEarnings: whether the receipt v1/v2 fold runs. An EDIT
    ///     saves through `applyEarnings`, which normalizes; a NEW shift saves
    ///     through `ShiftCommands.create`, which stores the fields raw. The
    ///     caller passes which writer it is previewing.
    @MainActor
    static func draftInput(
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
        receiptMetrics: ShiftReceiptMetrics?,
        normalizeEarnings: Bool,
        policies: CompensationPolicies
    ) -> ShiftInput? {
        // A draft the save would refuse is a draft the preview refuses:
        // `create` guards on `hasSomethingToSave`, and a shift carrying only
        // details still has substance to value.
        let hasShiftSubstance = cashCents > 0
            || creditCents > 0
            || hoursWorked != nil
            || tipOutCents > 0
            || clockIn != nil
            || clockOut != nil
            || receiptMetrics != nil
        guard hasShiftSubstance else { return nil }

        let record = ShiftRecord(
            id: shiftID,
            workDate: Calendar.current.startOfDay(for: min(date, .now)),
            shiftPeriod: shiftPeriod,
            cashTipsCents: cashCents,
            creditTipsCents: creditCents,
            tipOutCents: tipOutCents > 0 ? tipOutCents : nil,
            salesCents: salesCents > 0 ? salesCents : nil,
            hoursWorked: hoursWorked,
            clockIn: clockIn,
            clockOut: clockOut,
            serverCount: serverCount,
            receiptMetrics: receiptMetrics,
            note: note,
            recordedAt: recordedAt
        )
        if normalizeEarnings {
            // Mirrors `commitLiveEdit`: `.credit` is the owner, and the fold
            // is INERT for anything a record already carries v2-style.
            record.applyEarnings(
                cashCents: cashCents,
                creditCents: creditCents,
                metrics: receiptMetrics,
                metricsOwner: .credit
            )
        }
        return ShiftInputAdapter.input(from: record, calendars: policies.calendars)
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
    ///
    /// The draft substitutes in by id; the HISTORY it sits in comes from
    /// `ShiftRecord`s, the only stored shape since the flip. That history is
    /// not decoration here: `revealHistorySnapshot` feeds `StatsEngine`'s
    /// reveal comparison, which is what decides whether tonight is a personal
    /// record. Reading the rows logged before conversion alone would compare
    /// tonight against a permanently truncated history -- a false claim
    /// rather than a wrong total, which is the reveal's specific way of
    /// losing trust.
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
}
