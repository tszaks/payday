import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, calendar, periods, insights, logTips
    var id: String { rawValue }
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .dashboard
    @State private var previousTab: AppTab = .dashboard
    @State private var isRestoringTabAfterLog = false
    @State private var logTarget: TipEntrySheetTarget?

    var body: some View {
        TabView(selection: $selectedTab) {
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
        .onChange(of: selectedTab) { oldTab, newTab in
            handleTabSelection(from: oldTab, to: newTab)
        }
        // Shell-level so logging works from any tab; each screen keeps its own
        // sheet only for editing an existing entry.
        .sheet(item: $logTarget) { target in
            LogTipSheet(target: target)
        }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-InitialTab"), args.count > index + 1,
               let tab = AppTab(rawValue: args[index + 1]) {
                selectedTab = tab
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
                selectedTab = previousTab
            }
            return
        }

        previousTab = newTab
    }
}
