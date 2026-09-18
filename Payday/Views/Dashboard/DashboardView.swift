import Combine
import SwiftUI
import SwiftData
import TipKit

/// The latest wall-clock a shift was logged, for ordering today's shifts —
/// falls back to the shift's date when no recordedAt was captured.
private func shiftRecordedAt(_ items: [TipEntry]) -> Date {
    items.compactMap(\.recordedAt).max() ?? items.map(\.date).max() ?? .distantPast
}

/// Everything the Dashboard shows, and nothing it computes.
///
/// A PR 5 wave 1 adapter, to the contract in `Payday/Earnings/SnapshotFacts.swift`:
/// presentation on this struct, every cents figure out of one
/// `EarningsSnapshot`, and no money arithmetic anywhere between them. Read
/// that header before changing this file; the four rules each cost a measured
/// defect.
///
/// ## What moved, and what it closed
///
/// Before wave 1 this struct held eleven loose `Int`s and derived the hero
/// from three sources at once: `StatsEngine.periodToDateTotal` for the tips
/// (clamped to today), `TipBreakdown.total(of:)` for the cash/credit/gratuity
/// split (whole period, unclamped) and `PeriodIncome.wages` for the wages
/// (whole period, scalar weekday). `docs/METRICS.md` [DB-21] names the
/// consequence: "the drawer's component rows are whole-period and the total
/// is asOf-today tips + whole-period wages", i.e. a drawer whose rows could
/// not be made to sum to the bottom line it printed them under. The tip-out
/// was not read at all — it was BACK-DERIVED as
/// `max(0, cash + credit + gratuity - net)`, so any rounding disagreement
/// upstream became a phantom "Tipped out" row.
///
/// Now there is one query per figure group and one `EarningsResult` behind
/// the whole hero: `snapshot.range(heroPeriod, asOf: today)`. Its components ARE the
/// drawer rows (`BreakdownRow.ledgerRows(_:)`), its `earnedIncome` IS the
/// face figure (`EarningsFigure.earnedIncome(_:)`), its `tipOutCents` IS the
/// "Tipped out" row, and its label comes from `CompletenessCopy` rather than
/// from this file writing `tipOut > 0 ? "You kept" : "Total"` a sixth time.
/// One selection, one clamp, one workweek: rows that sum to their total by
/// construction.
///
/// ## The snapshot spans the whole dataset, on purpose
///
/// Wave 0 built Dashboard's snapshot over the CURRENT PERIOD's shifts only
/// and said so: "a workweek straddling the period edge still under-reports
/// overtime" (`docs/METRICS.md`, 2.3 after wave 0, row [SC-01]). The ledger
/// allocates the overtime threshold across the complete workweek of the
/// shifts it is handed, so handing it fourteen days cannot price the
/// forty-first hour of a week that began before day one.
/// `DashboardEarnings.build` covers the whole local history instead, which is
/// also what lets the hero follow a CLOSED period (the morning after a pay
/// period ends) and lets the payday card read the closed period it is
/// reporting on.
///
/// ## The cutoff is a query argument, and the hero says so
///
/// The dataset is UNCLAMPED, matching History, Calendar and the log preview,
/// so every screen's stamp is the same stamp and a disagreement between two
/// of them stays diffable (contract rule 3). Dashboard's period-to-date
/// cutoff is therefore an `asOf:` argument on one query rather than a
/// property of its copy of the data — and `heroDeferredShiftCount` makes the
/// narrower scope visible, because a hero that quietly excludes a shift whose
/// own row is right underneath it is two answers to one question.
///
/// ## Membership is the engine's, not an entry-date filter
///
/// `PayPeriodCalculator.period(containing:)` returns `end` as the START of
/// the period's last day, and the old `allEntries.filter { $0.date >=
/// period.start && $0.date <= period.end }` therefore dropped every shift
/// logged at a real hour on that last day — while `StatsEngine
/// .periodToDateTotal`, which compares civil days, kept them. MEASURED in
/// `DashboardPeriodParityTests`: the Shifts list omitted the final day's
/// shift while the hero above it counted the money. Both sides now select by
/// civil work day through `DayRange`, which is the engine's own membership
/// rule, so the list and the total cannot disagree about which shifts the
/// period holds.
/// Internal, not private, for one reason: `DashboardPeriodParityTests` builds
/// one and compares its hero against `PeriodsPageFacts`' row and
/// `PeriodDetailFacts`' hero. The plan's completion rule 2 is "its parity test
/// passes against the **real adapter**, not a helper", and a `private` adapter
/// can only be parity-tested against a copy of itself.
struct DashboardFacts: SnapshotFacts {
    // MARK: Presentation

