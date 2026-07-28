import SwiftUI
import SwiftData
import TipKit
import UserNotifications

@main
struct PaydayApp: App {
    // Home Screen long-press quick actions need windowScene(_:performActionFor:),
    // which only a UIKit scene delegate receives — see AppDelegate.swift.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var scheduleStore = PayScheduleStore()
    @State private var insightsStore = InsightsStore()
    @State private var preferencesStore = UserPreferencesStore()
    @State private var moveLedgerStore = MoveLedgerStore()

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
                .environment(moveLedgerStore)
                .preferredColorScheme(preferencesStore.appearance.colorScheme)
                .modelContainer(SharedModelContainer.shared)
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
                .task {
                    #if DEBUG
                    DebugSeeder.seedIfRequested(scheduleStore: scheduleStore, insightsStore: insightsStore, moveLedgerStore: moveLedgerStore, preferencesStore: preferencesStore)
                    #endif
                    // Backfill shiftID on any legacy rows (cheap nil-predicate
                    // fetch; no-ops once every row is migrated). Runs after the
                    // debug seeder so seeded rows already carry their own ids.
                    MigrationRunner.backfillShiftIDs(in: SharedModelContainer.shared.mainContext)
                    // Recompute punch-backed hoursWorked with the exact
                    // (never quarter-rounded) rule — heals shifts stored
                    // before that rule existed. Idempotent, so this is safe
                    // to run every launch alongside the backfill above.
                    MigrationRunner.recomputeExactHours(in: SharedModelContainer.shared.mainContext)
                }
        }
    }
}
