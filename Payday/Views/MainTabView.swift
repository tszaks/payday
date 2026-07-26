import SwiftUI
import SwiftData

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, history, insights, logTips
    var id: String { rawValue }
}

/// Lets any tab's content switch the selected tab (e.g. Dashboard's "days
/// left" tile jumping to History) without MainTabView needing to know about
/// every screen that wants to do that.
@Observable
final class TabRouter {
    var selected: AppTab = .dashboard
    /// Set alongside `selected = .history` (and the periods lens) by
    /// anything that wants to land inside the CURRENT period's detail, not
    /// just the periods list — HistoryView/PeriodsView clears it once it's
    /// consumed the request. A plain enum case rather than a full deep-link
    /// target because periods is the only screen anything currently jumps
    /// this deep into.
    var pendingCurrentPeriodDetail = false
}

struct MainTabView: View {
    #if DEBUG
    @Environment(\.modelContext) private var modelContext
    #endif
    @Environment(\.scenePhase) private var scenePhase
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
            Tab("History", systemImage: "clock.arrow.circlepath", value: .history) {
                HistoryView()
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
        .onChange(of: deepLink.pendingDashboardSelection) { _, shouldSelect in
            guard shouldSelect else { return }
            tabRouter.selected = .dashboard
            deepLink.pendingDashboardSelection = false
        }
        // A shift ended from Control Center, Siri, the Live Activity's own
        // End button, or the Home Screen quick action all happen outside
        // the app — popPendingEnd picks up the exact punches the next time
        // this view is on screen, whether that's a cold launch or a return
        // to the foreground.
        .onAppear { presentPendingShiftEndIfNeeded() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            presentPendingShiftEndIfNeeded()
        }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            // "periods"/"calendar" are legacy tab names from before the
            // History merge — mapped to the merged tab plus the matching
            // lens so old QA scripts keep working unmodified.
            if let index = args.firstIndex(of: "-InitialTab"), args.count > index + 1 {
                switch args[index + 1] {
                case "periods":
                    HistoryLens.periods.select()
                    tabRouter.selected = .history
                case "calendar":
                    HistoryLens.calendar.select()
                    tabRouter.selected = .history
                case let raw:
                    if let tab = AppTab(rawValue: raw) {
                        tabRouter.selected = tab
                    }
                }
            }
            if args.contains("-OpenLogSheet") {
                deepLink.pendingLogTarget = .new(defaultDate: .now)
            }
            // Screenshot/QA hook only: land straight inside the current
            // period's detail (the same jump Dashboard's "See all" makes)
            // so it can be captured without tapping through the Periods list.
            if args.contains("-OpenCurrentPeriodDetail") {
                tabRouter.pendingCurrentPeriodDetail = true
                HistoryLens.periods.select()
                tabRouter.selected = .history
            }
            // Screenshot/QA hook only: open the edit sheet directly for the
            // most recent entry of a given kind, so a cash+credit night's
            // shared shift details can be verified from both tabs without
            // needing UI automation to tap into it. Named distinctly from
            // DashboardView's own "-OpenEditSheet" (no kind arg) hook below
            // — the two used to share a flag name and could both fire off
            // the same launch args, each presenting its own sheet and
            // tripping a "already presenting" SwiftUI/UIKit conflict.
            if let index = args.firstIndex(of: "-OpenEditSheetKind"), args.count > index + 1,
               let kind = TipKind(rawValue: args[index + 1]) {
                let descriptor = FetchDescriptor<TipEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
                if let entry = (try? modelContext.fetch(descriptor))?.first(where: { $0.kind == kind }) {
                    deepLink.pendingLogTarget = .edit(entry)
                }
            }
            // Screenshot/QA hook only: starts a session 47 minutes ago and
            // requests its Live Activity, so the active Dashboard row and
            // the Dynamic Island can be captured without tapping Start.
            if args.contains("-StartShiftSession") {
                ShiftSessionManager.start(at: .now.addingTimeInterval(-47 * 60))
            }
        }
        #endif
    }

    private func presentPendingShiftEndIfNeeded() {
        guard let pending = ShiftSessionStore.popPendingEnd() else { return }
        deepLink.pendingLogTarget = .new(defaultDate: pending.start, clockIn: pending.start, clockOut: pending.end)
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
