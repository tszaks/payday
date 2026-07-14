import SwiftUI

struct RootView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var lockController = AppLockController()

    var body: some View {
        Group {
            if scheduleStore.schedule != nil {
                MainTabView()
            } else {
                FirstRunSetupView()
            }
        }
        .fullScreenCover(isPresented: $lockController.isLocked) {
            LockGateView(lockController: lockController)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                lockController.armIfEnabled(preferencesStore)
            }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-DebugForceLock") {
                lockController.isLocked = true
            }
        }
        #endif
    }
}
