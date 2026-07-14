import SwiftUI
import SwiftData

/// Insights runs entirely on-device: the stats engine computes the facts,
/// and (when supported) Foundation Models narrates them — no network call,
/// no API key, nothing ever leaves the phone. Regeneration is driven by
/// .task(id:) re-firing whenever the underlying facts actually change, not
/// a manual rate limit or a time-based schedule — on-device generation is
/// cheap enough that "always current" is just the default.
struct InsightsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var isLoading = false
    @State private var errorMessage: String?

    private var facts: InsightsFacts? {
        StatsEngine(records: allEntries.map(TipRecord.init)).insightsFacts()
    }

    private var isModelAvailable: Bool {
        if case .available = InsightsService.availability { return true }
        return false
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
                guard isModelAvailable, let facts, facts != insightsStore.snapshot?.facts else { return }
                await analyze(facts: facts)
            }
        }
    }

    private func resultList(_ facts: InsightsFacts) -> some View {
        List {
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
                            Text("Analyzing your tips…")
                                .font(PaydayFont.subheadline)
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                    } else {
                        Button("Analyze Again") {
                            Task { await analyze(facts: facts) }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.accentColor)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(PaydayFont.caption)
                                .foregroundStyle(PaydayColor.error)
                        }
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
                    Text("On-device analysis needs Apple Intelligence. These are your exact numbers, just not narrated.")
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
    /// (covers both "unsupported hardware" and "narration still pending").
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
            Text("Log \(StatsEngine.minimumShiftsForInsights) shifts to unlock this. Everything is computed right on your phone — nothing ever leaves it.")
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    private func analyze(facts: InsightsFacts) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let frequency = scheduleStore.schedule?.frequency ?? .biweekly
        do {
            let sections = try await InsightsService.narrate(facts: facts, scheduleFrequency: frequency)
            insightsStore.snapshot = InsightsSnapshot(sections: sections, generatedAt: .now, facts: facts)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
