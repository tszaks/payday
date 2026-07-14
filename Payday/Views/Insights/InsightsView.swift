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
struct InsightsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Upper bound on refresh cadence — "maybe weekly, twice a week at
    /// most." A visit to this tab checks whether this much time has passed
    /// since the last refresh; it never forces one sooner.
    private static let minimumRefreshInterval: TimeInterval = 3.5 * 24 * 3600

    private var statsEngine: StatsEngine {
        StatsEngine(records: allEntries.map(TipRecord.init))
    }

    private var facts: InsightsFacts? {
        statsEngine.insightsFacts()
    }

    /// Most recent 30 nights only — legible on a compact chart width, and
    /// matches Insights' own "recent patterns" framing rather than dumping
    /// the user's entire history into one bar chart.
    private var recentNights: [(date: Date, cents: Int)] {
        Array(statsEngine.nightlyTotals().suffix(30))
    }

    private var isModelAvailable: Bool {
        InsightsService.isConfigured
    }

    /// Due only when enough real time has passed AND the facts actually
    /// changed since the last refresh — nothing new logged means nothing
    /// new to say, so there's no reason to spend a call on it.
    private func isRefreshDue(facts: InsightsFacts) -> Bool {
        guard let snapshot = insightsStore.snapshot else { return true }
        guard facts != snapshot.facts else { return false }
        return Date.now.timeIntervalSince(snapshot.generatedAt) >= Self.minimumRefreshInterval
    }

    var body: some View {
        NavigationStack {
            Group {
                if let facts {
                    resultList(facts)
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
            .task(id: facts) {
                guard isModelAvailable, let facts, isRefreshDue(facts: facts) else { return }
                await refresh(facts: facts)
            }
        }
    }

    private func resultList(_ facts: InsightsFacts) -> some View {
        List {
            Section {
                NightlyEarningsChart(nights: recentNights)
                    .padding(.vertical, 4)
            }
            .listRowBackground(PaydayColor.background)

            if isModelAvailable {
                Section {
                    if let generatedAt = insightsStore.snapshot?.generatedAt {
                        Text("Last updated \(generatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.textSecondary)
                    }

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
                    }
                }
                .listRowBackground(PaydayColor.background)
            }

            ForEach(sections(for: facts)) { section in
                Section(section.title) {
                    Text(section.body)
                        .font(PaydayFont.bodyRegular)
                        .foregroundStyle(PaydayColor.textPrimary)
                        .padding(.vertical, 4)
                }
                .listRowBackground(PaydayColor.background)
            }

            if !isModelAvailable {
                Section {
                    Text("Analysis isn't configured right now. These are your exact numbers, just not narrated.")
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)
                }
                .listRowBackground(PaydayColor.background)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// The narrated sections when the cached narration still matches
    /// tonight's facts; the deterministic facts-only sections otherwise
    /// (covers both "not configured" and "refresh still pending").
    private func sections(for facts: InsightsFacts) -> [InsightSection] {
        if let snapshot = insightsStore.snapshot, snapshot.facts == facts {
            return snapshot.sections
        }
        return InsightsFactsCopy.sections(for: facts)
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

    private func refresh(facts: InsightsFacts) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let frequency = scheduleStore.schedule?.frequency ?? .biweekly
        do {
            let sections = try await InsightsService.narrate(
                facts: facts,
                scheduleFrequency: frequency,
                previousSections: insightsStore.snapshot?.sections
            )
            insightsStore.snapshot = InsightsSnapshot(sections: sections, generatedAt: .now, facts: facts)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
