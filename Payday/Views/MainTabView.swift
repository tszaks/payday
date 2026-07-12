import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, calendar, periods
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
        }
    }
}