    let calculator: PayPeriodCalculator
    /// The current period's entries, selected by the same civil-day range the
    /// hero's query uses. Drives the empty state and the screenshot hook
    /// only; nothing reads money off it.
    let periodEntries: [TipEntry]
    let daysRemaining: Int
    /// The period the hero number represents — usually the current one, but
    /// the just-finished one on the morning after a close, while the new
    /// period is still empty, so a $0.00 hero never sits above a "complete"
    /// card.
    let heroPeriod: PayPeriod
    let heroLabel: String
    let heroPayDate: Date
    let heroIsCurrent: Bool
    /// The `end` of the period the payday moment is showing, so the dismiss
    /// button can remember which one was closed.
    let paydayPeriodEnd: Date?
    /// Which of the card's two moments this is: the day or two after the period
    /// closed, or the day the check actually lands. nil when the card is not
    /// showing at all.
    let paydayPhase: PaydayMoment.Phase?
    let shiftCount: Int
    let shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])]
    /// Calendar days that hold 2+ shifts — a "double" — so a row can label
    /// itself "Today · Lunch" / "Today · Dinner" only when it needs to.
    let multiShiftDays: Set<Date>
    let paceDeltaCents: Int?
    /// How many prior periods back the pace line. 1 means it's still a
    /// single-period comparison and the copy says "last period" instead of
    /// "your usual pace."
    let pacePeriodCount: Int
    let isPaydayMoment: Bool
    let tonightLine: String?

    // MARK: Money, from the engine

    /// The dataset every figure below was selected out of. Held so each shift
    /// row can ask for its own valuation by the id it renders under.
    let snapshot: EarningsSnapshot?

    /// The hero face: `MetricID.earnedIncome` over the hero period, clamped
    /// to today, labelled and captioned by its own `Completeness`. Renders no
    /// currency at all when the engine could not answer (rule 4).
    let hero: EarningsFigure
    /// How many shifts the hero period holds that its to-date clamp excluded
    /// — shifts dated after today. A COUNT, not money: the figures all still
    /// come from the engine, and this only decides whether the hero has to
    /// say that it is not the whole period.
    ///
    /// MEASURED, and the reason it exists: a biweekly period whose only
    /// shift was dated two days ahead rendered `heroText "$0.00"`, `label
    /// "Total"`, `caption nil`, state `.noShifts` — directly above that
    /// shift's own row reading $394.00, because `valuation(_:)` is
    /// deliberately unclamped. The empty-state sentence the `$0.00`
    /// deferral leans on ("No shifts this period.") is gated on
    /// `periodEntries.isEmpty`, which is false in that state, so nothing on
    /// screen explained the zero. It was also a regression: the superseded
    /// hero printed 14400 for the same input.
    let heroDeferredShiftCount: Int
    /// The drawer's itemization, straight off the same `EarningsResult` the
    /// hero is — so "Cash tips + Credit tips + Gratuity + Wages - Tipped out"
    /// reconciles to the bottom line by construction, not by agreement.
    let heroBreakdownRows: [BreakdownRow]
    /// The drawer's emphasized bottom line, whose LABEL is
    /// `CompletenessCopy.earnedIncomeLabel` — so a partial period reads
    /// "Known so far" and can no longer print "Total".
    let heroBreakdownTotal: BreakdownRow
    /// The collapsed lip. Nil when there is no dataset behind it.
    let heroLipText: String?
    let heroHasBreakdown: Bool

    /// `MetricID.expectedPaycheckGross` for the period the payday card is
    /// reporting on. `.unavailable` when no card is showing, which is also
    /// every case in which nothing renders it.
    let predictedPaycheck: EarningsFigure
    /// `MetricID.voluntaryTips`, cash component, same period and same query
    /// as `predictedPaycheck` — the gap between "You kept" and the check.
    let paydayCash: EarningsFigure

    let stamp: SnapshotStamp?

    // MARK: Construction

    /// - Parameters:
    ///   - snapshot: the dataset, built once by the caller and cached there.
    ///     Optional per rule 2: nil is "no dataset stands behind this", not
    ///     "zero", and every figure on this struct renders as unavailable for
    ///     it.
    ///   - allShifts: the SAME grouping `snapshot` was built from, which is
    ///     why both arrive from one `DashboardEarnings.Dataset`. This struct
    ///     deliberately does not group anything itself: it used to, with the
    ///     payroll-zone calendar, while the snapshot was built with the
    ///     device's, and a legacy row with no `shiftID` therefore got a
    ///     different deterministic id from the two and its valuation lookup
    ///     missed (see `DashboardEarnings`). Presentation and `StatsEngine`
    ///     inputs only; no cents figure on this struct is derived from it.
    ///   - schedule: the pay-period GRID. It decides which days a period
    ///     covers and NOTHING about money — PR 3 severed its `firstWeekday`
    ///     from the workweek that owns overtime, which lives in
    ///     `CompensationPolicies` and reached this struct inside `snapshot`.
    init(
        snapshot: EarningsSnapshot?,
        allShifts: [(day: Date, shiftID: UUID, items: [TipEntry])],
        schedule: PaySchedule?,
        now: Date,
        forcedPaydayPhase: PaydayMoment.Phase?,
        dismissedClosedEnd: Date?,
        dismissedCheckEnd: Date?,
        payrollTimeZone: TimeZone
    ) {
        // One calendar for this whole screen, in the FROZEN payroll zone.
        // It is the same one `DashboardEarnings.build` grouped `allShifts`
        // with — the caller's, not a second construction — because this
        // struct no longer groups anything. See that type's header for the
        // measured id mismatch two groupings produced.
        let calendar = PayrollCalendar.gridCalendar(in: payrollTimeZone)

        self.snapshot = snapshot
        stamp = snapshot?.stamp
        calculator = PayPeriodCalculator(payrollTimeZone: payrollTimeZone, schedule: schedule ?? .fallback)
        let period = calculator.period(containing: now)
        daysRemaining = calculator.daysRemaining(from: now)

        // Membership by civil work day, which is the engine's rule. See the
        // type header for the final-day shifts the old entry-date filter
        // dropped.
        let currentRange = Self.range(of: period, in: payrollTimeZone)
        let periodShifts = allShifts.filter {
            currentRange.contains(CivilDay($0.day, in: payrollTimeZone))
        }
        shiftDays = periodShifts
        periodEntries = periodShifts.flatMap(\.items)
        // A "shift" counts closeouts, not calendar days.
        shiftCount = periodShifts.count
        // Days that hold more than one shift — the emergent doubles.
        var dayCounts: [Date: Int] = [:]
        for shift in periodShifts { dayCounts[shift.day, default: 0] += 1 }
        multiShiftDays = Set(dayCounts.filter { $0.value >= 2 }.keys)

        // Every entry, read back out of the grouping rather than taken as a
        // second parameter: one input cannot disagree with itself about which
        // rows the screen holds. `StatsEngine` sorts its own records, so the
        // grouping's order is not an input to anything.
        let tipRecords = allShifts.flatMap(\.items).map(TipRecord.init)
        let statsEngine = StatsEngine(payrollTimeZone: payrollTimeZone, records: tipRecords, calendar: calendar)

        // Measured against the MEDIAN of the last several periods at this
        // same point, not against whichever single period happened to come
        // before this one — one period is a sample size of one, and a single
        // big Saturday in it would read as a real trend. Hidden entirely
        // until some prior period has a record; a brand-new user has no
        // "usual" to be ahead of. See StatsEngine.usualPaceBaseline.
        //
        // Still a `StatsEngine` fact, and deliberately so: the pace line is
        // `analytics:paceComparison` ([DB-04]) and both of its sides are
        // `nonWageEarnings`. One basis on both sides is the property that
        // makes a delta mean anything, and moving only this screen's half of
        // it onto `earnedIncome` would compare a wage-inclusive present
        // against a wage-exclusive past. Group 2.6 owns the engine-wide
        // move.
        let comparison = statsEngine.paceComparison(
            currentPeriod: period,
            priorPeriods: calculator.priorPeriods(before: period, count: StatsEngine.paceLookbackPeriods),
            asOf: now
        )
        paceDeltaCents = comparison?.deltaCents
        pacePeriodCount = comparison?.periodCount ?? 0

        // The payday card belongs to a FINISHED period, and shows twice: the
        // day or two after its last shift, then again the day the check lands
        // (see PaydayMoment). Never on a day still workable.
        // forcedPaydayPhase is the DEBUG screenshot hook and pins it to the
        // current period regardless.
        let moment: PaydayMoment.Moment?
        if let forcedPaydayPhase {
            moment = PaydayMoment.Moment(period: period, phase: forcedPaydayPhase)
        } else {
            moment = PaydayMoment.moment(now: now, calculator: calculator, dismissedClosedEnd: dismissedClosedEnd, dismissedCheckEnd: dismissedCheckEnd)
        }
        // Nothing to show if that period had no earnings. The gate is
        // `earnedIncome` now, not tips-net: fixture Z1 is a period that was
        // worked for wages and tipped nothing, and the old gate suppressed
        // its "Your check should show" card even though the check is real
        // money ([DB-03]).
        //
        // `asOf` is an ARGUMENT here, not a property of the dataset. The
        // snapshot is built unclamped (`DashboardEarnings.build`) so that
        // Dashboard and History share one stamp over one dataset; the
        // period-to-date cutoff is Dashboard's own scope and it is spelled
        // once, here. MEASURED before this: the snapshot carried `asOf: now`
        // and History's carried `.distantFuture`, so the same current period
        // read 40400 here and 79800 there under the same label, with
        // different digests.
        let toDate = CivilDay(now, in: payrollTimeZone)
        let currentResult = snapshot?.range(currentRange, asOf: toDate)
        // The payday card's period is CLOSED, so its query takes no cutoff:
        // `now` is already past the period's end and a clamp would be a
        // no-op that only looks like a scope.
        let paydayResult = moment.flatMap { candidate -> (PaydayMoment.Moment, EarningsResult)? in
            guard let result = snapshot?.range(Self.range(of: candidate.period, in: payrollTimeZone)),
                  result.knownComponents.earnedIncomeCents > 0
            else { return nil }
            return (candidate, result)
        }
        let paydayMoment = paydayResult?.0
        let paydayPeriod = paydayMoment?.period
        isPaydayMoment = paydayPeriod != nil
        paydayPeriodEnd = paydayPeriod?.end
        paydayPhase = paydayMoment?.phase

        // On the morning after a close the new period is still empty; lead
        // with the period that just finished so a $0.00 hero never sits
        // above its own "complete" card. Once the new period has earnings,
        // the hero follows it and the completed card rides along below.
        //
        // "Empty" is the wage-inclusive figure ([DB-02] asks for exactly
        // that): a period worked for wages with no tips yet is not empty,
        // and the old tips-only gate read it as empty and pushed the hero
        // back onto last period while wages sat unread underneath.
        //
        // With no snapshot there is nothing to compare, so the hero stays on
        // the current period and renders as unavailable rather than silently
        // relabelling itself "Last pay period".
        let heroResult: EarningsResult?
        if let pay = paydayPeriod, let payResult = paydayResult?.1,
           currentResult?.knownComponents.earnedIncomeCents == 0, pay != period {
            heroPeriod = pay
            heroLabel = "Last pay period"
            heroPayDate = calculator.payDate(for: pay)
            heroIsCurrent = false
            heroResult = payResult
        } else {
            heroPeriod = period
            heroLabel = "This pay period"
            heroPayDate = calculator.payDate(for: period)
            heroIsCurrent = true
            heroResult = currentResult
        }

        // How much of the hero period the to-date clamp left out, as a count
        // of shifts. Both sides are the engine's own selection over the same
        // snapshot: `valuations(in:)` is unclamped, `result.shiftIDs` is what
        // the clamped query actually summed. See `heroDeferredShiftCount`.
        let heroRange = Self.range(of: heroPeriod, in: payrollTimeZone)
        let heroShiftsInPeriod = snapshot.map { $0.valuations(in: heroRange).count } ?? 0
        let deferredShiftCount = max(0, heroShiftsInPeriod - (heroResult?.shiftIDs.count ?? 0))
        heroDeferredShiftCount = deferredShiftCount

        // ONE EarningsResult behind the whole hero: the face figure, the
        // drawer's rows, the drawer's bottom line and the collapsed lip.
        // Nothing here adds, subtracts, scales or rounds a cents value; the
        // four `BreakdownRow` builders are wave 0's shared composition and
        // this is their first production caller ([SC-02], [SC-03]).
        if let heroResult {
            let figure = Self.declaringDeferral(
                EarningsFigure.earnedIncome(heroResult),
                deferredShiftCount: deferredShiftCount
            )
            hero = figure
            heroBreakdownRows = BreakdownRow.ledgerRows(heroResult)
            // The drawer's bottom line takes its CENTS from wave 0's shared
            // builder either way. Its LABEL follows the face figure, so the
            // two cannot say two things about the same number — which is the
            // whole reason the face stopped saying "Total" here.
            let total = BreakdownRow.total(heroResult)
            heroBreakdownTotal = deferredShiftCount > 0
                ? BreakdownRow(figure.label, cents: total.cents, emphasized: true)
                : total
            heroLipText = BreakdownRow.lipText(heroResult)
            heroHasBreakdown = BreakdownRow.hasBreakdown(heroResult)
        } else {
            // A label is still owed even with no figure: VoiceOver reads it
            // next to the placeholder glyph. It comes from the figure so the
            // face and the drawer's bottom line cannot say two things.
            let unavailable = EarningsFigure.unavailable()
            hero = unavailable
            heroBreakdownRows = []
            heroBreakdownTotal = BreakdownRow(unavailable.label, cents: nil, emphasized: true)
            heroLipText = nil
            heroHasBreakdown = false
        }

        // The whole pre-tax check in one number, fed the components the
        // engine already wrote for that period rather than a second pass
        // over the same shifts. Never split into "$X, plus $Y in wages" on
        // screen — that left the person adding it up.
        //
        // No `predictedPayDate` here any more: it was stored and never
        // rendered. The card deliberately does not repeat the pay date,
        // because the progress bar a few lines above already labels where the
        // period ends ([DB-22]), and `heroPayDate` is what draws that.
        predictedPaycheck = PredictedPaycheck.figure(from: paydayResult?.1)
        // Cash tips in the payday-moment period — the ENTIRE gap between
        // "You kept" and the check, since cash is the one thing that never
        // runs through payroll. Named on the card so nobody has to subtract
        // two big numbers to find out why their check is smaller than what
        // they made (Tyler, on his own real period: "if i kept 3100 why
        // would my check be 2600?? cash?"). Same query as the check above,
        // so the two cannot be a cent apart.
        paydayCash = EarningsFigure(
            metric: .voluntaryTips,
            amount: paydayResult.map { .cents($0.1.knownComponents.voluntaryCashCents) } ?? .unavailable,
            label: "Cash tips",
            caption: nil,
            completeness: paydayResult?.1.completeness ?? .empty
        )

        // Echo of tonight's reveal verdict, for the most recently logged
        // shift today — consistent with the per-shift reveal shown at log
        // time, rather than summing a double day into one number.
        //
        // A shift speaks ONE number (Tyler's ruling, 2026-07-27), and it is
        // the engine's: the same `earnedIncome` the shift's own row prints
        // directly below this line, so "the echo and the row must reconcile
        // on sight" is true by construction and not by two derivations
        // agreeing. `.unavailable` prints no line at all rather than an echo
        // with a placeholder where the money goes.
        let todayShifts = periodShifts.filter { calendar.isDateInToday($0.day) }
        var tonightRevealText: String?
        if let latest = todayShifts.max(by: { shiftRecordedAt($0.items) < shiftRecordedAt($1.items) }),
           let valuation = snapshot?.valuation(latest.shiftID),
           let revealCents = EarningsFigure
               .shiftEarnedIncome(valuation, wageFeatureEnabled: snapshot?.wageFeatureEnabled ?? false)
               .cents {
            let details = ShiftDetails.resolve(from: latest.items)
            // The engine's per-shift figures on BOTH sides of the
            // comparison. Handing `StatsEngine` a scalar rate instead made
            // it price each prior shift on its own with
            // `WageEstimate.cents`, so a workweek's overtime and its
            // cumulative rounding reached the headline but not the record it
            // claimed to beat ([DB-25]: "inputs should be earnedIncome per
            // shift").
            let revealEngine = StatsEngine(
                payrollTimeZone: payrollTimeZone,
                records: tipRecords,
                calendar: calendar,
                valuedShiftCents: Self.valuedCents(in: snapshot)
            )
            let result = revealEngine.reveal(
                forNightAt: calendar.startOfDay(for: now),
                cents: revealCents,
                period: period,
                shiftID: latest.shiftID
            )
            let components = valuation.components
            tonightRevealText = "\(RevealCopy.headline(cents: revealCents, includesNonTipIncome: components.wagesCents > 0 || components.gratuityFeesCents > 0)) \(RevealCopy.comparison(for: result.comparison, period: details.shiftPeriod))"
        }
        tonightLine = TonightLine.compose(
            tonightRevealText: tonightRevealText,
            isPaydayMoment: isPaydayMoment
        )
    }

    /// A pay period as the civil days it covers. `PayPeriod.end` is the START
    /// of the last day, and the range is inclusive of that whole day.
    private static func range(of period: PayPeriod, in timeZone: TimeZone) -> DayRange {
        DayRange(
            start: CivilDay(period.start, in: timeZone),
            end: CivilDay(period.end, in: timeZone)
        )
    }

    /// The same figure, saying out loud that the hero period holds shifts
    /// its to-date clamp left out.
    ///
    /// The CENTS are untouched — this adds, subtracts and rounds nothing, and
    /// the amount is still the engine's answer for the clamped selection.
    /// What changes is the words, under the rule the whole completeness
    /// machinery exists for: a figure that is not the whole story may not be
    /// headed with the word "Total".
    ///
    /// - "Known so far" is `MetricID.earnedIncome.allowedLabels`' own spelling
    ///   for that, and it is what `.partial` already reads. Wages `.off` keeps
    ///   its label: `nonWageEarnings` allows only "Tips" and "Tips & gratuity"
    ///   and neither can be misread as a settled total, so relabelling it
    ///   would put a label on a figure whose metric does not sanction it.
    /// - The caption NAMES the deferral, because "$0.00 · Known so far" with
    ///   nothing else on screen is still a person wondering where the shift
    ///   below it went. An existing completeness caption is kept and this is
    ///   appended to it; both facts are true at once.
    private static func declaringDeferral(
        _ figure: EarningsFigure,
        deferredShiftCount: Int
    ) -> EarningsFigure {
        guard deferredShiftCount > 0 else { return figure }
        let deferred = "\(CompletenessCopy.shiftCount(deferredShiftCount)) dated later this period"
        return EarningsFigure(
            metric: figure.metric,
            amount: figure.amount,
            label: figure.metric == .earnedIncome ? "Known so far" : figure.label,
            caption: [figure.caption, deferred].compactMap { $0 }.joined(separator: " · "),
            completeness: figure.completeness
        )
    }

    /// Every shift's `earnedIncome`, for `StatsEngine`'s reveal comparison.
    /// Nil without a snapshot, which leaves the engine on its own fallback
    /// rather than on a dictionary of zeros.
    private static func valuedCents(in snapshot: EarningsSnapshot?) -> [UUID: Int]? {
        guard let snapshot else { return nil }
        return Dictionary(
            snapshot.shifts.map { ($0.id, $0.components.earnedIncomeCents) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// The grid calendar in the FROZEN payroll zone.
///
/// One spelling for the whole screen. `ShiftDays.groupedByShift` defaults to
/// `Calendar.current`, so before this the shift grouping bucketed by the
/// DEVICE's civil day while the ledger valued by the payroll zone's — and a
/// legacy row with no `shiftID` took its deterministic fallback id from the
/// grouping calendar, so the two could key the same shift differently and a
/// `snapshot.valuation(id)` lookup would miss entirely.
enum PayrollCalendar {
    static func gridCalendar(in payrollTimeZone: TimeZone) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = payrollTimeZone
        return calendar
    }
}

/// The half of the render cache the snapshot's stamp cannot cover, because
/// none of it is an input to the engine.
///
/// Rule 3 of the adapter contract deletes `DashboardFactsKey`, which listed
/// the inputs this screen THOUGHT could move a number — the wage rate, the
/// policies, the payroll zone, a `dataRevision` counter. Every one of those
/// is now inside `SnapshotStamp.digest`, a SHA-256 over the complete input
/// set, so the facts cache keys on that. What is left here is genuinely
/// presentational: which pay period is selected, which day it is, and which
/// cards the person has dismissed. The pay-period GRID belongs in this half
/// specifically because `LegacySnapshotBridge` supplies no
/// `EarningsInputs.schedule`, so the grid is not in the digest and moving it
/// has to invalidate the facts some other way.
private struct DashboardSelection: Hashable {
    let day: Date
    let frequency: PayFrequency?
    let anchorPeriodEnd: Date?
    let payDelayDays: Int?
    let firstWeekday: Int?
    let forcedPhase: String?
    let dismissedClosedEndRaw: Double
    let dismissedCheckEndRaw: Double
}

/// One render's worth of work, kept so a `@State` change (opening the drawer,
/// presenting a sheet) does not redo it.
///
/// Two independent reuse tests, because the two halves cost different things:
///
/// - The DATASET (the grouping and the snapshot built from it) is valid while
///   `revision` has not moved. `LegacySnapshotBridge` costs 41.7 ms over
///   1,000 shifts and 307.4 ms over 10,000 (MEASURED, iPhone 17 Pro
///   simulator, 2026-09-18), so it must not run per `body`, and neither must
///   the grouping that feeds it. `LegacySnapshotRevision` is the invalidation
///   signal, and it is `EarningsStore`'s own trigger set rather than a second
///   opinion about what can change an input.
/// - The FACTS are valid while the dataset digest and the selection have not
///   moved. `digest` is the complete key; `selection` is the presentational
///   remainder.
private struct DashboardCacheIdentity: Hashable {
    let revision: Int
    let selection: DashboardSelection
}

private struct DashboardRenderCache {
    let revision: Int
    /// The grouping AND the snapshot built from it, together, because they
    /// have to be the same pair every render: caching only the snapshot is
    /// what let the view group a second time with a different calendar.
    let dataset: DashboardEarnings.Dataset
    let digest: String?
    let selection: DashboardSelection
    let facts: DashboardFacts
}

struct DashboardView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(PolicyStore.self) private var policyStore
    @Environment(TabRouter.self) private var tabRouter
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showSettings = false
    @State private var undoState = UndoDeleteToastState()
    @State private var progressTrackDrawn = false
    /// Observed, not mirrored into local state: a quick action or Control
    /// Center intent can start a session while this view is already on
    /// screen and foregrounded, which no scenePhase change would announce.
    private var shiftSession = ShiftSessionState.shared
    /// Whether the cash/credit breakdown drawer tucked under the hero is open.
    @State private var breakdownExpanded = false
    @State private var renderCache: DashboardRenderCache?
    /// Bumped by `LegacySnapshotRevision` — `EarningsStore`'s own rebuild
    /// triggers — so the cached snapshot is rebuilt when, and only when, an
    /// input to it moved. Not a `dataRevision`: that watched
    /// `ModelContext.didSave` alone, so a queued policy change or a midnight
    /// rollover left this screen serving figures computed under the old
    /// inputs. Gone entirely when PR 2 slice S7 lets this read
    /// `earningsStore.snapshot`.
    @State private var snapshotRevision = 0
    /// The `end` (as a reference-date interval) of the period whose completion
    /// card the person dismissed; 0 means none. Kept so the card stays gone
    /// once closed, without reappearing on the next launch.
    @AppStorage("dismissedPaydayPeriodEnd") private var dismissedClosedEndRaw: Double = 0
    /// The same, for the PAYDAY appearance of that card. Separate on purpose:
    /// closing the "period complete" summary on Monday says nothing about
    /// whether you want the check-verification prompt on Friday.
    @AppStorage("dismissedCheckDayPeriodEnd") private var dismissedCheckEndRaw: Double = 0

    private static let maxShiftRows = 5

    private var greeting: String {
        let timeOfDay = switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        guard let firstName = preferencesStore.firstName, !firstName.isEmpty else { return timeOfDay }
        return "\(timeOfDay), \(firstName)"
    }

    /// Screenshot/QA hook: pins the payday card to the current period in one of
    /// its two moments, so both can be inspected without waiting for a real
    /// payroll calendar. `-DebugForcePaydayMoment` is the close summary,
    /// `-DebugForceCheckDay` the payday appearance.
    private var forcedPaydayPhase: PaydayMoment.Phase? {
        #if DEBUG || targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-DebugForceCheckDay") { return .checkDay }
        if arguments.contains("-DebugForcePaydayMoment") { return .periodClosed }
        return nil
        #else
        return nil
        #endif
    }

    private let paydayVerificationTip = PaydayVerificationTip()

    var body: some View {
        let now = Date.now
        let dismissedClosedEnd = dismissedClosedEndRaw == 0 ? nil : Date(timeIntervalSinceReferenceDate: dismissedClosedEndRaw)
        let dismissedCheckEnd = dismissedCheckEndRaw == 0 ? nil : Date(timeIntervalSinceReferenceDate: dismissedCheckEndRaw)
        let payrollTimeZone = policyStore.payrollTimeZone
        let payrollCalendar = PayrollCalendar.gridCalendar(in: payrollTimeZone)
        // The selection the snapshot's digest cannot cover: which period is
        // on screen, which day it is, and which cards were dismissed. See
        // `DashboardSelection`.
        let selection = DashboardSelection(
            day: payrollCalendar.startOfDay(for: now),
            frequency: scheduleStore.schedule?.frequency,
            anchorPeriodEnd: scheduleStore.schedule?.anchorPeriodEnd,
            payDelayDays: scheduleStore.schedule?.payDelayDays,
            firstWeekday: scheduleStore.schedule?.firstWeekday,
            forcedPhase: forcedPaydayPhase?.rawValue,
            dismissedClosedEndRaw: dismissedClosedEndRaw,
            dismissedCheckEndRaw: dismissedCheckEndRaw
        )
        // ONE grouping and ONE snapshot built from it, over the WHOLE history
        // rather than this period's slice, so a workweek that straddles the
        // period edge is priced by the ledger as one week and the hero can
        // follow a closed period. `DashboardEarnings` holds the two together
        // and its header carries the two measured defects that come from
        // doing either one twice: a device-zone grouping under a
        // payroll-zone lookup, and a dataset-level `asOf` that made this
        // screen a different dataset from History's.
        //
        // `LegacySnapshotBridge` and not `earningsStore.snapshot`: nothing
        // writes `ShiftRecord` on a device until PR 2 slice S7, so the
        // store's snapshot is empty and a screen on it would show a person
        // with years of shifts a blank page. The swap is inside
        // `DashboardEarnings.build`.
        let dataset = renderCache?.revision == snapshotRevision
            ? renderCache!.dataset
            : DashboardEarnings.build(
                entries: allEntries,
                policies: policyStore.policies,
                payrollTimeZone: payrollTimeZone,
                calendar: payrollCalendar
            )
        let snapshot = dataset.snapshot
        // Rule 3: the facts are keyed on the dataset's own digest, the
        // complete computed key, plus this screen's presentational selection.
        let facts = renderCache?.digest == snapshot?.stamp.digest && renderCache?.selection == selection
            ? renderCache!.facts
            : DashboardFacts(
                snapshot: snapshot,
                allShifts: dataset.shiftDays,
                schedule: scheduleStore.schedule,
                now: now,
                forcedPaydayPhase: forcedPaydayPhase,
                dismissedClosedEnd: dismissedClosedEnd,
                dismissedCheckEnd: dismissedCheckEnd,
                payrollTimeZone: payrollTimeZone
            )
        NavigationStack {
            // A ScrollView, deliberately NOT a List: the hero's drawer changes
            // height when it opens, and a List (UIKit-backed) animates the row
            // resize on its own clock while the drawer's spring runs on
            // another — everything below visibly stutters. Pure SwiftUI layout
            // keeps the whole column on one animation, which is exactly how
            // Vero's budget drawer stays smooth.
            ScrollView {
                VStack(spacing: PaydaySpacing.p8) {
                    heroWithDrawer(facts)
                        .padding(.horizontal, PaydaySpacing.p16)
                        .padding(.top, 8)

                    tonightLineRow(facts)

                    if facts.periodEntries.isEmpty {
                        emptyState(facts)
                    } else {
                        shiftsSection(facts)
                            .padding(.horizontal, PaydaySpacing.p16)
                    }
                }
            }
            .background(PaydayColor.background)
            .contentMargins(.bottom, 88, for: .scrollContent) // clear the floating + button
            .navigationTitle(greeting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(item: $sheetTarget) { target in
                LogTipSheet(target: target).paydayAppearance()
            }
            #if DEBUG || targetEnvironment(simulator)
            .onAppear {
                // Screenshot/QA hook only — opens the most recent period
                // entry, no kind argument. Named distinctly from
                // MainTabView's "-OpenEditSheetKind <kind>" hook so passing
                // one can never accidentally also satisfy the other and
                // double-present a sheet.
                if ProcessInfo.processInfo.arguments.contains("-OpenEditSheet"), let first = facts.periodEntries.first {
                    sheetTarget = .edit(first)
                }
                if ProcessInfo.processInfo.arguments.contains("-OpenSettings") {
                    showSettings = true
                }
                if ProcessInfo.processInfo.arguments.contains("-DebugExpandBreakdown") {
                    breakdownExpanded = true
                }
                // Screenshot-only: opens the drawer in slow motion so a
                // frame-capture pass can inspect mid-animation layout for
                // jumps — a real tap animates too fast to catch over simctl.
                if ProcessInfo.processInfo.arguments.contains("-DebugDrawerSlowMotion") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.linear(duration: 4)) {
                            breakdownExpanded = true
                        }
                    }
                }
            }
            #endif
            .sheet(isPresented: $showSettings) {
                SettingsView(schedule: scheduleStore.schedule ?? .fallback).paydayAppearance()
            }
        }
        .undoDeleteToast(undoState, context: modelContext)
        .onAppear { shiftSession.sync() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            shiftSession.sync()
        }
        .task(id: DashboardCacheIdentity(revision: snapshotRevision, selection: selection)) {
            renderCache = DashboardRenderCache(
                revision: snapshotRevision,
                dataset: dataset,
                digest: snapshot?.stamp.digest,
                selection: selection,
                facts: facts
            )
        }
        .legacySnapshotRevision($snapshotRevision)
    }

    // MARK: Tonight line

    /// The historical "you usually work Fridays" line — hero card's own
    /// footer band (shiftBand) owns the live-shift slot now, so this only
    /// ever renders while no session is active.
    @ViewBuilder
    private func tonightLineRow(_ facts: DashboardFacts) -> some View {
        if shiftSession.activeStart == nil, let tonightLine = facts.tonightLine {
            Text(tonightLine)
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textSecondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.horizontal, PaydaySpacing.p24)
                .padding(.vertical, PaydaySpacing.p4)
        }
    }

    // MARK: Hero card + breakdown drawer

    /// The hero card with a cash/credit drawer tucked behind it, via the
    /// shared HeroBreakdownDrawer (same peek + slide treatment as Vero's
    /// coverage drawer, now also used by PeriodDetailView's hero). The
    /// drawer's collapsed lip shows the earnings split at rest; tapping the
    /// hero slides it open to the full reconciliation (cash tips + credit
    /// tips + employee gratuity - tip-out = take-home), which is where the
    /// tip-out lives now instead of cluttering the card face.
    ///
    /// Every figure in it arrives composed. This function used to build the
    /// row list itself from five of its own additions and derive the
    /// tip-out as `max(0, cash + credit + gratuity - nonWageNet)`; the rows
    /// now come out of `BreakdownRow.ledgerRows(_:)` over the hero's one
    /// `EarningsResult`, and the tip-out is the ledger's own
    /// `tipOutCents`, READ rather than reconstructed.
    private func heroWithDrawer(_ facts: DashboardFacts) -> some View {
        HeroBreakdownDrawer(
            lipText: facts.heroLipText ?? "",
            rows: facts.heroBreakdownRows,
            total: facts.heroBreakdownTotal,
            hasBreakdown: facts.heroHasBreakdown,
            isExpanded: $breakdownExpanded
        ) {
            heroCard(facts)
        }
    }

    /// Shared by the hero's tap gesture (inside HeroBreakdownDrawer) and its
    /// VoiceOver accessibility action (heroSummary below) so both paths
    /// toggle identically.
    private func toggleBreakdown() {
        HeroBreakdownToggle.fire($breakdownExpanded, reduceMotion: reduceMotion)
    }

    // MARK: Hero card

    private func heroCard(_ facts: DashboardFacts) -> some View {
        VStack(spacing: PaydaySpacing.p20) {
            heroSummary(facts)

            if facts.isPaydayMoment {
                Divider()
                paydayMomentSection(facts)
            }

            Divider()
            shiftBand
        }
        .paydayCard(padding: PaydaySpacing.p24)
    }

    /// The hero card's own footer band — this is where a shift lives or
    /// dies now, not a separate row below the card (Tyler's call: Start
    /// Shift felt tacked on before). Idle offers Start Shift; live shows the
    /// running timer and hands off to End Shift, which does nothing but
    /// open the same log sheet every other creation path uses — the
    /// session itself only ends once that sheet is SAVED (see
    /// LiveShiftEndModeResolver), so cancelling leaves the shift running
    /// exactly as it was before the tap.
    @ViewBuilder
    private var shiftBand: some View {
        Group {
            if let activeStart = shiftSession.activeStart {
                HStack(spacing: PaydaySpacing.p8) {
                    HStack(spacing: PaydaySpacing.p8) {
                        LiveShiftDot()
                        Text("On shift · ")
                            .foregroundStyle(PaydayColor.textSecondary)
                            .font(PaydayFont.subheadline)
                        LiveShiftClock(startedAt: activeStart)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(onShiftAccessibilityLabel(activeStart))

                    Spacer(minLength: PaydaySpacing.p8)

                    Button("End Shift") {
                        sheetTarget = .new(defaultDate: .now)
                    }
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.primary)
                    .buttonStyle(PressableButtonStyle())
                }
                // The live row arrives with real presence — leading-edge
                // slide + slight scale, the app's own spring — and leaves
                // fast (exits are always quicker than entrances). Never
                // from nothing: opacity + 0.97, not scale-from-zero.
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: -8)).combined(with: .scale(scale: 0.97, anchor: .leading)),
                    removal: .opacity
                ))
            } else {
                Button("Start Shift") {
                    PaydayHaptics.lightTap()
                    ShiftSessionManager.start()
                }
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.primary)
                .buttonStyle(PressableButtonStyle())
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : PaydayAnimation.drawerSpring, value: shiftSession.activeStart != nil)
    }

    /// "On shift, 47 minutes" — a spoken fact, not the literal ticking
    /// digits the clock renders visually.
    private func onShiftAccessibilityLabel(_ start: Date) -> String {
        let minutes = max(0, Int(Date.now.timeIntervalSince(start) / 60))
        return "On shift, \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// The always-tappable part of the hero: label, amount, pace line, and
    /// the period progress bar. Combined into one VoiceOver element carrying
    /// a button trait and the toggle action — the tap gesture that expands
    /// the breakdown drawer lives on the outer heroCard container, which
    /// (being several separately-readable Texts) has no single element for
    /// VoiceOver to activate otherwise. The payday moment section stays
    /// outside this combined region so its own Dismiss button and TipKit
    /// popover keep their individual accessibility.
    private func heroSummary(_ facts: DashboardFacts) -> some View {
        let hasBreakdown = facts.heroHasBreakdown
        return VStack(spacing: PaydaySpacing.p20) {
            VStack(spacing: 6) {
                Text(facts.heroLabel)
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                // `figure.text` is nil when the engine could not answer, so
                // this cannot print "$0.00" for "Payday couldn't read your
                // shifts" (adapter contract, rule 4). A pay period with no
                // shifts at all is a different case and DOES print $0.00:
                // that zero is a fact, and "No shifts this period." is drawn
                // directly underneath it because `periodEntries` is empty.
                //
                // A period whose shifts are all dated AHEAD of today used to
                // land in the same $0.00-under-"Total" presentation while
                // that sentence was NOT drawn (the shift's own row was),
                // which is the state `heroDeferredShiftCount` closed: the
                // label becomes "Known so far" and the caption below names
                // the shifts dated later in the period.
                Text(facts.hero.text ?? ShiftDayRow.unavailablePlaceholder)
                    .font(PaydayFont.displayXXL)
                    .monospacedDigit()
                    .foregroundStyle(
                        facts.hero.isUnavailable ? PaydayColor.textSecondary : PaydayColor.textPrimary
                    )
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: facts.hero.cents)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                // "Wages estimated from your current rate" / "wages missing
                // for 1 shift". The one line that keeps a partial total from
                // reading as a settled one; `CompletenessCopy` decides when
                // it exists, never this screen.
                if let caption = facts.hero.caption {
                    Text(caption)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                // Pace only makes sense for the period still in progress —
                // a finished period isn't racing anything.
                if facts.heroIsCurrent, let paceDeltaCents = facts.paceDeltaCents {
                    // The screen's one color moment: ahead is green because
                    // being ahead is the act. Behind stays quiet gray — red
                    // is reserved for a shorted paycheck, never for pace.
                    Text(RevealCopy.paceLine(deltaCents: paceDeltaCents, periodCount: facts.pacePeriodCount))
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(paceDeltaCents > 0 ? PaydayColor.primary : PaydayColor.textSecondary)
                        .monospacedDigit()
                        .animation(reduceMotion ? nil : PaydayAnimation.premiumSpring, value: paceDeltaCents > 0)
                }
                // Projection line removed: it overlapped the pace line above
                // (two framings of the same trajectory). Pace stays — it's
                // grounded in real logged history on both sides and it's the
                // screen's one green moment; projection was the softer of the
                // two. (Still computed for the widget/Insights.)
            }

            progressTrack(facts)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(hasBreakdown ? .isButton : [])
        .accessibilityHint(hasBreakdown ? (breakdownExpanded ? "Hide breakdown" : "Show breakdown") : "")
        .accessibilityAction {
            guard hasBreakdown else { return }
            toggleBreakdown()
        }
    }

    private func progressAccessibilityValue(_ facts: DashboardFacts) -> String {
        guard facts.heroIsCurrent else { return "Period complete" }
        return facts.daysRemaining == 0 ? "Last day" : "\(facts.daysRemaining) days left"
    }

    /// The period itself, drawn: fills as days pass, ends at payday. This
    /// carries "days left" without a number — a glance shows where you are.
    private func progressTrack(_ facts: DashboardFacts) -> some View {
        let fraction = facts.calculator.progress(through: .now, in: facts.heroPeriod)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PaydayColor.primary.opacity(0.15))
                    Capsule()
                        .fill(PaydayColor.primary)
                        .frame(width: geo.size.width * (progressTrackDrawn ? fraction : 0))
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Pay period progress")
            .accessibilityValue(progressAccessibilityValue(facts))

            // The bar already shows how far through the period you are, so
            // "N days left" was the same fact twice — only the payday date
            // remains, labeling where the bar ends.
            HStack {
                Spacer()
                Text("Payday · \(facts.heroPayDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
        }
        .onAppear {
            guard !progressTrackDrawn else { return }
            if reduceMotion {
                progressTrackDrawn = true
            } else {
                withAnimation(PaydayAnimation.premiumSpring.delay(0.15)) {
                    progressTrackDrawn = true
                }
            }
        }
    }

    private func paydayMomentSection(_ facts: DashboardFacts) -> some View {
        let isCheckDay = facts.paydayPhase == .checkDay
        return VStack(spacing: 16) {
            // No header on payday: a green "Payday" here collided with the
            // progress bar's own "Payday · Thu, Aug 13" a few lines above,
            // which labels the CURRENT period's payday — two different dates
            // under one word reads as "payday is Aug 13" on the very day the
            // money arrives. "Today" moves into the caption below instead, where
            // it belongs, and the card keeps one line rather than two.
            //
            // Otherwise the header names the state the card is reporting, and
            // then only when the hero above isn't already saying it — once the
            // hero reads "Last pay period" over a full progress bar, "the period
            // ended" is on screen twice and this made it three times (Tyler,
            // 2026-08-03: say it once).
            //
            // Best day is gone entirely — nobody opens the app for it, and it
            // was the one figure on this card measured tips-only, so it never
            // matched the wage-inclusive shift rows below it anyway.
            VStack(spacing: 4) {
                Text(isCheckDay ? "Today's check should show" : "Your check should show")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                Text(facts.predictedPaycheck.text ?? ShiftDayRow.unavailablePlaceholder)
                    .font(PaydayFont.displayLarge)
                    .monospacedDigit()
                    .foregroundStyle(
                        facts.predictedPaycheck.isUnavailable
                            ? PaydayColor.textSecondary
                            : PaydayColor.textPrimary
                    )
                // The arithmetic, stated out loud. This number used to be
                // gross credit tips with the tip-out silently left in and the
                // wages added back in a second sentence, which is exactly how
                // a card ends up with two totals nobody can reconcile. The
                // payday date is NOT repeated here — the progress bar above
                // already labels where the period ends.
                Text("Card tips + gratuity + wages − tip-out · before tax")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .multilineTextAlignment(.center)
                // Closes the last gap on this card. The hero says what you kept
                // and this says what the check carries, and the difference
                // between them is ALWAYS exactly the cash — the only money that
                // never runs through payroll. Without this line the reader has
                // to subtract two four-figure numbers to learn that, and Tyler
                // did exactly that on his own real period before asking "cash?".
                // Not a repeat under rule 11: it does arithmetic for the reader
                // rather than restating something already on screen.
                if let cash = facts.paydayCash.text, (facts.paydayCash.cents ?? 0) > 0 {
                    Text("Cash already paid · \(cash)")
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                // The check figure's own completeness, when it has one: a
                // period with an unpriced shift cannot present a settled
                // check total without saying so.
                if let caption = facts.predictedPaycheck.caption {
                    Text(caption)
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .popoverTip(paydayVerificationTip)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            // The card clears on its own, but let the person close it the moment
            // they've seen it. Each of the two moments is dismissed on its own
            // key, so closing the period summary does not also cancel the
            // check-verification prompt days later.
            if let end = facts.paydayPeriodEnd {
                Button {
                    let dismiss = {
                        if isCheckDay {
                            dismissedCheckEndRaw = end.timeIntervalSinceReferenceDate
                        } else {
                            dismissedClosedEndRaw = end.timeIntervalSinceReferenceDate
                        }
                    }
                    if reduceMotion {
                        dismiss()
                    } else {
                        withAnimation(PaydayAnimation.premiumSpring) { dismiss() }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PaydayColor.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCheckDay ? "Dismiss payday card" : "Dismiss period summary")
            }
        }
    }

    // MARK: Shifts

    private func shiftsSection(_ facts: DashboardFacts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Shifts")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                Spacer()
                Text(facts.shiftCount == 1 ? "1 this period" : "\(facts.shiftCount) this period")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            .padding(.top, PaydaySpacing.p16)
            .padding(.bottom, PaydaySpacing.p8)

            ForEach(Array(facts.shiftDays.prefix(Self.maxShiftRows).enumerated()), id: \.element.shiftID) { index, group in
                if index > 0 { Divider() }
                shiftRow(for: group, facts: facts)
            }
            if facts.shiftDays.count > Self.maxShiftRows {
                Divider()
                Button {
                    // "See all" used to just switch tabs and leave the
                    // person staring at the periods LIST — the shifts they
                    // were looking at live inside the CURRENT period's
                    // detail, so land there directly.
                    tabRouter.pendingCurrentPeriodDetail = true
                    HistoryLens.periods.select()
                    tabRouter.selected = .history
                } label: {
                    Text("See all")
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(PaydayColor.primary)
                        .padding(.vertical, PaydaySpacing.p12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func shiftRow(
        for group: (day: Date, shiftID: UUID, items: [TipEntry]),
        facts: DashboardFacts
    ) -> some View {
        // A shift, single-entry or merged cash+credit, is one row now — the
        // edit sheet is shaped like a shift regardless of how many TipEntry
        // rows it took to log it, so there's no separate "open this shift's
        // entries" destination anymore.
        // Swipe-to-delete went with the List conversion (swipeActions is
        // List-only); delete stays one long-press away via the context menu,
        // with the same undo toast, and PeriodDetailView still swipes.
        if let anchor = group.items.first {
            Button {
                sheetTarget = .edit(anchor)
            } label: {
                ShiftDayRow(facts: ShiftDayRowFacts(
                    snapshot: facts.snapshot,
                    shiftID: group.shiftID,
                    day: group.day,
                    period: ShiftDetails.resolve(from: group.items).shiftPeriod,
                    dayHasMultipleShifts: facts.multiShiftDays.contains(group.day)
                ))
                .padding(.vertical, PaydaySpacing.p12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shiftContextMenu(group.items, sheetTarget: $sheetTarget, undoState: undoState, context: modelContext)
        }
    }

    /// Deliberately NOT ContentUnavailableView any more: its intrinsic height
    /// wants most of a screen, so inside this ScrollView it sat down behind the
    /// floating glass tab bar, which refracted the text into an unreadable
    /// double image. Its description line ("Log your tips and watch the total
    /// build toward payday") also only restated the title.
    ///
    /// The wording follows the hero: when the hero reads "Last pay period", the
    /// empty list belongs to the NEW period, and "Nothing logged yet this
    /// period" directly under a completed period's total reads like a
    /// contradiction rather than a new start.
    private func emptyState(_ facts: DashboardFacts) -> some View {
        Text("No shifts this period.")
            .font(PaydayFont.subheadline)
            .foregroundStyle(PaydayColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, PaydaySpacing.p24)
    }
}

/// One-time education, shown the first time the payday moment appears:
/// TipKit tracks "seen" state itself, so this never repeats once dismissed.
private struct PaydayVerificationTip: Tip {
    var title: Text {
        Text("Verify your paycheck")
    }

    var message: Text? {
        Text("Compare this with the tips line on your stub.")
    }

    var image: Image? {
        Image(systemName: "checkmark.seal")
    }
}


/// The live band's recording light: a quiet breathing pulse (opacity only,
/// never size) says "this is recording right now" the way a REC dot does —
/// the one piece of ongoing motion the band earns while a shift runs.
/// Static under Reduce Motion.
private struct LiveShiftDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(PaydayColor.primary)
            .frame(width: 8, height: 8)
            .opacity(dimmed ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// The elapsed clock, digit-rolling: Text(timerInterval:) self-updates
/// outside SwiftUI's animation system, so its digits SWAP every second.
/// Driving the same string from a per-second TimelineView lets
/// contentTransition(.numericText) roll each changing digit instead —
/// the system's own timer language (Dynamic Island, Clock). Plain swaps
/// under Reduce Motion.
private struct LiveShiftClock: View {
    let startedAt: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let label = ElapsedClock.string(from: startedAt, to: context.date)
            Text(label)
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.textPrimary)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: false))
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: label)
        }
    }
}
