import SwiftUI

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
    @State private var tabRouter = TabRouter()
    @State private var previousTab: AppTab = .dashboard
    @State private var isRestoringTabAfterLog = false
    // Single source of truth for "what log sheet should be showing" —
    // shared with App Intents (Siri, Shortcuts, the widget's "+" button),
    // none of which can reach a plain @State here directly.
    @Bindable private var deepLink = DeepLinkCoordinator.shared

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
            //
            // Tinted green unlike Vero's own (neutral) search tab: Vero's
            // opens a secondary feature (chat); this one IS the app's core
            // action; a neutral glass circle undersells the one button a
            // tired, one-handed, post-shift user needs to find instantly.
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
        .sheet(item: $deepLink.pendingLogTarget) { target in
            LogTipSheet(target: target)
        }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-InitialTab"), args.count > index + 1,
               let tab = AppTab(rawValue: args[index + 1]) {
                tabRouter.selected = tab
            }
            if args.contains("-OpenLogSheet") {
                deepLink.pendingLogTarget = .new(defaultDate: .now)
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
            deepLink.pendingLogTarget = .new(defaultDate: .now)
            isRestoringTabAfterLog = true
            DispatchQueue.main.async {
                tabRouter.selected = previousTab
            }
            return
        }

        previousTab = newTab
    }
}
