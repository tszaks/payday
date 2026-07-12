import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, calendar, periods, insights
    var id: String { rawValue }
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .dashboard

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
        }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-InitialTab"), args.count > index + 1,
               let tab = AppTab(rawValue: args[index + 1]) {
                selectedTab = tab
            }
        }
        #endif
    }
}
