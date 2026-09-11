import Foundation
import SwiftData

/// Wipes everything Payday keeps on this device.
///
/// Separate from DebugSeeder.clearAll, which looks similar but is compiled
/// out of release builds and does not touch preferences or an in-progress
/// shift. This runs in production, on the account-deletion path, so it has
/// to leave nothing behind.
///
/// Deleting an account destroys a person's entire earnings record with no
/// recovery: the server rows are gone by cascade and the local copy is gone
/// by this. That is the behavior Payday chose deliberately — the privacy
/// story is unambiguous and there is no half-deleted state to explain — but
/// it is also why the UI that reaches here asks for typed confirmation
/// rather than a tap.
@MainActor
enum PaydayAccountEraser {
    /// Order matters. SwiftData rows go first so a widget timeline refreshed
    /// mid-erase can never read shifts whose owning schedule has already
    /// been torn out from under it.
    static func eraseLocalData(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        insightsStore: InsightsStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore
    ) {
        try? context.delete(model: TipEntry.self)
        try? context.delete(model: PaycheckRecord.self)
        try? context.save()

        // An abandoned shift would otherwise resurface on next launch as a
        // timer running against an account that no longer exists.
        _ = ShiftSessionStore.endActive(stash: false)
        _ = ShiftSessionStore.popPendingEnd()

        scheduleStore.schedule = nil
        insightsStore.snapshot = nil
        moveLedgerStore.reset()

        // Every one of these is personal: the name is from Sign in with
        // Apple, and the wage is the person's pay rate.
        preferencesStore.firstName = nil
        preferencesStore.baseHourlyWageCents = nil
        preferencesStore.isFaceIDLockEnabled = false
        preferencesStore.isSmartNudgeEnabled = true
        preferencesStore.isPaydayReminderEnabled = true
        preferencesStore.appearance = .system

        // The widget reads the shared app-group store directly, so it has to
        // be told the store is empty or it keeps rendering the last total.
        PaydayWidgetRefresh.request()
    }
}
