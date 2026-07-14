import SwiftUI
import SwiftData
import TipKit
import UserNotifications

@main
struct PaydayApp: App {
    @State private var scheduleStore = PayScheduleStore()
    @State private var insightsStore = InsightsStore()
    @State private var preferencesStore = UserPreferencesStore()

    init() {
        try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(scheduleStore)
                .environment(insightsStore)
                .environment(preferencesStore)
                .preferredColorScheme(preferencesStore.appearance.colorScheme)
                .modelContainer(SharedModelContainer.shared)
                .task {
                    #if DEBUG
                    DebugSeeder.seedIfRequested(scheduleStore: scheduleStore, insightsStore: insightsStore)
                    #endif
                }
        }
    }
}
