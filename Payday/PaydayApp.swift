import SwiftUI
import SwiftData

@main
struct PaydayApp: App {
    @State private var scheduleStore = PayScheduleStore()
    @State private var insightsStore = InsightsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(scheduleStore)
                .environment(insightsStore)
                .modelContainer(for: [TipEntry.self, PaycheckRecord.self])
                .task {
                    #if DEBUG
                    DebugSeeder.seedIfRequested(scheduleStore: scheduleStore, insightsStore: insightsStore)
                    #endif
                }
        }
    }
}
