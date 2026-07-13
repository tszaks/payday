import SwiftUI
import SwiftData

/// The one screen in the app that reaches the network, and only when the
/// user explicitly taps the button below — never automatically.
struct InsightsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var sections: [InsightSection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Analyzing your tips…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sections.isEmpty {
                    ScrollView {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                } else {
                    List {
                        ForEach(sections) { section in
                            Section(section.title) {
                                Text(section.body)
                                    .padding(.vertical, 4)
                            }
                        }
                        Section {
                            Button("Analyze Again") {
                                Task { await analyze() }
                            }
                        }
                    }
                    .listStyle(.plain)
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
        let snapshots = allEntries.map { TipEntrySnapshot(date: $0.date, amountCents: $0.amountCents, note: $0.note) }
        let frequency = scheduleStore.schedule?.frequency ?? .biweekly
        do {
            sections = try await InsightsService.analyze(entries: snapshots, scheduleFrequency: frequency)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
