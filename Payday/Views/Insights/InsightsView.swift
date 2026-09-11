import Combine
import SwiftUI
import SwiftData

/// The stats engine computes the facts; OpenAI's gpt-5.6-terra narrates
/// them over the network. This is autonomous, not on-demand — there is
/// deliberately no "Analyze Now" control anywhere. A refresh only happens
/// when it's actually due (see minimumRefreshInterval below) and there's
/// something new to say; visiting this tab can trigger that check, but
/// never a person's tap. Each refresh amends the previous narration rather
/// than rewriting it from scratch, so wording should settle down and
/// change less over time as patterns stabilize, not reshuffle every visit.
/// Between refreshes the last narration keeps showing (marked stale, never
/// discarded) rather than dropping back to the plain facts — someone who
/// logs nightly should see prose almost all the time, not robo-facts.
struct InsightsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Environment(MoveLedgerStore.self) private var moveLedgerStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingBackfillSheet = false
    @State private var pageFactsCache: InsightsPageFactsCache?
    @State private var dataRevision = 0
    @State private var currentDay = Calendar.current.startOfDay(for: .now)

    // Cadence and the failure cooldown both live in NarrationRefresh, which is
    // pure and tested — this rule decides when real money gets spent.

    private var isModelAvailable: Bool {
        InsightsService.isConfigured
    }

    /// Due when enough real time has passed AND the facts actually changed
    /// since the last refresh (nothing new logged means nothing new to
    /// say) — OR when the last attempt failed, which bypasses the interval
    /// gate entirely so a network hiccup gets one retry on the very next
    /// visit instead of waiting out the full interval with no recourse.
    private func isRefreshDue(facts: InsightsFacts) -> Bool {
        let snapshot = insightsStore.snapshot
        return NarrationRefresh.isDue(
            now: .now,
            snapshotGeneratedAt: snapshot?.generatedAt,
            // flatMap, not `snapshot?.facts`, to keep this a single-level
            // optional compare — snapshot is optional AND its facts are
            // optional (a snapshot persisted before that field existed).
            factsMatchSnapshot: snapshot.flatMap(\.facts) == facts,
            lastAttemptFailed: insightsStore.lastAttemptFailed,
            lastAttemptAt: insightsStore.lastAttemptAt
        )
    }

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
                    resultList(facts, moves: pageFacts.moves, followUps: pageFacts.followUps, recentNights: pageFacts.recentNights, plan: pageFacts.plan)
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
            .task(id: pageFacts.facts) {
                guard isModelAvailable, let facts = pageFacts.facts, isRefreshDue(facts: facts) else { return }
                await refresh(facts: facts, topMove: pageFacts.moves.first, latestFollowUp: pageFacts.followUps.first)
            }
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

    private func resultList(_ facts: InsightsFacts, moves: [Move], followUps: [FollowUp], recentNights: [(date: Date, cents: Int)], plan: PlanForward?) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: PaydaySpacing.p16) {
                let shownFollowUps = Array(followUps.prefix(1))
                let primaryMove = moves.first
                let supportingMoves = Array(moves.dropFirst().prefix(2))
                let excludedTileIDs = InsightsPresentation.redundantMetricIDs(for: moves)
                let numberRows = InsightsNumbersGrid.rows(for: facts, excluding: excludedTileIDs)

                // Change leads — something that MOVED outranks a standing
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
                        VStack(spacing: PaydaySpacing.p12) {
                            ForEach(plan.nights, id: \.weekday) { night in
                                planNightRow(night)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }

                // Model narration is deliberately demoted to data-quality
                // context. The observations already exist above; repeating
                // them under "Worth Knowing" made the page longer without
                // making it smarter.
                ForEach(dataNoteSections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DATA NOTE")
                            .font(PaydayFont.caption2)
                            .tracking(0.8)
                            .foregroundStyle(PaydayColor.primary)
                        Text(section.title)
                            .font(PaydayFont.headline)
                            .foregroundStyle(PaydayColor.textPrimary)
                        Text(section.body)
                            .font(PaydayFont.bodyRegular)
                            .foregroundStyle(PaydayColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }

                if isModelAvailable {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Updating…")
                                .font(PaydayFont.subheadline)
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.error)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

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

    /// Narration no longer competes with deterministic recommendations. It
    /// survives only when it explains an anomaly or warns that a figure is
    /// estimated/incomplete, and at most two notes can reach the page.
    private var dataNoteSections: [InsightSection] {
        InsightsPresentation.dataNotes(from: insightsStore.snapshot?.sections ?? [])
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

    private func refresh(facts: InsightsFacts, topMove: Move?, latestFollowUp: FollowUp?) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let frequency = scheduleStore.schedule?.frequency ?? .biweekly
        do {
            let sections = try await InsightsService.narrate(
                facts: facts,
                scheduleFrequency: frequency,
                previousSections: insightsStore.snapshot?.sections,
                topMove: topMove,
                latestFollowUp: latestFollowUp
            )
            insightsStore.snapshot = InsightsSnapshot(sections: sections, generatedAt: .now, facts: facts)
            insightsStore.lastAttemptFailed = false
            insightsStore.lastAttemptAt = .now
        } catch {
            errorMessage = error.localizedDescription
            // Only a retryable failure earns the interval bypass. A 4xx or an
            // unparseable answer will fail the same way on the same input, so
            // it waits for the facts to change or the normal interval — the
            // parse case has already been billed once and must not bill again
            // on the next visit to this tab.
            insightsStore.lastAttemptFailed = (error as? InsightsError)?.isRetryable ?? true
            insightsStore.lastAttemptAt = .now
        }
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
