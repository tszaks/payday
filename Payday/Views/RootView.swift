import Combine
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
    /// The other representation. SmartNudgeScheduler picks between this and
    /// `allEntries` on `shiftsAreAuthoritative`; it must never read both, or a
    /// converted shift counts twice.
    @Query private var shiftRecords: [ShiftRecord]

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
                SmartNudgeScheduler.reschedule(preferencesStore: preferencesStore, allEntries: allEntries, shiftRecords: shiftRecords)
                PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: scheduleStore.schedule, allEntries: allEntries, paycheckRecords: paycheckRecords)
            default:
                break
            }
        }
        // The payday notification's figure became POLICY-dependent in PR 5
        // group 2.12: it used to be `PredictedPaycheck.tipsLineCents`
        // (wage-EXCLUSIVE, so no rate edit could move it) and it is now
        // `expectedPaycheckGross`, which includes wages. Every one of the
        // other reschedule triggers is shift-shaped, so before this the
        // pending request kept its pre-edit figure while the Dashboard card
        // the tap lands on recomputed from `policyStore.policies` on every
        // render — MEASURED at $150.00 on the lock screen against $310.00 on
        // the card, over the same one shift, after nothing but setting an
        // hourly rate in Settings (`PaydayPushSchedulerTests`,
        // `policyEditMovesTheDecision`).
        //
        // Here rather than in `PayrollSettingsSection` next to the three
        // `policyStore.apply…` calls, for the reason rule 3 of the adapter
        // contract gives about hand-maintained dependency lists: this fires
        // for every policy write there is, including `confirmRateHistory`
        // (which moves the body's caption, not its cents), the launch
        // migration, and a policy arriving from a sync download on a
        // background thread — none of which are in Settings.
        //
        // `PolicyStore.didChange` alone and NOT `LegacySnapshotRevision`'s
        // merged publisher, deliberately: that set includes
        // `ModelContext.didSave`, and `@Query allEntries` has not
        // necessarily caught up when a save posts. That is exactly why
        // `LogTipSheet` and `BackfillSheet` hand `reschedule` `allEntries +
        // newEntries` by hand. Subscribing to the save here would race those
        // two call sites and could overwrite a correct decision with one
        // computed from the pre-save entry list. A policy edit changes no
        // shift, so `allEntries` is already current for this trigger.
        .onReceive(NotificationCenter.default.publisher(for: PolicyStore.didChange)) { _ in
            PaydayPushScheduler.reschedule(preferencesStore: preferencesStore, schedule: scheduleStore.schedule, allEntries: allEntries, paycheckRecords: paycheckRecords)
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
