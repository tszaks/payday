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
    /// Thrown when the financial tables are still populated after the erase.
    /// Deliberately a distinct error: "we could not delete your data" has to
    /// reach the person, because the alternative is telling them their
    /// earnings record is gone while it is still on the device.
    struct IncompleteErasure: Error {
        let remainingTipEntries: Int
        let remainingPaychecks: Int
    }

    /// Order matters. SwiftData rows go first so a widget timeline refreshed
    /// mid-erase can never read shifts whose owning schedule has already
    /// been torn out from under it.
    ///
    /// Throwing, and verified by readback. This used to swallow every error
    /// with `try?` and return silently, so a failed save left the complete
    /// financial history on disk while the caller reported a clean deletion —
    /// found by the 2026-09-14 security review.
    static func eraseLocalData(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        insightsStore: InsightsStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore
    ) throws {
        try context.delete(model: TipEntry.self)
        try context.delete(model: PaycheckRecord.self)
        try context.save()

        // A successful save is not proof of an empty store: the deletes and
        // the save can each succeed against a context whose rows were
        // reinserted by a concurrent writer, and SwiftData's batch delete has
        // its own failure modes. Ask the store what is actually left.
        let remainingTips = try context.fetchCount(FetchDescriptor<TipEntry>())
        let remainingPaychecks = try context.fetchCount(FetchDescriptor<PaycheckRecord>())
        guard remainingTips == 0, remainingPaychecks == 0 else {
            throw IncompleteErasure(
                remainingTipEntries: remainingTips,
                remainingPaychecks: remainingPaychecks
            )
        }

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

        // Identity-bound shared state. Left behind, the stale registration
        // made `canRegister` refuse the next Apple ID on this device with
        // accountMismatch — a lockout with no account left to mismatch.
        PaydayAuthorizationState.reset()

        // The widget reads the shared app-group store directly, so it has to
        // be told the store is empty or it keeps rendering the last total.
        PaydayWidgetRefresh.request()
    }
}
