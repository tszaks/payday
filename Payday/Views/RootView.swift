import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var lockController = AppLockController()
    @State private var hasEvaluatedInitialLock = false
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    var body: some View {
        Group {
            if !hasEvaluatedInitialLock {
                PaydayColor.background.ignoresSafeArea()
            } else if lockController.isLocked {
                LockGateView(lockController: lockController)
            } else {
                PaydayCloudGate {
                    if scheduleStore.schedule != nil {
                        MainTabView()
                    } else {
                        FirstRunSetupView()
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                lockController.armIfEnabled(preferencesStore)
            case .active:
                SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries)
                PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: scheduleStore.schedule, allEntries: allEntries, paycheckRecords: paycheckRecords)
            default:
                break
            }
        }
        .task {
            // Backgrounding an already-running app arms the lock via the
            // scenePhase handler above, but a fully-terminated app (swiped
            // away in the App Switcher, not just suspended) starts a brand
            // new process on relaunch with no memory of that — nothing had
            // ever checked the preference at launch time before, so a cold
            // launch always opened straight to unlocked content regardless
            // of the setting.
            lockController.armIfEnabled(preferencesStore)
            hasEvaluatedInitialLock = true
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
