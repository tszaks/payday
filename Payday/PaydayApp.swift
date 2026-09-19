import SwiftUI
import SwiftData
import TipKit
import UserNotifications

@main
struct PaydayApp: App {
    // Home Screen long-press quick actions need windowScene(_:performActionFor:),
    // which only a UIKit scene delegate receives — see AppDelegate.swift.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    // scheduleStore and policyStore are assigned in `init` instead of
    // inline, because `earningsStore` reads both and a property's inline
    // default cannot be handed to another property's default.
    @State private var scheduleStore: PayScheduleStore
    @State private var insightsStore = InsightsStore()
    @State private var preferencesStore = UserPreferencesStore()
    @State private var moveLedgerStore = MoveLedgerStore()
    @State private var policyStore: PolicyStore
    @State private var onboardingStore = OnboardingStateStore()
    /// The one earnings snapshot for this process. Built here and handed to
    /// every screen through the environment so two surfaces cannot disagree
    /// about the same fact (Design 2). PR 5 migrates the screens onto it.
    @State private var earningsStore: EarningsStore

    init() {
        // First, before anything that can fail. Opening the shared SwiftData
        // container is the one startup failure this app has already shipped a
        // recovery screen for (SharedStoreRecoveryView below), and a reporter
        // started after it would never hear about it. No-ops entirely when no
        // SENTRY_DSN is in the bundle, which is every Debug and test build.
        PaydayCrashReporting.start()

        // Before any view can reach the context. See the function's comment
        // for why the flag lives here and not inside `shared`.
        SharedModelContainer.disableMainContextAutosave()

        // The stores this one reads must exist before it does, so they are
        // built here rather than relying on property initialization order.
        let policyStore = PolicyStore()
        let scheduleStore = PayScheduleStore()
        _policyStore = State(initialValue: policyStore)
        _scheduleStore = State(initialValue: scheduleStore)
        _earningsStore = State(initialValue: EarningsStore(
            source: ModelContextEarningsInputSource(
                container: SharedModelContainer.shared,
                policyStore: policyStore,
                scheduleStore: scheduleStore
            ),
            // S7's fact, finally wired. `EarningsStore.init` documents that
            // "S7 passes its single shiftsAreAuthoritative in here", and S7
            // shipped without doing it, so the parameter kept its pre-S7
            // default of `false` and `.shiftCacheWiped` was unreachable in
            // production. Post-conversion with a purged shift cache the
            // engine then computed from ZERO shifts while `legacyTipEntryCount`
            // knew the account still had data, and every surface rendered $0.
            shiftsAreAuthoritative: { PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount },
            // WIRED HERE, not left on its default, because the comment above
            // is a record of what a defaulted parameter costs: S7's fact
            // shipped unwired and `.shiftCacheWiped` was unreachable in
            // production for three slices. `onPublish` is the same shape --
            // a hook whose default is "do nothing" -- so it gets connected
            // in the same commit that introduces it.
            //
            // Self-gating before the migration lands: `syncedDatasetRevision`
            // is only set when `dataset_revisions` can be read, and that
            // table does not exist in production yet, so the uploader
            // returns `.skippedNoCleanSync` and spends no round trip. It
            // starts working when the migration is applied, with no second
            // change here.
            onPublish: { snapshot in
                SnapshotPublisher.shared.publish(snapshot)
            }
        ))
        try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if SharedModelContainer.openingFailed {
                    SharedStoreRecoveryView()
                } else {
                    RootView()
                }
            }
                .environment(scheduleStore)
                .environment(insightsStore)
                .environment(preferencesStore)
                .environment(moveLedgerStore)
                .environment(policyStore)
                .environment(onboardingStore)
                .environment(earningsStore)
                .preferredColorScheme(preferencesStore.appearance.colorScheme)
                .modelContainer(SharedModelContainer.shared)
                .task { earningsStore.requestRebuild(reason: .initial) }
                // Scene `.active` is the one Design 2 trigger the store
                // cannot observe itself: `UIApplication` is unavailable to
                // an app extension, and EarningsStore compiles into the
                // widget too. Another process (an App Intent, a Control)
                // may have written shifts while this one was backgrounded.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        earningsStore.requestRebuild(reason: .sceneActive)
                    }
                }
                // Lock Screen / StandBy accessory widgets can't host an
                // interactive button (accessory families are rendered by the
                // system, not the widget's own view) — widgetURL is the only
                // way a tap on one of those can reach the app. This is the
                // other half: payday://log jumps straight to the log sheet,
                // the same destination OpenLogSheetIntent gives the
                // home-screen widget's "+".
                .onOpenURL { url in
                    guard url.scheme == "payday" else { return }
                    switch url.host {
                    case "log":
                        DeepLinkCoordinator.shared.pendingLogTarget = .new(defaultDate: .now)
                    case "shift":
                        // The Live Activity/lock screen tap — always opens
                        // Dashboard, never a sheet; ending is only ever the
                        // explicit End button/control, never this tap.
                        DeepLinkCoordinator.shared.pendingDashboardSelection = true
                    default:
                        break
                    }
                }
        }
    }
}

private struct SharedStoreRecoveryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Payday Couldn't Open", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Your synced data remains safe. Close and reopen Payday, then try again.")
        }
        .padding()
        .background(PaydayColor.background)
    }
}
