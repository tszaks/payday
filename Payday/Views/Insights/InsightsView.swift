import Combine
import SwiftUI
import SwiftData

/// Entirely deterministic. Every number and every sentence on this page is
/// computed from local records, so the page renders the same offline as on,
/// instantly, with no spinner and no failure state.
///
/// It used to narrate through a model. That came off because the one job a
/// model could do here that arithmetic cannot — reading a written shift
/// note and tying it to a number — depends on shift notes, which are a
/// rarely-used feature. What remained was a model forbidden from doing
/// arithmetic, choosing among facts the engine already ranks, in exchange
/// for latency, a network dependency, a failure mode, and wording that
/// changed between visits. PR 5 group 2.7 finished that removal:
/// `InsightsService`, its prompt's sixteen money figures, and
/// `InsightsFactsCopy`'s ten prose sections are deleted, not dormant.
///
/// ## A PR 5 wave 2 adapter (groups 2.6 and 2.7)
///
/// To the contract in `Payday/Earnings/SnapshotFacts.swift`: presentation on
/// the facts struct, every money figure derived from one `EarningsSnapshot`,
/// no `Key` struct and no `dataRevision`, and no arithmetic in the view.
///
/// **What it fixes.** This view built its `StatsEngine` with no wage rate at
/// all, so every fact, chart point, typical range, trend, forecast and Move
/// on the page was `nonWageEarnings` while the hero on every other screen —
/// and the word "earnings" in this page's own section headers — was
/// wage-inclusive `earnedIncome`. `docs/METRICS.md` rows [IL-01] through
/// [IL-27] all carried "basis nonWageEarnings" for that reason. The engine is
/// now fed `InsightsEarnings.pricing(...)`, the ledger's own per-shift
/// `earnedIncome`, so one basis runs through every comparison on the page —
/// and that basis is DECLARED, once, by `InsightsBasis.note`, including when
/// it has to fall back to tips because some shift cannot be priced. Read
/// `InsightsEarnings`' header for why the fall-back is the whole page rather
/// than the offending comparison.
struct InsightsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MoveLedgerStore.self) private var moveLedgerStore
    @Environment(PolicyStore.self) private var policyStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var isShowingBackfillSheet = false
    @State private var renderCache: InsightsRenderCache?
    /// Bumped by `LegacySnapshotRevision` — `EarningsStore`'s own rebuild
    /// triggers — so the cached snapshot is rebuilt when, and only when, an
    /// input to it moved. Replaces the `@State private var dataRevision`
    /// this screen carried, which watched `ModelContext.didSave` alone: a
    /// queued policy change or a midnight rollover left the page serving
    /// figures computed under the old inputs. Gone entirely when PR 2 slice
    /// S7 lets this read `earningsStore.snapshot`.
    @State private var snapshotRevision = 0
    /// Any instant on the current civil day. The DAY itself is derived in
    /// `body` through the payroll calendar, not stored: a stored
    /// `Calendar.current.startOfDay` was the DEVICE's day, so a person who
    /// flew somewhere read a different reference date from the one the
    /// engine buckets by.
    @State private var dayTick = Date.now

    var body: some View {
        let payrollTimeZone = policyStore.payrollTimeZone
        let payrollCalendar = PayrollCalendar.gridCalendar(in: payrollTimeZone)
        let currentDay = payrollCalendar.startOfDay(for: dayTick)
        // The half of the render cache the snapshot's digest cannot cover,
        // because none of it is an input to the engine. Rule 3 deleted
        // `InsightsPageFactsKey`, which listed the inputs this screen THOUGHT
        // could move a number — the policies, the payroll zone, a
        // `dataRevision` counter. Every one of those is inside
        // `SnapshotStamp.digest` now, a SHA-256 over the complete input set.
        // What is left is genuinely presentational: which civil day it is,
        // and how many Moves have been shown.
        let selection = InsightsSelection(
            day: currentDay,
            ledgerRevision: moveLedgerStore.revision
        )
        // ONE grouping and ONE snapshot built from it, over the WHOLE history
        // — the recent-window scoping this page applies is a query argument,
        // never a property of the dataset, because the ledger allocates the
        // overtime threshold across a complete workweek and a windowed slice
        // cannot price the forty-first hour of a week that began before the
        // window. `InsightsEarnings` holds the pair together and its header
        // carries the two defects that come from doing either one twice.
        //
        // `LegacySnapshotBridge` and not `earningsStore.snapshot`: nothing
        // writes `ShiftRecord` on a device until PR 2 slice S7, so the
        // store's snapshot is empty and a screen on it would show a person
        // with years of shifts a blank page. The swap is inside
        // `InsightsEarnings.build`.
        let dataset = renderCache?.revision == snapshotRevision
            ? renderCache!.dataset
            : InsightsEarnings.build(
                entries: allEntries,
                policies: policyStore.policies,
                payrollTimeZone: payrollTimeZone,
                calendar: payrollCalendar
            )
        // Rule 3: the facts are keyed on the dataset's own digest, the
        // complete computed key, plus this screen's presentational selection.
        let pageFacts = renderCache?.digest == dataset.snapshot?.stamp.digest
            && renderCache?.selection == selection
            ? renderCache!.facts
            : InsightsPageFacts(
                dataset: dataset,
                ledger: moveLedgerStore.firstShownAt,
                payrollTimeZone: payrollTimeZone,
                calendar: payrollCalendar,
                now: currentDay
            )
        NavigationStack {
            Group {
                if let facts = pageFacts.facts {
                    resultList(facts, pageFacts: pageFacts)
                } else {
                    ScrollView {
                        emptyState(unlocks: pageFacts.unlocks, shiftCount: pageFacts.shiftCount)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
            }
            .background(PaydayColor.background)
            .navigationTitle("Insights")
            .task(id: pageFacts.moves.map(\.id)) {
                moveLedgerStore.recordShown(pageFacts.moves)
            }
            .sheet(isPresented: $isShowingBackfillSheet) {
                BackfillSheet().paydayAppearance()
            }
            // QA-only, same launch-arg pattern as -InitialTab: simctl can't
            // tap, so screenshot QA needs the sheet to present itself.
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-OpenBackfillSheet") {
                    isShowingBackfillSheet = true
                }
            }
        }
        .task(id: InsightsCacheIdentity(revision: snapshotRevision, selection: selection)) {
            renderCache = InsightsRenderCache(
                revision: snapshotRevision,
                dataset: dataset,
                digest: dataset.snapshot?.stamp.digest,
                selection: selection,
                facts: pageFacts
            )
        }
        .legacySnapshotRevision($snapshotRevision)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            dayTick = .now
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { dayTick = .now }
        }
    }

    private func resultList(_ facts: InsightsFacts, pageFacts: InsightsPageFacts) -> some View {
        let moves = pageFacts.moves
        let followUps = pageFacts.followUps
        let chartFacts = pageFacts.chartFacts
        let plan = pageFacts.plan
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: PaydaySpacing.p16) {
                let shownFollowUps = Array(followUps.prefix(1))
                let primaryMove = moves.first
                let supportingMoves = Array(moves.dropFirst().prefix(2))
                let excludedTileIDs = InsightsPresentation.redundantMetricIDs(for: moves)
                let numberRows = InsightsNumbersGrid.rows(
                    for: facts,
                    hourly: pageFacts.hourly,
                    excluding: excludedTileIDs
                )

                // The basis, said ONCE, above every figure it governs.
                //
                // This is the plan's rule ("every comparison declares its
                // basis") satisfied by declaring it for the page, because the
                // page is on one basis by construction — `StatsEngine` reads
                // a shift's money in exactly one place and the whole engine
                // was handed one pricing. Thirty tiles each restating it
                // reads as a form letter and eats the first screen, which is
                // the same call this screen already made for the
                // interquartile qualifier two sections down ("Said once here
                // instead of five times below").
                //
                // The four tiles that are deliberately NOT on the page basis
                // — TIP PERCENT, SPEND / GUEST, TIPS / TABLE, CASH NIGHTS —
                // each name theirs in their own caption, because a wage is
                // not a tip and folding one in would make "tipped 16.7% of
                // sales" false. See `InsightsEarnings`' header.
                if let note = pageFacts.basis.note {
                    Text(note)
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Reliability leads the page. A server already knows the
                // SHAPE of their week — that Friday is good and Monday is
                // dead. What no amount of experience tells them is the
                // SPREAD, which is the number anyone budgeting on variable
                // income actually needs. It is also true from the first
                // qualifying weekday and never false-alarms, which is why
                // it holds the lead slot rather than the trend.
                if let reliability = pageFacts.reliability, reliability.hasVisibleRanges {
                    reliabilitySection(reliability)
                    Divider()
                }

                // Level over time. Often correctly absent: it demands a
                // fully-covered prior window, twelve shifts a side, a
                // stable-enough schedule, and both a materiality and a
                // precision gate. See StatsEngine.earningTrend.
                if let trend = pageFacts.trend {
                    trendSection(trend)
                    Divider()
                }

                // Change — something that MOVED outranks a standing
                // pattern, since a shift in the data is the newer fact. Only
                // the largest change leads; the full ledger still informs
                // future ranking without turning this into a feed.
                ForEach(shownFollowUps) { followUp in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SINCE THEN")
                            .font(PaydayFont.caption2)
                            .tracking(0.8)
                            .foregroundStyle(PaydayColor.primary)
                        Text(followUp.title)
                            .font(PaydayFont.headline)
                            .foregroundStyle(PaydayColor.textPrimary)
                        Text(followUp.body)
                            .font(PaydayFont.bodyRegular)
                            .foregroundStyle(PaydayColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }

                // One finding owns the top of the screen. Moves are already
                // ranked by strength of evidence; stating that hierarchy
                // explicitly is easier to scan than three equally loud essays.
                // The header describes rather than instructs — this page
                // reports what the data shows and leaves the decision to the
                // reader (see StatsEngine.moves()).
                if let primaryMove {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WHAT STANDS OUT")
                            .font(PaydayFont.caption2)
                            .tracking(0.8)
                            .foregroundStyle(PaydayColor.primary)
                        Text(primaryMove.title)
                            .font(PaydayFont.title3)
                            .foregroundStyle(PaydayColor.textPrimary)
                        Text(primaryMove.body)
                            .font(PaydayFont.bodyRegular)
                            .foregroundStyle(PaydayColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }

                if !supportingMoves.isEmpty {
                    VStack(alignment: .leading, spacing: PaydaySpacing.p12) {
                        Text("OTHER SIGNALS")
                            .font(PaydayFont.caption2)
                            .tracking(0.8)
                            .foregroundStyle(PaydayColor.primary)
                        ForEach(Array(supportingMoves.enumerated()), id: \.element.id) { index, move in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(move.title)
                                    .font(PaydayFont.headline)
                                    .foregroundStyle(PaydayColor.textPrimary)
                                Text(InsightsPresentation.compactBody(for: move))
                                    .font(PaydayFont.subheadline)
                                    .foregroundStyle(PaydayColor.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if index < supportingMoves.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }

                // Deterministic metrics render immediately. Exact facts that
                // already appear in a Move are omitted here so the user never
                // has to decode the same 4 PM comparison twice.
                if !numberRows.isEmpty {
                    VStack(alignment: .leading, spacing: PaydaySpacing.p12) {
                        Text("AT A GLANCE")
                            .font(PaydayFont.caption2)
                            .tracking(0.8)
                            .foregroundStyle(PaydayColor.primary)
                        VStack(spacing: PaydaySpacing.p16) {
                            ForEach(numberRows, id: \.first?.id) { row in
                                HStack(spacing: PaydaySpacing.p16) {
                                    ForEach(row) { tile in
                                        statTile(tile)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                }

                // Chart card — the one visual, and this screen's object: it
                // keeps its card while everything else here goes flat. The
                // chart owns its own label (it doubles as the scrub
                // readout), so no separate header here.
                NightlyEarningsChart(facts: chartFacts)
                    .paydayCard()

                // A description of the week ahead at the reader's existing
                // rhythm, not a schedule to follow: each weekday and amount
                // gets its own row so the total can be checked at a glance
                // and sample sizes remain explicit. The optional-pickup row
                // was removed — suggesting an extra shift is the one thing
                // on this page that told the reader what to do.
                if let plan {
                    VStack(alignment: .leading, spacing: PaydaySpacing.p12) {
                        Text("THE WEEK AHEAD")
                            .font(PaydayFont.caption2)
                            .tracking(0.8)
                            .foregroundStyle(PaydayColor.primary)
                        Text(PlanForwardCopy.headline(for: plan))
                            .font(PaydayFont.headline)
                            .foregroundStyle(PaydayColor.textPrimary)
                        // The forecast's own track record, attached to the
                        // forecast rather than given its own section: it is
                        // a fact about the estimate, not about the reader.
                        if let accuracy = pageFacts.forecastAccuracy {
                            Text(RevealCopy.forecastAccuracyLine(accuracy))
                                .font(PaydayFont.caption)
                                .foregroundStyle(PaydayColor.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let biasLine = RevealCopy.forecastBiasLine(accuracy) {
                                Text(biasLine)
                                    .font(PaydayFont.caption)
                                    .foregroundStyle(PaydayColor.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        VStack(spacing: PaydaySpacing.p12) {
                            ForEach(plan.nights, id: \.weekday) { night in
                                planNightRow(night)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }

                // No DATA NOTE section, no spinner, no error caption: this
                // page is entirely deterministic and renders the same offline
                // as on. PR 5 group 2.7 deleted the narration service rather
                // than leaving it dormant on disk — see this view's header.

                Color.clear.frame(height: PaydaySpacing.p8).id("insights-bottom")
            }
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.top, PaydaySpacing.p8)
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        // QA-only, same launch-arg pattern as -InitialTab: simctl can
        // screenshot but not scroll, so below-the-fold QA scrolls itself.
        .onAppear {
            guard ProcessInfo.processInfo.arguments.contains("-ScrollInsightsBottom") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(nil) { proxy.scrollTo("insights-bottom", anchor: .bottom) }
            }
        }
        }
    }

    /// One tile in THE NUMBERS grid: a green uppercase label, a big
    /// monospaced value, and a caption context line underneath.
    private func statTile(_ tile: InsightsNumberTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.label)
                .font(PaydayFont.caption2)
                .tracking(0.8)
                .foregroundStyle(PaydayColor.primary)
            Text(tile.value)
                .font(PaydayFont.displayCompact)
                .foregroundStyle(PaydayColor.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tile.context)
                .font(PaydayFont.caption2)
                .foregroundStyle(PaydayColor.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Ranges are a TABLE, not prose: weekday, range, sample size. Written
    /// as sentences it came out as five near-identical lines all opening
    /// with "Half your …", which read as a form letter and ate the whole
    /// first screen. The qualifier belongs in the subhead, said once.
    ///
    /// Deliberately the same row shape as THE WEEK AHEAD below (see
    /// planNightRow): label and sample on the left, the number on the
    /// right, monospaced so the column lines up.
    private func reliabilitySection(_ reliability: StatsEngine.ReliabilityFacts) -> some View {
        VStack(alignment: .leading, spacing: PaydaySpacing.p12) {
            VStack(alignment: .leading, spacing: 4) {
                // NOT "what you can count on", which is what this said
                // first and which the statistic does not support. A
                // middle-50% range is not a floor — a quarter of shifts
                // come in under the low number. You can count on a floor;
                // you cannot count on a middle. This header describes the
                // range rather than promising something about it.
                Text("WHAT A SHIFT USUALLY PAYS")
                    .font(PaydayFont.caption2)
                    .tracking(0.8)
                    .foregroundStyle(PaydayColor.primary)
                // Said once here instead of five times below. The second
                // sentence exists because the first one raises the obvious
                // question and leaving it unanswered invites reading the
                // low number as a guarantee.
                Text("Half your shifts land in these ranges. A quarter come in under the low end.")
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            VStack(spacing: PaydaySpacing.p12) {
                ForEach(reliability.byWeekday, id: \.self) { entry in
                    typicalRangeRow(
                        label: Self.rangeSubject(for: entry),
                        basis: Self.shiftCountBasis(entry.range.shiftCount),
                        range: entry.range
                    )
                }
                if let overall = reliability.overall {
                    // A different statistic, not a summary of the rows: its
                    // width is driven by weekday mix rather than by
                    // night-to-night uncertainty. Separated and quieted.
                    Divider()
                    typicalRangeRow(
                        label: "All shifts",
                        basis: Self.shiftCountBasis(overall.shiftCount),
                        range: overall,
                        isMuted: true
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func typicalRangeRow(label: String, basis: String, range: StatsEngine.TypicalRange, isMuted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PaydaySpacing.p12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(PaydayFont.subheadlineSemibold)
                    .foregroundStyle(isMuted ? PaydayColor.textSecondary : PaydayColor.textPrimary)
                Text(basis)
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            Spacer(minLength: PaydaySpacing.p12)
            Text("\(Money.wholeDollarString(fromCents: range.lowCents))–\(Money.wholeDollarString(fromCents: range.highCents))")
                .font(PaydayFont.subheadlineSemibold)
                .monospacedDigit()
                .foregroundStyle(isMuted ? PaydayColor.textSecondary : PaydayColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), half land between \(Money.wholeDollarString(fromCents: range.lowCents)) and \(Money.wholeDollarString(fromCents: range.highCents)). \(basis).")
    }

    /// Just the count. It used to read "Across 13 Sunday lunches" directly
    /// under a row already titled "Sunday lunches", which put the same
    /// words on two adjacent lines of every single row. The sample size is
    /// an honesty device and stays; the noun was pure repetition.
    private static func shiftCountBasis(_ count: Int) -> String {
        count == 1 ? "1 shift" : "\(count) shifts"
    }

    /// "Fridays", or "Friday lunches" / "Friday dinners" when the weekday
    /// was split because each service clears the bar on its own.
    private static func rangeSubject(for entry: StatsEngine.WeekdayTypicalRange) -> String {
        let name = InsightsPresentation.weekdayName(entry.weekday)
        switch entry.shiftPeriod {
        case .lunch: return "\(name) lunches"
        case .dinner: return "\(name) dinners"
        case nil: return "\(name)s"
        }
    }

    /// The level line and the schedule line stay separate on purpose:
    /// working more is not earning more per shift, and running them
    /// together is the exact conflation the stratification prevents.
    private func trendSection(_ trend: StatsEngine.EarningTrend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOW IT'S BEEN RUNNING")
                .font(PaydayFont.caption2)
                .tracking(0.8)
                .foregroundStyle(PaydayColor.primary)
            Text(RevealCopy.trendLine(trend))
                .font(PaydayFont.bodyRegular)
                .foregroundStyle(PaydayColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let scheduleLine = RevealCopy.trendScheduleLine(trend) {
                Text(scheduleLine)
                    .font(PaydayFont.subheadline)
                    .foregroundStyle(PaydayColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planNightRow(_ night: PlanForward.Night) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PaydaySpacing.p12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(InsightsPresentation.weekdayName(night.weekday))
                    .font(PaydayFont.subheadlineSemibold)
                    .foregroundStyle(PaydayColor.textPrimary)
                Text(InsightsPresentation.sampleBasis(weekday: night.weekday, count: night.nightCount))
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            }
            Spacer(minLength: PaydaySpacing.p12)
            Text(Money.wholeDollarString(fromCents: night.averageNetCents))
                .font(PaydayFont.displaySmall)
                .foregroundStyle(PaydayColor.textPrimary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func emptyState(unlocks: [Unlock], shiftCount: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(PaydayFont.iconXL)
                .foregroundStyle(PaydayColor.textSecondary)
            Text(shiftCount == 0 ? "Log \(StatsEngine.minimumShiftsForInsights) shifts for insights" : "Insights unlock at \(StatsEngine.minimumShiftsForInsights) shifts")
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
            if let insightsUnlock = unlocks.first(where: { $0.kind == .insights }), shiftCount > 0 {
                Text("\(insightsUnlock.have) of \(insightsUnlock.need)")
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.textSecondary)
                Capsule()
                    .fill(PaydayColor.fieldBackground)
                    .frame(width: 160, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(PaydayColor.primary)
                            .frame(width: 160 * CGFloat(insightsUnlock.have) / CGFloat(insightsUnlock.need), height: 4)
                    }
                    .accessibilityHidden(true)
            }
            Button("Add Past Shifts") { isShowingBackfillSheet = true }
                .font(PaydayFont.subheadline)
                .foregroundStyle(PaydayColor.primary)
                .buttonStyle(.plain)
        }
        .padding(.top, 40)
    }

}

/// Every number Insights shows, computed once per render.
///
/// A PR 5 adapter: presentation and already-computed figures only. The two
/// things it adds over the pre-wave-2 version are the reason group 2.6
/// exists — `basis`, the page's declared metric, and `hourly`, the one $/hr
/// figure, taken from the engine rather than divided here.
///
/// It carries `stamp` (contract rule 3) so a disagreement with another
/// screen is diffable: same digest means same dataset, by construction. A nil
/// stamp means no dataset stands behind the page at all, and then `basis` is
/// `.unavailable` and every figure below refuses rather than reading zero.
///
/// **Internal, not private**, for the reason `DashboardFacts`,
/// `PeriodsPageFacts`, `PeriodDetailFacts`, `DayDetailFacts` and
/// `LogShiftFacts` are: the plan's completion rule 2 is "its parity test
/// passes against the real adapter, not a helper." While this was private the
/// suite could not reach it, restated the construction in a helper of its
/// own, and therefore did not gate the screen at all — with
/// `valuedShiftCents` patched to nil here, reverting the whole page to
/// tips-only under wage-inclusive headers, the full app suite still reported
/// `Test run with 855 tests in 154 suites passed`.
struct InsightsPageFacts: SnapshotFacts {
    let stamp: SnapshotStamp?
    /// What every money figure on this page is, in one value. Rendered as a
    /// sentence above the figures by `resultList`.
    let basis: InsightsBasis
    /// `MetricID.hourlyRate` over the same recent window the grid covers,
    /// with its coverage. Nil when the engine cannot answer — never a
    /// fabricated `$0/hr` — **and nil whenever the page is not on a
    /// wage-inclusive basis**, because `hourlyRate` is `earnedIncome` over
    /// minutes by registry definition (`EarningsResult.hourlyRateCents`
    /// divides `coveredComponents.earnedIncomeCents`) and there is no
    /// tips-only rate in the registry to fall back to. A $/hr tile under
    /// "Every figure below is tips only" would be the one wage-inclusive
    /// number left on a tips-only page.
    ///
    /// The consequence, stated rather than hidden: a wage-inclusive basis
    /// means every shift in the dataset is wage-valued, which means every
    /// shift has hours, so `HourlyRate.coverage`'s "across 5 of 6 shifts"
    /// fraction is now unreachable FROM THIS SCREEN. It stays because
    /// `docs/METRICS.md`'s presentation rules require it of the metric and
    /// History's caption for the same metric still reaches it. Whether
    /// Insights should instead show a tips-only $/hr — which needs a
    /// registry metric, not a division here — is a decision for Tyler,
    /// flagged the same way the whole-history completeness gate is.
    let hourly: InsightsEarnings.HourlyRate?
    let facts: InsightsFacts?
    let moves: [Move]
    let followUps: [FollowUp]
    /// Full history, one engine query per bar. NightlyEarningsChart owns
    /// progressive aggregation, so more history produces fewer, more
    /// meaningful weekly/monthly/yearly bars instead of an ever-denser row
    /// of daily marks.
    ///
    /// PR 5 wave 0: the bars used to be `StatsEngine.nightlyTotals`, which
    /// is `nonWageEarnings` — so under a wage-inclusive page they were
    /// short by every hour worked and had no way to say so (the M1 fixture's
    /// defect). They are now `snapshot.day(_:)`, wage-inclusive and carrying
    /// their own completeness, each bar rendering an `EarningsFigure`. Wave 2
    /// put everything ELSE on this screen on the same basis, via
    /// `StatsEngine`'s pricing.
    ///
    /// And then the bars follow the PAGE basis rather than being
    /// wage-inclusive by construction. Wave 2's first cut hard-coded
    /// `EarningsFigure.earnedIncome` in `EarningsChartPoint`, so on a
    /// `.partial` dataset — the ordinary case, since every shift added through
    /// "Add Past Shifts" is hours-less — the bars read 26,500c / 24,000c /
    /// 7,500c / 25,800c / 25,500c over the same five days the tiles, the
    /// typical range, the plan and the day totals read 10,500c / 9,000c /
    /// 7,500c / 9,800c / 10,500c, under a note saying every figure below was
    /// tips only and a bar label saying "Total". `basis.chartMetric` is what
    /// closes that.
    let chartFacts: EarningsChartFacts
    /// What unlocks next, and how close — see UnlockProgress.
    let unlocks: [Unlock]
    let shiftCount: Int
    /// A deterministic look one week ahead — see StatsEngine.planForward.
    let plan: PlanForward?
    /// What a shift typically pays — see StatsEngine.typicalRanges.
    let reliability: StatsEngine.ReliabilityFacts?
    /// Whether the earning LEVEL moved — see StatsEngine.earningTrend.
    let trend: StatsEngine.EarningTrend?
    /// How close `plan` has been — see StatsEngine.forecastAccuracy.
    /// Twelve retrospective engines, so it belongs here in the cached
    /// facts and never in a view body.
    let forecastAccuracy: StatsEngine.ForecastAccuracy?

    /// - Parameters:
    ///   - dataset: the page's ONE snapshot and the grouping it was built
    ///     from. The records below are flattened out of that same grouping
    ///     rather than passed in alongside it, so the engine and the snapshot
    ///     cannot be looking at two different sets of rows.
    ///   - calendar: the GRID calendar in the frozen payroll zone, the SAME
    ///     one `InsightsEarnings.build` grouped with. It has to be: a legacy
    ///     `TipEntry` with `shiftID == nil` takes a deterministic id derived
    ///     from `calendar.startOfDay(...)`, so two calendars mint two ids for
    ///     one shift and the pricing map misses.
    init(
        dataset: InsightsEarnings.Dataset,
        ledger: [String: Date],
        payrollTimeZone: TimeZone,
        calendar: Calendar,
        now: Date = .now
    ) {
        let snapshot = dataset.snapshot
        stamp = snapshot?.stamp
        // ONE decision, from the dataset's own `Completeness`, before any
        // figure is computed — and then every money surface below reads it.
        // Group 2.6 first shipped with only `StatsEngine` governed by it,
        // which left the chart and the HOURLY tile wage-inclusive under a
        // note reading "Every figure below is tips only": one day was
        // $265.00 on the chart and $105.00 in the tiles beside it.
        let basis = InsightsEarnings.basis(for: snapshot)
        self.basis = basis
        let records = dataset.shiftDays.flatMap(\.items).map(TipRecord.init)
        // The engine is built by `InsightsEarnings.engine`, not here, so the
        // parity suite gates this wiring instead of restating it. See that
        // function's header for the measurement that made it a function.
        let statsEngine = InsightsEarnings.engine(
            for: dataset,
            payrollTimeZone: payrollTimeZone,
            calendar: calendar
        )
        facts = statsEngine.insightsFacts(referenceDate: now)
        // `hourlyRate` is `earnedIncome` over minutes by registry definition,
        // so it is only askable on a wage-inclusive page. See the property.
        hourly = basis.isWageInclusive
            ? InsightsEarnings.hourlyRate(
                snapshot,
                referenceDate: now,
                in: payrollTimeZone
            )
            : nil
        moves = statsEngine.moves(referenceDate: now)
        followUps = statsEngine.followUps(ledger: ledger, referenceDate: now)
        chartFacts = EarningsChartFacts(
            wholeOf: snapshot,
            timeZone: payrollTimeZone,
            // The bars name the metric the page declared, so the peak
            // callout, the scrub readout and the bar label are the same
            // cents and the same noun as everything under the note.
            metric: basis.chartMetric
        )
        // Use the same rotation PLAN names as "your usual nights."
        unlocks = UnlockProgress.nextUnlocks(
            records: records,
            usualWeekdays: statsEngine.workRhythm(referenceDate: now).usualWeekdays
        )
        shiftCount = UnlockProgress.shiftCount(records: records)
        plan = statsEngine.planForward(referenceDate: now)
        reliability = statsEngine.typicalRanges(referenceDate: now)
        trend = statsEngine.earningTrend(referenceDate: now)
        forecastAccuracy = statsEngine.forecastAccuracy(referenceDate: now)
    }
}

/// The presentational remainder the snapshot's digest cannot cover.
///
/// `day` because every window on this page (the 180-day facts window, the
/// trend's two eight-week halves, the forecast's twelve weeks, the plan's
/// coming week) is measured back from today. `ledgerRevision` because which
/// Moves have already been SHOWN decides which follow-ups exist, and that is
/// a record of what the person has seen rather than an input to any number.
private struct InsightsSelection: Hashable {
    let day: Date
    let ledgerRevision: Int
}

private struct InsightsCacheIdentity: Hashable {
    let revision: Int
    let selection: InsightsSelection
}

/// One render's worth of work, kept so a `@State` change (presenting the
/// backfill sheet, scrubbing the chart) does not redo it.
///
/// Two independent reuse tests, because the two halves cost different things,
/// the same split `DashboardRenderCache` documents:
///
/// - The DATASET (the grouping and the snapshot built from it) is valid while
///   `revision` has not moved. `LegacySnapshotBridge` costs 41.7 ms over
///   1,000 shifts and 307.4 ms over 10,000 (MEASURED, iPhone 17 Pro
///   simulator, 2026-09-18), so it must not run per `body`.
/// - The FACTS are valid while the dataset digest and the selection have not
///   moved. `digest` is the complete key; `selection` is the presentational
///   remainder.
private struct InsightsRenderCache {
    let revision: Int
    /// The grouping AND the snapshot built from it, together, because they
    /// have to be the same pair every render: the grouping's `shiftID`s are
    /// what index the snapshot, and what the pricing map is checked against.
    let dataset: InsightsEarnings.Dataset
    let digest: String?
    let selection: InsightsSelection
    let facts: InsightsPageFacts
}

/// Page-level presentation rules that keep Insights decisive without moving
/// any arithmetic out of StatsEngine. Internal (rather than private) so the
/// anti-duplication and caveat filters can be tested directly.
enum InsightsPresentation {
    static func redundantMetricIDs(for moves: [Move]) -> Set<String> {
        var result: Set<String> = []
        if moves.contains(where: { $0.id == "startTimeLeader" }) {
            result.insert("startTimes")
        }
        return result
    }

    /// Supporting signals need the comparison and any honesty hedge, not a
    /// second annual projection beneath the fully explained primary Move.
    static func compactBody(for move: Move) -> String {
        let parts = move.body.components(separatedBy: ". ")
        guard let first = parts.first, !first.isEmpty else { return move.body }
        var result = sentence(first)
        if let hedge = parts.dropFirst().first(where: { $0.hasPrefix("Only ") }) {
            result += " \(sentence(hedge))"
        }
        return result
    }

    static func weekdayName(_ weekday: Int) -> String {
        guard Calendar.current.weekdaySymbols.indices.contains(weekday - 1) else { return "Shift" }
        return Calendar.current.weekdaySymbols[weekday - 1]
    }

    static func sampleBasis(weekday: Int, count: Int) -> String {
        let name = weekdayName(weekday)
        return count == 1 ? "Based on 1 \(name)" : "Based on \(count) \(name)s"
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }
}
