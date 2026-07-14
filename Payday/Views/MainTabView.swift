import SwiftUI
import SwiftData

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, calendar, periods, insights, logTips
    var id: String { rawValue }
}

/// Lets any tab's content switch the selected tab (e.g. Dashboard's "days
/// left" tile jumping to Calendar) without MainTabView needing to know about
/// every screen that wants to do that.
@Observable
final class TabRouter {
    var selected: AppTab = .dashboard
}

struct MainTabView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(InsightsStore.self) private var insightsStore
    @Query(sort: \TipEntry.date, order: .reverse) private var allEntries: [TipEntry]

    @State private var tabRouter = TabRouter()
    @State private var previousTab: AppTab = .dashboard
    @State private var isRestoringTabAfterLog = false
    @State private var logTarget: TipEntrySheetTarget?

    /// iOS has no way to guarantee code runs at an exact wall-clock time
    /// without a server to push it — there's no true "every Monday at 9am"
    /// here. This is the honest local approximation: whenever the app is
    /// opened and it's been a week or more since the last analysis, refresh
    /// it quietly in the background.
    private static let autoRefreshInterval: TimeInterval = 7 * 24 * 60 * 60

    var body: some View {
        TabView(selection: $tabRouter.selected) {
            Tab("Dashboard", systemImage: "house.fill", value: .dashboard) {
                DashboardView()
            }
            Tab("Calendar", systemImage: "calendar", value: .calendar) {
                CalendarView()
            }
            Tab("Periods", systemImage: "banknote.fill", value: .periods) {
                PeriodsView()
            }
            Tab("Insights", systemImage: "chart.line.uptrend.xyaxis", value: .insights) {
                InsightsView()
            }

            // role: .search is what gives this its own circular Liquid Glass
            // button beside the main pill instead of a sixth item inside it —
            // the same trick Vero uses for its chat tab. Never actually
            // navigated to: selecting it opens the sheet and snaps straight
            // back to whichever tab was showing.
            Tab("Log Tips", systemImage: "plus", value: .logTips, role: .search) {
                Color.clear
            }
        }
        .environment(tabRouter)
        .onChange(of: tabRouter.selected) { oldTab, newTab in
            handleTabSelection(from: oldTab, to: newTab)
        }
        // Shell-level so logging works from any tab; each screen keeps its own
        // sheet only for editing an existing entry.
        .sheet(item: $logTarget) { target in
            LogTipSheet(target: target)
        }
        .task { await autoAnalyzeIfDue() }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-InitialTab"), args.count > index + 1,
               let tab = AppTab(rawValue: args[index + 1]) {
                tabRouter.selected = tab
            }
            if args.contains("-OpenLogSheet") {
                logTarget = .new(defaultDate: .now)
            }
        }
        #endif
    }

    private func handleTabSelection(from oldTab: AppTab, to newTab: AppTab) {
        guard oldTab != newTab else { return }

        if isRestoringTabAfterLog {
            isRestoringTabAfterLog = false
            return
        }

        if newTab == .logTips {
            logTarget = .new(defaultDate: .now)
            isRestoringTabAfterLog = true
            DispatchQueue.main.async {
                tabRouter.selected = previousTab
            }
            return
        }

        previousTab = newTab
    }

    /// Silent by design: this is a background refresh, not a user action,
    /// so a failure (no network, not enough data yet) just means we try
    /// again next time the app opens rather than surfacing an error.
    private func autoAnalyzeIfDue() async {
        let isStale = insightsStore.snapshot.map {
            Date.now.timeIntervalSince($0.generatedAt) >= Self.autoRefreshInterval
        } ?? true
        guard isStale else { return }

        let snapshots = allEntries.map {
            TipEntrySnapshot(date: $0.date, amountCents: $0.amountCents, kind: $0.kind, note: $0.note, recordedAt: $0.recordedAt, isDouble: $0.isDouble)
        }
        let frequency = scheduleStore.schedule?.frequency ?? .biweekly
        guard let sections = try? await InsightsService.analyze(entries: snapshots, scheduleFrequency: frequency) else { return }
        insightsStore.snapshot = InsightsSnapshot(sections: sections, generatedAt: .now)
    }
}
