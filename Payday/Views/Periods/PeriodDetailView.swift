import Combine
import SwiftUI
import SwiftData

/// One immutable period-detail render.
///
/// PR 5 group 2.4, wave 1. The contract is
/// `Payday/Earnings/SnapshotFacts.swift`, and this screen is where three of
/// its four rules were previously broken at once: the hero, the $/hr caption,
/// the drawer rows and the paycheck section each composed their own money out
/// of `TipBreakdown` + `StatsEngine.nightlyTotals` + `PeriodIncome`, the
/// tip-out was BACK-DERIVED as `max(0, cash + credit + gratuity − net)`
/// instead of read, and the drawer's bottom line was
/// `tipOutCents > 0 ? "You kept" : "Total"` — so a period the engine could
/// only partly value still printed the word "Total".
///
/// Everything on this struct now comes from ONE `EarningsResult`: the period's
/// own, composed from `range(_:)` (see `HistoryEarnings.earnings`). That is
/// also what makes the screen agree with the History row that opened it and
/// with the chart under its own hero — all three are the same query.
struct PeriodDetailFacts: SnapshotFacts {
    // MARK: Presentation

    let payDate: Date
    /// The period's shifts, newest first, with the rows a tap edits.
    ///
    /// Selected by `result.shiftIDs`, NOT by re-filtering entries on their
    /// dates. The engine selects a shift by its work day in the FROZEN
    /// payroll zone; this screen's old filter compared `entry.date` against
    /// the period bounds in `Calendar.current`, so a late-night shift near a
    /// period boundary could be listed under a period whose total did not
    /// include it. Reading the selection back off the result makes the rows
    /// and the hero the same set by construction.
    let shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])]
    let multiShiftDays: Set<Date>
    /// The civil days this screen asked about, so a caller can see the scope
    /// as well as the cents.
    let range: DayRange

    // MARK: Money, from the engine

    /// The snapshot every figure below came out of. Held so the shift rows
    /// can look up their own valuations by the same ids the result selected.
    let snapshot: EarningsSnapshot?
    /// The period's one result. Nil only when there is no snapshot, which
    /// renders as unavailable and never as zero.
    let result: EarningsResult?
    /// The hero figure, labelled and captioned by its own completeness.
    let hero: EarningsFigure
    /// `MetricID.hourlyRate` with its coverage, from the engine's own
    /// covered-income-over-covered-minutes. See
    /// `HistoryEarnings.hourlyRateCaption` for the divergence this closes.
    let hourlyRateCaption: String?

    /// The drawer, composed by the shared component from the same result:
    /// `BreakdownRow.ledgerRows(_:)`, `.total(_:)`, `.lipText(_:)` and
    /// `.hasBreakdown(_:)`. Wave 0 wrote and tested all four and left them
    /// with zero production callers; these four fields are those callers
    /// (`docs/METRICS.md` [SC-02] and [SC-03]).
    let breakdownRows: [BreakdownRow]
    let breakdownTotal: BreakdownRow
    let lipText: String
    let hasBreakdown: Bool

    /// One engine query per bar, over this period's days. `Σ bars` is
    /// `chartFacts.whole`, which is the same range query the hero is.
    let chartFacts: EarningsChartFacts

    /// `MetricID.expectedPaycheckGross` for the period, read off
    /// `expectation` — the value handed to `PaycheckEntrySheet` — so the
    /// figure this screen renders and the figure the sheet renders and audits
    /// against are one property and not two that agree.
    let expectedCheckCents: Int
    /// What the engine expects of this period's stub. See
    /// `PaycheckReconciler.Expectation` for the divergence this closes: the
    /// sheet used to rebuild its own basis from an entry-date filter and the
    /// pay-period GRID's weekday, and disagreed with this screen by $310.00
    /// on a measured fixture.
    let expectation: PaycheckReconciler.Expectation
    let noPaycheckCaption: String
    let paycheck: PaycheckRecord?
    /// The recorded check next to what the engine expected. One type shared
    /// with the History row, so the row's delta and this screen's verdict
    /// cannot disagree.
    let checked: PeriodCheckComparison?

    let stamp: SnapshotStamp?

    /// - Parameters:
    ///   - snapshot: `HistoryEarnings.build`'s, over the WHOLE history, so a
    ///     workweek straddling this period's boundary keeps the overtime it
    ///     produced. PR 2 S7 makes it `earningsStore.snapshot`.
    ///   - shiftDays: the same grouping the snapshot was built from, so a
    ///     `shiftID` here indexes it.
    ///   - schedule: the pay-period GRID, for the pay DATE only. Its
    ///     `firstWeekday` reaches no money path from this screen: PR 3
    ///     severed the grid's weekday from the workweek, and the one
    ///     remaining consumer of the scalar (`PeriodIncome`) is gone from
    ///     here.
    init(
        snapshot: EarningsSnapshot?,
        shiftDays: [(day: Date, shiftID: UUID, items: [TipEntry])],
        paycheckRecords: [PaycheckRecord],
        period: PayPeriod,
        schedule: PaySchedule?,
        payrollTimeZone: TimeZone,
        calendar: Calendar = .current
    ) {
        let calculator = PayPeriodCalculator(
            payrollTimeZone: payrollTimeZone,
            schedule: schedule ?? .fallback,
            calendar: calendar
        )
        payDate = calculator.payDate(for: period)
        range = HistoryEarnings.range(of: period, in: payrollTimeZone)
        self.snapshot = snapshot
        stamp = snapshot?.stamp

        let periodResult = HistoryEarnings.earnings(snapshot, for: period, in: payrollTimeZone)
        result = periodResult

        let selected = Set(periodResult?.shiftIDs ?? [])
        let rows = shiftDays.filter { selected.contains($0.shiftID) }
        self.shiftDays = rows
        var shiftCounts: [Date: Int] = [:]
        for shift in rows { shiftCounts[shift.day, default: 0] += 1 }
        multiShiftDays = Set(shiftCounts.filter { $0.value >= 2 }.keys)

        if let periodResult {
            hero = EarningsFigure.earnedIncome(periodResult)
            breakdownRows = BreakdownRow.ledgerRows(periodResult)
            breakdownTotal = BreakdownRow.total(periodResult)
            lipText = BreakdownRow.lipText(periodResult)
            hasBreakdown = BreakdownRow.hasBreakdown(periodResult)
        } else {
            // No dataset stands behind these facts, so nothing may render a
            // currency figure (rule 4). The drawer has nothing to itemize
            // either, so it does not open.
            hero = .unavailable()
            breakdownRows = []
            breakdownTotal = BreakdownRow("Known so far", cents: nil, emphasized: true)
            lipText = ""
            hasBreakdown = false
        }
        hourlyRateCaption = HistoryEarnings.hourlyRateCaption(periodResult)

        // ONE expectation for this period, built from the result the hero,
        // the drawer rows and the $/hr caption already read, and handed
        // straight to `PaycheckEntrySheet`. The sheet used to rebuild its own
        // from an entry-date filter and the pay-period GRID's weekday and
        // audited a real stub $310.00 away from this screen;
        // `PaycheckReconciler.Expectation`'s header has the measurement, and
        // `PaycheckParityTests` pins the two sides equal.
        //
        // The `?? 0` is never rendered as money: with no dataset
        // `noPaycheckCaption` below names the pay date and no dollar figure,
        // and `checked` refuses.
        expectation = PaycheckReconciler.Expectation(result: periodResult, stamp: snapshot?.stamp)
        expectedCheckCents = expectation.grossCents ?? 0

        // Every bar is `snapshot.day(thatDay)` and `whole` is the same
        // `range(_:)` the hero is, so the chart and the figure above it are
        // one engine answering at two scopes. No `asOf` override: the
        // snapshot's own cutoff is already `.distantFuture`, because History
        // has never applied one.
        chartFacts = EarningsChartFacts(
            snapshot: snapshot,
            range: range,
            timeZone: payrollTimeZone
        )

        let resolvedPaycheck = HistoryEarnings.paycheck(for: period, in: paycheckRecords)
        paycheck = resolvedPaycheck
        checked = PeriodCheckComparison(result: periodResult, paycheck: resolvedPaycheck)
        // Rule 4 again: with no dataset there is no expectation to state, so
        // the caption names the pay date and no dollar figure at all.
        //
        // Three cases, because `checked` now refuses for two different
        // reasons and the section renders this caption for both. A check
        // RECORDED against an unreadable dataset is not "no paycheck": say
        // which half is missing, in `EarningsUnavailable`'s own words, rather
        // than describing a check the person already entered as expected.
        let payDateText = payDate.formatted(.dateTime.month(.abbreviated).day())
        if periodResult == nil {
            noPaycheckCaption = resolvedPaycheck == nil
                ? "Expected on \(payDateText)"
                : "Check recorded · Payday couldn't read your shifts right now."
        } else {
            noPaycheckCaption = "Expected \(Money.string(fromCents: expectedCheckCents)) · \(payDateText)"
        }
    }
}

