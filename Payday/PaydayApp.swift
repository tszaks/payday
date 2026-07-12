import SwiftUI
import SwiftData

@main
struct PaydayApp: App {
    @State private var scheduleStore = PayScheduleStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(scheduleStore)
                .modelContainer(for: [TipEntry.self, PaycheckRecord.self])
                .task {
                    #if DEBUG
                    DebugSeeder.seedIfRequested(scheduleStore: scheduleStore)
                    #endif
                }
        }
    }
}
