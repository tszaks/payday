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
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Environment(MoveLedgerStore.self) private var moveLedgerStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Upper bound on refresh cadence — "maybe weekly, twice a week at
    /// most." A visit to this tab checks whether this much time has passed
    /// since the last refresh; it never forces one sooner. A failed
    /// attempt is the one exception (see isRefreshDue).
    private static let minimumRefreshInterval: TimeInterval = 3.5 * 24 * 3600

    private var isModelAvailable: Bool {
        InsightsService.isConfigured
    }

    /// Stale means there's a narration on screen, but it was generated
    /// from older facts than what's showing now — the numbers moved since
    /// the last refresh. Still shown; just labeled.
    private func isNarrationStale(for facts: InsightsFacts) -> Bool {
        guard let snapshot = insightsStore.snapshot else { return false }
        return snapshot.facts != facts
    }

    /// Due when enough real time has passed AND the facts actually changed
    /// since the last refresh (nothing new logged means nothing new to
    /// say) — OR when the last attempt failed, which bypasses the interval
    /// gate entirely so a network hiccup gets one retry on the very next
    /// visit instead of waiting out the full interval with no recourse.
    private func isRefreshDue(facts: InsightsFacts) -> Bool {
        if insightsStore.lastAttemptFailed { return true }
        guard let snapshot = insightsStore.snapshot else { return true }
        guard facts != snapshot.facts else { return false }
        return Date.now.timeIntervalSince(snapshot.generatedAt) >= Self.minimumRefreshInterval
    }

    var body: some View {
        // Built once per render — StatsEngine construction (mapping every
        // entry to a TipRecord) was happening up to 4 times a render, once
        // per each of facts/moves/recentNights independently re-deriving
        // its own `statsEngine`, the same redundant-rebuild pattern P1.3
        // fixed on Dashboard.
        let pageFacts = InsightsPageFacts(allEntries: allEntries, ledger: moveLedgerStore.firstShownAt)
        NavigationStack {
            Group {
                if let facts = pageFacts.facts {
                    resultList(facts, moves: pageFacts.moves, followUps: pageFacts.followUps, recentNights: pageFacts.recentNights)
                } else {
                    ScrollView {
                        emptyState
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
        }
    }

    private func resultList(_ facts: InsightsFacts, moves: [Move], followUps: [FollowUp], recentNights: [(date: Date, cents: Int)]) -> some View {
        ScrollView {
            VStack(spacing: PaydaySpacing.p16) {
                // Follow-ups lead — a verdict on a past recommendation
                // outranks a fresh one, since it answers "did that actually
                // work" instead of just proposing something new. Flattened:
                // a section on the surface, not a card — the chart below is
                // this screen's one object.
                ForEach(followUps) { followUp in
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

                // Moves come next and are always fresh — deterministic
                // math, not narration, so there's nothing to wait on.
                // moves() already returns them ranked by annualized impact,
                // descending — the eye should land on the first one, so
                // only it gets the stronger "TOP MOVE" kicker. Restrained on
                // purpose: one clear lead, not a rainbow of emphasis.
                ForEach(Array(moves.enumerated()), id: \.element.id) { index, move in
                    VStack(alignment: .leading, spacing: 6) {
                        if index == 0 {
                            Text("TOP MOVE")
                                .font(PaydayFont.caption2)
                                .tracking(0.8)
                                .foregroundStyle(PaydayColor.onPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(PaydayColor.primary, in: Capsule())
                        } else {
                            Text("MOVE")
                                .font(PaydayFont.caption2)
                                .tracking(0.8)
                                .foregroundStyle(PaydayColor.primary)
                        }
                        Text(move.title)
                            .font(PaydayFont.headline)
                            .foregroundStyle(PaydayColor.textPrimary)
                        Text(move.body)
                            .font(PaydayFont.bodyRegular)
                            .foregroundStyle(PaydayColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }

                // THE NUMBERS — a flat, deterministic stat grid straight
                // off InsightsFacts. On screen instantly; never waits on
                // narration, and never conflicts with the totals law since
                // every figure here is a per-shift average, a rate, or a
                // share, not a total.
                let numberRows = InsightsNumbersGrid.rows(for: facts)
                if !numberRows.isEmpty {
                    VStack(spacing: PaydaySpacing.p16) {
                        ForEach(Array(numberRows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: PaydaySpacing.p16) {
                                ForEach(row) { tile in
                                    statTile(tile)
                                }
                            }
                        }
                    }
                    Divider()
                }

                // WORTH KNOWING — narration, trimmed to anomaly
                // explanations, caveats, or one synthesis (see
                // InsightsService's prompt). Never restates the grid above.
                // No fallback: when narration isn't available yet, this
                // section simply doesn't render and the grid stands alone.
                ForEach(worthKnowingSections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WORTH KNOWING")
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

                // Chart card — the one visual, and this screen's object: it
                // keeps its card while everything else here goes flat. The
                // chart owns its own label (it doubles as the scrub
                // readout), so no separate header here.
                NightlyEarningsChart(nights: recentNights)
                    .paydayCard()

                if isModelAvailable {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Updating your analysis…")
                                .font(PaydayFont.subheadline)
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.error)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    footnote(for: facts)
                }
            }
            .padding(.horizontal, PaydaySpacing.p16)
            .padding(.top, PaydaySpacing.p8)
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
    }

    @ViewBuilder
    private func footnote(for facts: InsightsFacts) -> some View {
        VStack(spacing: 4) {
            if isNarrationStale(for: facts) {
                Text("Reflects data through \(insightsStore.snapshot!.generatedAt.formatted(.dateTime.month(.abbreviated).day())). A newer summary is on the way.")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textSecondary)
            } else if let generatedAt = insightsStore.snapshot?.generatedAt {
                Text("Last updated \(generatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .font(PaydayFont.caption2)
                    .foregroundStyle(PaydayColor.textTertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, PaydaySpacing.p20)
        .padding(.top, PaydaySpacing.p4)
    }

    /// Whatever narration exists keeps showing — stale or not — rather than
    /// disappearing the moment new data arrives. Unlike THE NUMBERS grid
    /// (always on, computed straight from facts), there is no fallback
    /// here: before any narration has been generated, or when narration
    /// isn't configured, this is simply empty and the grid stands alone.
    private var worthKnowingSections: [InsightSection] {
        insightsStore.snapshot?.sections ?? []
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
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(PaydayFont.iconXL)
                .foregroundStyle(PaydayColor.textSecondary)
            Text("See where and when you earn the most.")
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
            Text("Log \(StatsEngine.minimumShiftsForInsights) shifts to unlock this.")
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
                .multilineTextAlignment(.center)
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
        } catch {
            errorMessage = error.localizedDescription
            insightsStore.lastAttemptFailed = true
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
    /// Most recent 30 nights only — legible on a compact chart width, and
    /// matches Insights' own "recent patterns" framing rather than dumping
    /// the user's entire history into one bar chart.
    let recentNights: [(date: Date, cents: Int)]

    init(allEntries: [TipEntry], ledger: [String: Date]) {
        let statsEngine = StatsEngine(records: allEntries.map(TipRecord.init))
        facts = statsEngine.insightsFacts()
        moves = statsEngine.moves()
        followUps = statsEngine.followUps(ledger: ledger)
        recentNights = Array(statsEngine.nightlyTotals().suffix(30))
    }
}
