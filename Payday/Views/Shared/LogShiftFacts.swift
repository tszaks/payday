import Foundation

/// Everything the Log Shift / Edit Shift sheet says about the draft in front
/// of it, and nothing it computes.
///
/// The wave-1 adapter for `docs/METRICS.md` group 2.8, written to the contract
/// in `Payday/Earnings/SnapshotFacts.swift`. The four rules, and what each one
/// removed from this screen:
///
/// **Rule 1 — presentation only.** The sheet used to hold
/// `WageEstimate.shiftTotalCents(cashCents:creditCents:tipOutCents:wageCentsPerHour:hoursWorked:)`
/// plus `receiptMetrics.separatedGratuityFeesCents` in a computed property, and
/// that sum was the header. Two things were wrong with it and only one was
/// visible. The visible one: `WageEstimate.cents` is BASE RATE ONLY, so a shift
/// in a week that crosses the overtime threshold was quoted at straight time in
/// the header and then rendered by `ShiftDayRow` — already migrated in wave 0 —
/// at its ledger value a second later, on the very next screen. The invisible
/// one: a scalar `wageCentsPerHour` prices every shift at today's rate, so
/// backfilling a shift from before a raise quoted the new rate.
///
/// **Rule 2 — `EarningsSnapshot?` plus presentational inputs.** It takes the
/// PREVIEW snapshot (`ShiftDraftPreview`), which is the app's real history with
/// this draft substituted in, valued by the same ledger with the user's own
/// effective-dated policies. That is what makes the header equal the saved row:
/// same engine, same workweek, same rounding, same policies.
///
/// **Rule 3 — no `Key`, no `dataRevision`.** This screen never had either; it
/// re-rendered off `@State` directly. It carries `stamp` anyway, because the
/// stamp is what lets a test prove the header and the saved row were computed
/// from the same dataset rather than merely printing the same string.
///
/// **Rule 4 — figures, not cents.** The header renders `total.text` and
/// `total.label`, so a draft with no hours logged is headed "Known so far"
/// instead of "Shift total", and a draft the engine cannot value renders no
/// currency at all. The hardcoded "Shift total" is gone: it was not a label
/// `MetricID.earnedIncome.allowedLabels` sanctions, and it said "total" over a
/// figure that excluded an unpriced wage.
struct LogShiftFacts: Equatable, SnapshotFacts {
    // MARK: Presentation

    /// The draft's own minutes, by the adapter's one conversion
    /// (`WorkedMinutes.minutes(fromHours:)`). Equal to
    /// `snapshot.valuation(draftID).minutesWorked` whenever the valuation
    /// exists — pinned by `LogShiftFactsTests.draftMinutesAreTheEngineMinutes`
    /// — and held here so the hours caption still reads while the engine has
    /// no answer.
    let draftMinutes: Int?

    /// "Today · Dinner · 5:02 – 11:41 PM · $15 tipped out" (rows [LS-05],
    /// [LS-18]). Its tip-out clause is the ledger's, not the sheet's binding.
    let beliefLine: String

    // MARK: Money, from the engine

    /// The draft shift's earned income as the ledger valued it, with the label
    /// and caption its completeness allows (row [LS-01]).
    ///
    /// Built by `EarningsFigure.shiftEarnedIncome`, the SAME constructor
    /// `ShiftDayRowFacts` uses, so the header and the row the save produces are
    /// one function of one valuation rather than two functions that agree.
    let total: EarningsFigure

    /// "$47/hr", or nil when the draft has no minutes to divide by and when
    /// there is no figure to divide (row [LS-02]).
    ///
    /// `EarningsResult.hourlyRateCents` — `MetricID.hourlyRate`, integer
    /// half-up over `coveredComponents` — replacing
    /// `Int((Double(shiftTotalCents) / hoursWorked).rounded())` in the view
    /// body. The engine's numerator is wage-inclusive and net of tip-out, the
    /// same basis the old division used, so this is the same question asked of
    /// the one thing allowed to answer it.
    let hourlyRateText: String?

