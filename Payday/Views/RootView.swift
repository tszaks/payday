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

    /// The intro is a first-run experience, and "first run" has to mean more
    /// than an unset flag. Anyone who already has a pay schedule on this
    /// device is by definition not new — without that second condition, every
    /// existing installation would be handed a welcome screen on the update
    /// that introduces this flow.
    private var shouldShowIntro: Bool {
        guard !onboardingStore.hasFinishedIntro else { return false }
        guard scheduleStore.schedule == nil else { return false }
        #if DEBUG || targetEnvironment(simulator)
        // The one -Debug flag that WANTS the intro: it opens a named stage of
        // it (see PaydayOnboardingViewModel.applyDebugStageIfRequested).
        if ProcessInfo.processInfo.arguments.contains("-DebugOnboardingStage") { return true }
        // Screenshot and QA launches (-Seed*, -UITestOffline, -Debug*) all want
        // the real app, and the seeders themselves run inside PaydayCloudGate
        // — which now sits BEHIND this branch, so an intro here would stall
        // them on the welcome screen forever.
        if ProcessInfo.processInfo.arguments.contains(where: {
            $0.hasPrefix("-Seed") || $0.hasPrefix("-Debug") || $0 == "-UITestOffline"
        }) {
            return false
        }
        #endif
        return true
    }

    var body: some View {
        Group {
            if !hasEvaluatedInitialLock {
                PaydayColor.background.ignoresSafeArea()
            } else if lockController.isLocked {
                LockGateView(lockController: lockController)
            } else if shouldShowIntro {
                // Deliberately AHEAD of PaydayCloudGate: the gate's job is to
                // demand a Sign in with Apple, and demanding one before a
                // stranger has seen a single number is the worst possible
                // first screen. Show what the app does, then ask.
                OnboardingFlowView(viewModel: onboardingViewModel) { chosenFrequency in
                    onboardingStore.quizPayFrequency = chosenFrequency
                    onboardingStore.hasFinishedIntro = true
                    // Answers are only needed to reach this point; drop them
                    // so nothing leaks into a second run on the same device.
                    onboardingViewModel.reset()
                }
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
