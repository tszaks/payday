import SwiftUI
import SwiftData

/// The one screen in the app that reaches the network, and only when the
/// user explicitly taps the button below — never automatically.
struct InsightsView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var result: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if isLoading {
                        ProgressView("Analyzing your tips…")
                            .padding(.top, 60)
                    } else if let result {
                        resultView(result)
                    } else {
                        emptyState
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
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

    private func resultView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let attributed = try? AttributedString(markdown: text) {
                Text(attributed)
            } else {
                Text(text)
            }
            Button("Analyze Again") {
                Task { await analyze() }
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func analyze() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let snapshots = allEntries.map { TipEntrySnapshot(date: $0.date, amountCents: $0.amountCents, note: $0.note) }
        let frequency = scheduleStore.schedule?.frequency ?? .biweekly
        do {
            result = try await InsightsService.analyze(entries: snapshots, scheduleFrequency: frequency)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