struct PeriodDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(PolicyStore.self) private var policyStore
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    let period: PayPeriod
    @State private var sheetTarget: TipEntrySheetTarget?
    @State private var showPaycheckSheet = false
    @State private var undoState = UndoDeleteToastState()
    /// Whether the cash/credit breakdown drawer tucked under the hero is open.
    @State private var breakdownExpanded = false
    /// The snapshot this screen renders, and the only thing it caches. See
    /// `PeriodsView`'s note on why the facts themselves are not cached and
    /// why there is no `PeriodDetailFactsKey` any more.
    @State private var snapshotCache: PeriodDetailSnapshotCache?
    @State private var writes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let build = snapshotBuild()
        let facts = PeriodDetailFacts(
            snapshot: build.snapshot,
            shiftDays: build.shiftDays,
            paycheckRecords: paycheckRecords,
            period: period,
            schedule: scheduleStore.schedule,
            payrollTimeZone: policyStore.payrollTimeZone
        )
        // A ScrollView, deliberately NOT a List — same fix as the Dashboard
        // (2026-07-19): a List animates row resize on UIKit's own clock,
        // which fights the hero drawer's spring and makes everything below
        // visibly stutter as it opens and closes. Pure SwiftUI layout keeps
        // the whole column on one animation.
        ScrollView {
            VStack(spacing: PaydaySpacing.p16) {
                HeroBreakdownDrawer(
                    lipText: facts.lipText,
                    rows: facts.breakdownRows,
                    total: facts.breakdownTotal,
                    hasBreakdown: facts.hasBreakdown,
                    isExpanded: $breakdownExpanded
                ) {
                    heroCard(facts)
                }

                // The chart keeps its own time-scaled earnings label (it doubles as
                // the scrub readout), so no separate flat header goes above
                // it — this is this screen's only other flat section without
                // a kicker.
                if !facts.shiftDays.isEmpty {
                    NightlyEarningsChart(facts: facts.chartFacts)
                }

                paycheckSection(facts)

                shiftsSection(facts)
            }
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.top, PaydaySpacing.p8)
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        .background(PaydayColor.background)
        .navigationTitle(periodTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheetTarget) { target in
            LogTipSheet(target: target).paydayAppearance()
        }
        .sheet(isPresented: $showPaycheckSheet) {
            // The sheet is HANDED this screen's basis rather than rebuilding
            // one: see `PaycheckReconciler.Expectation` for the $310.00 divergence that
            // closes.
            PaycheckEntrySheet(
                period: period,
                existing: facts.paycheck,
                expectation: facts.expectation
            )
            .paydayAppearance()
        }
        .undoDeleteToast(undoState, context: modelContext)
        .task(id: SnapshotBuildKey(
            writes: writes,
            policies: policyStore.policies,
            payrollTimeZone: policyStore.payrollTimeZone
        )) {
            snapshotCache = PeriodDetailSnapshotCache(
                writes: writes,
                policies: policyStore.policies,
                payrollTimeZone: policyStore.payrollTimeZone,
                build: build
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            writes &+= 1
        }
        #if DEBUG
        .onAppear {
            // Screenshot-only, same flag as the Dashboard hero: opens the
            // drawer immediately so QA can inspect the expanded layout
            // without tapping through simctl.
            if ProcessInfo.processInfo.arguments.contains("-DebugExpandBreakdown") {
                breakdownExpanded = true
            }
        }
        #endif
    }

    private func snapshotBuild() -> HistoryEarnings.Build {
        let policies = policyStore.policies
        let zone = policyStore.payrollTimeZone
        if let cached = snapshotCache,
           cached.writes == writes,
           cached.policies == policies,
           cached.payrollTimeZone == zone {
            return cached.build
        }
        return HistoryEarnings.build(
            entries: allEntries,
            policies: policies,
            payrollTimeZone: zone
        )
    }

    /// Flat, in the Insights section grammar: a tracked caption2 kicker,
    /// content beneath, no card. One raised object on this screen is the
    /// hero; the paycheck comparison sits on the surface like every other
    /// non-hero section.
    @ViewBuilder
    private func paycheckSection(_ facts: PeriodDetailFacts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PAYCHECK")
                .font(PaydayFont.caption2)
                .tracking(0.8)
                .foregroundStyle(PaydayColor.primary)

            if let checked = facts.checked, let paycheck = facts.paycheck {
                PaycheckComparisonView(checked: checked, paycheck: paycheck)
            } else {
                Text(facts.noPaycheckCaption)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
            }

            Button(facts.paycheck == nil ? "Add paycheck" : "Edit paycheck") {
                showPaycheckSheet = true
            }
            .font(PaydayFont.subheadline)
            .foregroundStyle(PaydayColor.primary)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }

    @ViewBuilder
    private func shiftsSection(_ facts: PeriodDetailFacts) -> some View {
        if facts.shiftDays.isEmpty {
            Text("No shifts in this period.")
                .font(PaydayFont.bodyRegular)
                .foregroundStyle(PaydayColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Shifts")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .padding(.bottom, PaydaySpacing.p8)

                ForEach(Array(facts.shiftDays.enumerated()), id: \.element.shiftID) { index, group in
                    if index > 0 { Divider() }
                    shiftRow(for: group, facts: facts)
                }
            }
        }
    }

    /// The face goes minimal: the figure, plus the captions the completeness
    /// rules owe. Cash/Credit, Wages, and the payday date all live in the
    /// tucked drawer / paycheck section below, rather than stacking four
    /// caption lines of differently-weighted information on the card face.
    ///
    /// The figure has no LABEL here — the drawer's bottom line carries it,
    /// and it is `CompletenessCopy`'s ("Known so far" / "You kept" / "Tips"),
    /// never this screen's own conditional. An unreadable dataset renders the
    /// placeholder rather than `$0.00`.
    private func heroCard(_ facts: PeriodDetailFacts) -> some View {
        VStack(spacing: 10) {
            Text(facts.hero.text ?? ShiftDayRow.unavailablePlaceholder)
                .font(PaydayFont.displayXL)
                .monospacedDigit()
                .foregroundStyle(
                    facts.hero.isUnavailable ? PaydayColor.textSecondary : PaydayColor.textPrimary
                )
            if let hourlyRateCaption = facts.hourlyRateCaption {
                Text(hourlyRateCaption)
                    .font(PaydayFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            if let caption = facts.hero.caption {
                Text(caption)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel(facts))
        .accessibilityAddTraits(facts.hasBreakdown ? .isButton : [])
        .accessibilityHint(facts.hasBreakdown ? (breakdownExpanded ? "Hide breakdown" : "Show breakdown") : "")
        .accessibilityAction {
            guard facts.hasBreakdown else { return }
            HeroBreakdownToggle.fire($breakdownExpanded, reduceMotion: reduceMotion)
        }
        .paydayCard(padding: PaydaySpacing.p24)
    }

    /// VoiceOver hears the label the rules allow, which the visual card
    /// deliberately leaves to the drawer.
    private func heroAccessibilityLabel(_ facts: PeriodDetailFacts) -> String {
        var parts = [facts.hero.label]
        parts.append(facts.hero.text ?? "amount unavailable")
        if let hourlyRateCaption = facts.hourlyRateCaption { parts.append(hourlyRateCaption) }
        if let caption = facts.hero.caption { parts.append(caption) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func shiftRow(
        for group: (day: Date, shiftID: UUID, items: [TipEntry]),
        facts: PeriodDetailFacts
    ) -> some View {
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
            // Swipe-to-delete was List-only and went with the List
            // conversion — delete stays one long-press away via the context
            // menu, with the same undo toast, matching the Dashboard.
            .shiftContextMenu(group.items, sheetTarget: $sheetTarget, undoState: undoState, context: modelContext)
        }
    }

    /// The card used to carry its own date range as a caption; folding it
    /// into the nav title instead frees that space for the payday/rate line.
    /// The year only shows when the period crosses into one other than the
    /// current one — most periods live entirely inside a single year.
    private var periodTitle: String {
        let currentYear = Calendar.current.component(.year, from: Date())
        let endYear = Calendar.current.component(.year, from: period.end)
        let start = period.start.formatted(.dateTime.month(.abbreviated).day())
        if endYear != currentYear {
            return "\(start) – \(period.end.formatted(.dateTime.month(.abbreviated).day().year()))"
        }
        return "\(start) – \(period.end.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

/// Period detail's half of the group's snapshot cache. Same three triggers
/// as `PeriodsView`'s; a separate type only because both are `private` to
/// their own file and neither screen should be able to hand the other a
/// snapshot built with different policies.
private struct PeriodDetailSnapshotCache {
    let writes: Int
    let policies: CompensationPolicies
    let payrollTimeZone: TimeZone
    let build: HistoryEarnings.Build
}

/// A recorded check against what the engine expected for the same period.
///
/// Every figure arrives on `PeriodCheckComparison`, built from the period's
/// own `EarningsResult`. This view used to be handed a `TipBreakdown` and
/// recompute the comparison itself, which is how the History row and this
/// screen came to be two implementations of one verdict.
struct PaycheckComparisonView: View {
    let checked: PeriodCheckComparison
    let paycheck: PaycheckRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verdictLine)
                .font(PaydayFont.headline)
                .monospacedDigit()
                .foregroundStyle(checked.isShort ? PaydayColor.error : PaydayColor.primary)

            Text(comparisonCaption)
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
                .monospacedDigit()

            if let note = paycheck.note, !note.isEmpty {
                Text(note)
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textTertiary)
            }

            ForEach(stubDetailLines, id: \.label) { line in
                Text(line.text)
                    .font(PaydayFont.caption2)
                    .monospacedDigit()
                    .foregroundStyle(PaydayColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Capture-only stub facts (see PaycheckRecord's optional detail
    /// fields) — quiet caption lines under the comparison, nothing shown
    /// for whichever weren't entered, no layout change when none exist.
    /// hourlyRateCents/owedTipsCents are retired from the entry sheet
    /// (2026-07-27) but still shown here when present — legacy records that
    /// only ever had those two must stay legible.
    private var stubDetailLines: [(label: String, text: String)] {
        var lines: [(label: String, text: String)] = []
        if let regularWagesCents = paycheck.regularWagesCents {
            lines.append((label: "Regular wages", text: "Regular wages \(Money.string(fromCents: regularWagesCents))"))
        }
        if let overtimeWagesCents = paycheck.overtimeWagesCents {
            lines.append((label: "Overtime wages", text: "Overtime wages \(Money.string(fromCents: overtimeWagesCents))"))
        }
        if let gratuityCents = paycheck.gratuityCents {
            lines.append((label: "Gratuity", text: "Gratuity \(Money.string(fromCents: gratuityCents))"))
        }
        if let grossPayCents = paycheck.grossPayCents {
            lines.append((label: "Gross", text: "Gross \(Money.string(fromCents: grossPayCents))"))
        }
        if let taxesCents = paycheck.taxesCents {
            lines.append((label: "Taxes", text: "Taxes \(Money.string(fromCents: taxesCents))"))
        }
        if let netPayCents = paycheck.netPayCents {
            lines.append((label: "Net", text: "Net \(Money.string(fromCents: netPayCents))"))
        }
        if let hourlyRateCents = paycheck.hourlyRateCents {
            lines.append((label: "Hourly rate", text: "Hourly rate \(Money.string(fromCents: hourlyRateCents))"))
        }
        if let owedTipsCents = paycheck.owedTipsCents {
            lines.append((label: "Tips owed", text: "Tips owed \(Money.string(fromCents: owedTipsCents))"))
        }
        return lines
    }

    /// The whole verdict in one sentence — exact dollar gap, no exclamation
    /// marks. The explanatory paragraph that used to sit under this (cash
    /// tips aren't on the stub) is gone: true of every server everywhere,
    /// it doesn't need repeating on every period forever (Tyler's
    /// obviousness law, 2026-07-27).
    private var verdictLine: String {
        guard checked.deltaCents != 0 else { return "Matched exactly." }
        let amount = Money.string(fromCents: abs(checked.deltaCents))
        return checked.isShort ? "\(amount) short." : "\(amount) over."
    }

    private var comparisonCaption: String {
        let logged = Money.string(fromCents: checked.expectedTipsAndGratuityCents)
        let paid = Money.string(fromCents: checked.paidTipEarningsCents)
        if checked.usesCreditOnly {
            return "Logged \(logged) in card tips and gratuity · check paid \(paid)"
        }
        return "Logged \(logged) · check paid \(paid)"
    }
}
