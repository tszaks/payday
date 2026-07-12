import SwiftUI

struct RootView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore

    var body: some View {
        if scheduleStore.schedule != nil {
            MainTabView()
        } else {
            FirstRunSetupView()
        }
    }
}
