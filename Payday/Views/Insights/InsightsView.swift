import SwiftUI
import SwiftData

/// The one screen in the app that reaches the network, and only when the
/// user explicitly taps the button below — never automatically. The last
/// result is cached in InsightsStore so it survives app relaunch instead
/// of re-running on every open.
struct InsightsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var isLoading = false
    @State private var errorMessage: String?

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
            ForEach(snapshot.sections) { section in
                Section(section.title) {
                    Text(section.body)
                        .font(PaydayFont.body)
                        .foregroundStyle(PaydayColor.textPrimary)
                        .padding(.vertical, 4)
                }
                .listRowBackground(PaydayColor.background)
            }
            Section {
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
                    if let errorMessage {
                        Text(errorMessage)
                            .font(PaydayFont.caption)
                            .foregroundStyle(PaydayColor.error)
                    }
                }
            } footer: {
                Text("Last updated \(snapshot.generatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
            }
            .listRowBackground(PaydayColor.background)
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
            Text("Sends your logged tips — dates, amounts, cash/credit type, and any notes — to OpenAI for analysis. Nothing else leaves your phone.")
                .font(PaydayFont.caption)
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

    private func analyze() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let snapshots = allEntries.map { TipEntrySnapshot(date: $0.date, amountCents: $0.amountCents, kind: $0.kind, note: $0.note, recordedAt: $0.recordedAt) }
        let frequency = scheduleStore.schedule?.frequency ?? .biweekly
        do {
            let sections = try await InsightsService.analyze(entries: snapshots, scheduleFrequency: frequency)
            insightsStore.snapshot = InsightsSnapshot(sections: sections, generatedAt: .now)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
