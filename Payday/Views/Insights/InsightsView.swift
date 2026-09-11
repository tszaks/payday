import Combine
import SwiftUI
import SwiftData

/// Entirely deterministic. Every number and every sentence on this page is
/// computed by StatsEngine from local records, so the page renders the same
/// offline as on, instantly, with no spinner and no failure state.
///
/// It used to narrate through a model. That came off because the one job a
/// model could do here that arithmetic cannot — reading a written shift
/// note and tying it to a number — depends on shift notes, which are a
/// rarely-used feature. What remained was a model forbidden from doing
/// arithmetic, choosing among facts the engine already ranks, in exchange
/// for latency, a network dependency, a failure mode, and wording that
/// changed between visits.
///
/// InsightsService, InsightsStore, and NarrationRefresh are all still on
/// disk and still tested, simply unreferenced here. Reversible if notes
/// ever become real behavior.
struct InsightsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MoveLedgerStore.self) private var moveLedgerStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var isShowingBackfillSheet = false
    @State private var pageFactsCache: InsightsPageFactsCache?
    @State private var dataRevision = 0
    @State private var currentDay = Calendar.current.startOfDay(for: .now)

    var body: some View {
        let key = InsightsPageFactsKey(
            entriesRevision: dataRevision,
            ledgerRevision: moveLedgerStore.revision,
            currentDay: currentDay
        )
        let pageFacts = pageFactsCache?.key == key
            ? pageFactsCache!.facts
            : InsightsPageFacts(allEntries: allEntries, ledger: moveLedgerStore.firstShownAt, now: currentDay)
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
        .task(id: key) {
            pageFactsCache = InsightsPageFactsCache(key: key, facts: pageFacts)
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            dataRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshCurrentDay()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshCurrentDay() }
        }
    }

    private func refreshCurrentDay() {
        currentDay = Calendar.current.startOfDay(for: .now)
    }

    private func resultList(_ facts: InsightsFacts, pageFacts: InsightsPageFacts) -> some View {
        let moves = pageFacts.moves
        let followUps = pageFacts.followUps
        let recentNights = pageFacts.recentNights
        let plan = pageFacts.plan
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: PaydaySpacing.p16) {
                let shownFollowUps = Array(followUps.prefix(1))
                let primaryMove = moves.first
                let supportingMoves = Array(moves.dropFirst().prefix(2))
                let excludedTileIDs = InsightsPresentation.redundantMetricIDs(for: moves)
                let numberRows = InsightsNumbersGrid.rows(for: facts, excluding: excludedTileIDs)

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
                NightlyEarningsChart(nights: recentNights)
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
                // page is now entirely deterministic and renders the same
                // offline as on. The narration service is still on disk and
                // still tested, just unreferenced — see the type comment on
                // InsightsService for why it came off the page.

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

    /// "Half your Fridays land between $110 and $180 (twelve Fridays)."
    /// Weekday lines first, since "I'm on Friday, what should I expect" is
    /// the question actually being asked; the overall line is a different
    /// statistic and is labelled as one.
    private func reliabilitySection(_ reliability: StatsEngine.ReliabilityFacts) -> some View {
        VStack(alignment: .leading, spacing: PaydaySpacing.p12) {
            Text("WHAT YOU CAN COUNT ON")
                .font(PaydayFont.caption2)
                .tracking(0.8)
                .foregroundStyle(PaydayColor.primary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(reliability.byWeekday, id: \.self) { entry in
                    Text(RevealCopy.typicalRangeLine(entry.range, subject: Self.rangeSubject(for: entry)))
                        .font(PaydayFont.bodyRegular)
                        .foregroundStyle(PaydayColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let overall = reliability.overall {
                    Text(RevealCopy.typicalRangeLine(overall, subject: "shifts"))
                        .font(PaydayFont.subheadline)
                        .foregroundStyle(PaydayColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Every number Insights shows, computed once per render — see the
/// Dashboard's own DashboardFacts for the same fix applied there first.
/// StatsEngine construction (mapping every entry to a TipRecord) is a real
/// cost that doesn't need paying three separate times a render.
private struct InsightsPageFacts {
    let facts: InsightsFacts?
    let moves: [Move]
    let followUps: [FollowUp]
    /// Full history. NightlyEarningsChart owns progressive aggregation, so
    /// more history produces fewer, more meaningful weekly/monthly/yearly
    /// bars instead of an ever-denser row of daily marks.
    let recentNights: [(date: Date, cents: Int)]
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

    init(allEntries: [TipEntry], ledger: [String: Date], now: Date = .now) {
        let records = allEntries.map(TipRecord.init)
        let statsEngine = StatsEngine(records: records)
        facts = statsEngine.insightsFacts(referenceDate: now)
        moves = statsEngine.moves(referenceDate: now)
        followUps = statsEngine.followUps(ledger: ledger, referenceDate: now)
        recentNights = statsEngine.nightlyTotals()
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

private struct InsightsPageFactsKey: Hashable {
    let entriesRevision: Int
    let ledgerRevision: Int
    let currentDay: Date
}

private struct InsightsPageFactsCache {
    let key: InsightsPageFactsKey
    let facts: InsightsPageFacts
}

/// Page-level presentation rules that keep Insights decisive without moving
/// any arithmetic out of StatsEngine. Internal (rather than private) so the
/// anti-duplication and caveat filters can be tested directly.
enum InsightsPresentation {
    private static let dataNoteTerms = [
        "estimate", "estimated", "approximate", "unconfirmed", "not confirmed",
        "missing", "incomplete", "outage", "carried", "comped", "split check",
        "thin", "noisy", "partial", "limited data"
    ]

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

    static func dataNotes(from sections: [InsightSection]) -> [InsightSection] {
        Array(sections.filter { section in
            let text = "\(section.title) \(section.body)".lowercased()
            return dataNoteTerms.contains(where: text.contains)
        }.prefix(2))
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
