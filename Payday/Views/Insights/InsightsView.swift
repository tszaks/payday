import SwiftUI
import SwiftData

/// The one screen in the app that reaches the network. MainTabView also
/// triggers a silent auto-refresh roughly once a week (see its
/// autoAnalyzeIfDue) — this view's own "Analyze Again" is the manual path,
/// rate-limited below to protect the baked-in API key from being spammed.
/// The last result is cached in InsightsStore so it survives app relaunch.
struct InsightsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var now = Date.now

    /// Manual re-analysis is throttled independently of the weekly auto-run
    /// — this guards against someone tapping the button repeatedly, not
    /// against the scheduled refresh.
    private static let minimumManualInterval: TimeInterval = 60 * 60

    private var nextManualAnalysisAllowedAt: Date? {
        insightsStore.snapshot?.generatedAt.addingTimeInterval(Self.minimumManualInterval)
    }

    private var canAnalyzeManually: Bool {
        guard let nextAllowed = nextManualAnalysisAllowedAt else { return true }
        return now >= nextAllowed
    }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = insightsStore.snapshot {
                    // Calm over noisy: re-analyzing never evicts what's already
                    // on screen. Progress shows inline in the footer instead.
                    resultList(snapshot)
                } else if isLoading {
                    // Nothing to preserve on a first-ever analysis.
                    ProgressView("Analyzing your tips…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .onAppear { now = .now }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-RunInsightsAnalysis") {
                    Task { await analyze() }
                }
            }
            #endif
        }
    }

    private func resultList(_ snapshot: InsightsSnapshot) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Last updated \(snapshot.generatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .font(PaydayFont.caption)
                        .foregroundStyle(PaydayColor.textSecondary)
                    Text("Refreshes automatically about once a week — tap below for a fresh read anytime.")
                        .font(PaydayFont.caption2)
                        .foregroundStyle(PaydayColor.textSecondary)

                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Analyzing your tips…")
                                .font(PaydayFont.subheadline)
                                .foregroundStyle(PaydayColor.textSecondary)
                        }
                    } else {
                        Button("Analyze Again") {
                            Task { await analyze() }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.accentColor)
                        .disabled(!canAnalyzeManually)

                        if !canAnalyzeManually, let nextAllowed = nextManualAnalysisAllowedAt {
                            Text("You can analyze again at \(nextAllowed.formatted(date: .omitted, time: .shortened)).")
                                .font(PaydayFont.caption2)
                                .foregroundStyle(PaydayColor.textSecondary)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(PaydayFont.caption)
                                .foregroundStyle(PaydayColor.error)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(PaydayColor.background)

            ForEach(snapshot.sections) { section in
                Section(section.title) {
                    Text(section.body)
                        .font(PaydayFont.body)
                        .foregroundStyle(PaydayColor.textPrimary)
                        .padding(.vertical, 4)
                }
                .listRowBackground(PaydayColor.background)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(PaydayFont.iconXL)
                .foregroundStyle(PaydayColor.textSecondary)
            Text("See where and when you earn the most.")
                .font(PaydayFont.headline)
                .foregroundStyle(PaydayColor.textPrimary)
            Text("Sends your logged tips — dates, amounts, cash/credit type, double-shift flag, and any notes — to OpenAI for analysis. Nothing else leaves your phone.")
                .font(PaydayFont.caption)
                .foregroundStyle(PaydayColor.textSecondary)
                .multilineTextAlignment(.center)
            Text("Once you've got enough logged, this refreshes automatically about once a week.")
                .font(PaydayFont.caption2)
                .foregroundStyle(PaydayColor.textSecondary)
                .multilineTextAlignment(.center)
            if let errorMessage {
                Text(errorMessage)
                    .font(PaydayFont.caption)
                    .foregroundStyle(PaydayColor.error)
                    .multilineTextAlignment(.center)
            }
            Button("Analyze My Tips") {
                Task { await analyze() }
            }
            .buttonStyle(.glassProminent)
            .tint(.accentColor)
        }
        .padding(.top, 40)
    }

    /// The cooldown check has to live here, not just on the button's
    /// .disabled(), or any caller that skips the button (the debug launch
    /// flag did exactly this) can still hit the network on every launch.
    private func analyze() async {
        now = .now
        guard canAnalyzeManually else { return }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let snapshots = allEntries.map { TipEntrySnapshot(date: $0.date, amountCents: $0.amountCents, kind: $0.kind, note: $0.note, recordedAt: $0.recordedAt, isDouble: $0.isDouble) }
        let frequency = scheduleStore.schedule?.frequency ?? .biweekly
        do {
            let sections = try await InsightsService.analyze(entries: snapshots, scheduleFrequency: frequency)
            insightsStore.snapshot = InsightsSnapshot(sections: sections, generatedAt: .now)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
