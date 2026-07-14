import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, calendar, periods, insights
    var id: String { rawValue }
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .dashboard
    @State private var logTarget: TipEntrySheetTarget?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
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

            logButton
                .padding(.trailing, 20)
                .padding(.bottom, 92) // float above the tab bar pill
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

    private var logButton: some View {
        Button {
            logTarget = .new(defaultDate: .now)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
        .accessibilityLabel("Log tips")
    }
}
