import SwiftUI

/// Periods and Calendar are the same job — history — told in two time
/// systems: a list of pay periods, or a month grid. One tab, one
/// NavigationStack, a segmented control choosing which telling is on screen.
enum HistoryLens: String, CaseIterable {
    case periods, calendar

    static let storageKey = "historyLens"

    /// Lets anything outside HistoryView (the Dashboard "See all" jump, the
    /// -InitialTab/-OpenCurrentPeriodDetail QA hooks) force the lens open to
    /// a specific one — @AppStorage in HistoryView reads this same
    /// UserDefaults key, so a write here is picked up like any other
    /// AppStorage writer would be.
    func select() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

struct HistoryView: View {
    @AppStorage(HistoryLens.storageKey) private var lens: HistoryLens = .periods
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("Lens", selection: $lens) {
                    Text("Periods").tag(HistoryLens.periods)
                    Text("Calendar").tag(HistoryLens.calendar)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, PaydaySpacing.p16)
                .padding(.top, PaydaySpacing.p8)

                switch lens {
                case .periods:
                    PeriodsView(path: $path)
                case .calendar:
                    CalendarView()
                }
            }
            .background(PaydayColor.background)
        }
    }
}
