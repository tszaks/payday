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
                if isLoading {
                    ProgressView("Analyzing your tips…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let snapshot = insightsStore.snapshot {
                    resultList(snapshot)
                } else {
                    ScrollView {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
            }
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
                        .padding(.vertical, 4)
                }
            }
            Section {
                Button("Analyze Again") {
                    Task { await analyze() }
                }
            } footer: {
                Text("Last updated \(snapshot.generatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("See where and when you earn the most.")
                .font(.headline)
            Text("Sends your logged tip dates and amounts to OpenAI for analysis. Nothing else leaves your phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.red)
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
        let snapshots = allEntries.map { TipEntrySnapshot(date: $0.date, amountCents: $0.amountCents, kind: $0.kind, note: $0.note) }
        let frequency = scheduleStore.schedule?.frequency ?? .biweekly
        do {
            let sections = try await InsightsService.analyze(entries: snapshots, scheduleFrequency: frequency)
            insightsStore.snapshot = InsightsSnapshot(sections: sections, generatedAt: .now)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
