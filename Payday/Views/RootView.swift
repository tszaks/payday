import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(PayScheduleStore.self) private var scheduleStore
    @Environment(UserPreferencesStore.self) private var preferencesStore
    @Environment(OnboardingStateStore.self) private var onboardingStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var lockController = AppLockController()
    @State private var hasEvaluatedInitialLock = false
    @State private var onboardingViewModel = PaydayOnboardingViewModel()
    @Query private var allEntries: [TipEntry]
    @Query private var paycheckRecords: [PaycheckRecord]

    var body: some View {
        Group {
            if !hasEvaluatedInitialLock {
                PaydayColor.background.ignoresSafeArea()
            } else {
                // Two questions, in this order, and nothing else:
                //
                //   1. Signed in?  No  -> the welcome flow, ending at sign-in.
                //   2. Unlocked?   No  -> the lock screen.
                //   Otherwise -> the app (or the pay-schedule step, once).
                //
                // The lock check used to sit OUT here, ahead of the gate, which
                // meant a signed-out device with the lock enabled asked for
                // Face ID and then showed a welcome screen — authentication to
                // reach a marketing page. It is inside the signed-in branch
                // now, because that is the only place there is anything to
                // protect: the welcome flow shows no earnings, and reaching
                // real data from it still requires the account holder's Apple
                // ID, which is a stronger gate than the local one.
                PaydayCloudGate(onboardingViewModel: onboardingViewModel) {
                    if lockController.isLocked {
                        LockGateView(lockController: lockController)
                    } else if scheduleStore.schedule != nil {
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