    /// "6h 23m · $18.06 wages", or just "6h 23m" when the shift carries no
    /// valued wage (rows [LS-06], [LS-07]).
    ///
    /// The wages term is `valuation.components.wagesCents`, this shift's slice
    /// of the WORKWEEK allocation. The old caption was base-rate only and said
    /// so in a comment ("overtime is a weekly calculation that can't be
    /// attributed to a single shift"); the ledger does attribute it, per shift,
    /// and the per-shift figures telescope to the week total. So the caveat is
    /// retired rather than restated, and the caption now sums to the header.
    let hoursCaption: String?

    /// Whether the figure contains wages or mandatory gratuity, so the reveal
    /// never calls an all-in number "in tips" (rows [LS-13], [LS-16]).
    ///
    /// Read off the valuation (`wage.isValued`, `components.gratuityFeesCents`)
    /// rather than off the sheet's own `wageCents != nil || gratuity > 0`,
    /// because the engine is the only thing that knows whether a wage was
    /// actually priced: hours with no rate policy in effect produce no wage,
    /// and the old test could not see that.
    let includesNonTipIncome: Bool

    let stamp: SnapshotStamp?

    // MARK: Construction

    /// - Parameters:
    ///   - snapshot: `ShiftDraftPreview.snapshot(...)`, the history with this
    ///     draft substituted in. Nil while there is nothing typed yet or when
    ///     the inputs would not fingerprint; both render as unavailable.
    ///   - draftID: the id the draft was substituted under, so
    ///     `valuation(draftID)` hits.
    ///   - hoursWorked: the draft's decimal hours, the sheet's own `@State`.
    ///     This is a DURATION, not money — rule 2 bans `wageCentsPerHour` and
    ///     `firstWeekday` on a facts struct, not the length of a shift.
    init(
        snapshot: EarningsSnapshot?,
        draftID: UUID,
        date: Date,
        shiftPeriod: ShiftPeriod?,
        clockIn: Date?,
        clockOut: Date?,
        hoursWorked: Double?,
        calendar: Calendar = .current,
        now: Date = .now
    ) {
        let valuation = snapshot?.valuation(draftID)
        let result = snapshot?.shift(draftID)

        self.draftMinutes = hoursWorked.map(WorkedMinutes.minutes(fromHours:))
        self.stamp = snapshot?.stamp
        self.total = EarningsFigure.shiftEarnedIncome(
            valuation,
            wageFeatureEnabled: snapshot?.wageFeatureEnabled ?? false
        )
        self.beliefLine = ShiftBeliefLine.compose(
            date: date,
            shiftPeriod: shiftPeriod,
            clockIn: clockIn,
            clockOut: clockOut,
            tipOut: valuation,
            calendar: calendar,
            now: now
        )
        self.includesNonTipIncome = (valuation?.wage.isValued ?? false)
            || (valuation?.components.gratuityFeesCents ?? 0) > 0

        // The rate line stays hidden for a figure the engine could not
        // produce: an "$X/hr" over an unavailable total would be a currency
        // string standing in for "no idea", which is the one thing rule 4
        // makes unspellable on the headline and must not reappear underneath
        // it. Kept behind a positive figure too, exactly as before, so an
        // untouched sheet does not open with "$0/hr".
        if let rateCents = result?.hourlyRateCents, let cents = self.total.cents, cents > 0 {
            self.hourlyRateText = "\(Money.wholeDollarString(fromCents: rateCents))/hr"
        } else {
            self.hourlyRateText = nil
        }

        if let minutes = draftMinutes {
            let label = WorkedMinutes.hoursLabel(minutes: minutes)
            if case .valued(let wage, _) = valuation?.wage {
                self.hoursCaption = "\(label) · \(Money.string(fromCents: wage.wagesCents)) wages"
            } else {
                self.hoursCaption = label
            }
        } else {
            self.hoursCaption = nil
        }
    }
}
