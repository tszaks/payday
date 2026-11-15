import Foundation
import SwiftData
import UserNotifications

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
        let remainingShifts: Int
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
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore
    ) throws {
        try context.delete(model: TipEntry.self)
        try context.delete(model: PaycheckRecord.self)
        // ShiftRecord is the third financial table. It is a mirror of
        // public.shifts rather than a second copy of the tips, but it carries
        // the same earnings in the same detail, so leaving it behind would
        // leave a complete shift history on a device whose owner was told
        // their account was deleted.
        try context.delete(model: ShiftRecord.self)
        try context.save()
        try removeRetiredPayStubLedger()

        // A successful save is not proof of an empty store: the deletes and
        // the save can each succeed against a context whose rows were
        // reinserted by a concurrent writer, and SwiftData's batch delete has
        // its own failure modes. Ask the store what is actually left.
        let remainingTips = try context.fetchCount(FetchDescriptor<TipEntry>())
        let remainingPaychecks = try context.fetchCount(FetchDescriptor<PaycheckRecord>())
        let remainingShifts = try context.fetchCount(FetchDescriptor<ShiftRecord>())
        guard remainingTips == 0, remainingPaychecks == 0, remainingShifts == 0 else {
            throw IncompleteErasure(
                remainingTipEntries: remainingTips,
                remainingPaychecks: remainingPaychecks,
                remainingShifts: remainingShifts
            )
        }

        // An abandoned shift would otherwise resurface on next launch as a
        // timer running against an account that no longer exists.
        _ = ShiftSessionStore.endActive(stash: false)
        _ = ShiftSessionStore.popPendingEnd()

        scheduleStore.schedule = nil
        removeRetiredInsightsNarration()
        moveLedgerStore.reset()
        policyStore.reset()

        // Every one of these is personal: the name is from Sign in with
        // Apple, and the wage is the person's pay rate.
        preferencesStore.firstName = nil
        preferencesStore.baseHourlyWageCents = nil
        preferencesStore.isFaceIDLockEnabled = false
        preferencesStore.isSmartNudgeEnabled = true
        preferencesStore.isPaydayReminderEnabled = true
        // Where card tips are paid is the deleted account's payroll fact.
        // Left behind, the next account on this phone would inherit it, and
        // settings sync would upload it as that account's own choice.
        preferencesStore.isCardTipsPaidAtClose = false
        preferencesStore.appearance = .system

        // Identity-bound shared state: the explicit sign-out and app-lock
        // flags. Left behind, the next account on this device would inherit
        // the deleted account's sign-out and lock policy. The registration
        // itself is cleared by PaydaySyncState.forget in the caller.
        PaydayAuthorizationState.reset()

        // A pending alert would still fire for the deleted account, and a
        // delivered one keeps its figure in Notification Center. The payday
        // identifiers carry each job's id, so they are found by prefix, the
        // way `PaydayPushScheduler` clears its own.
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [SmartNudgeScheduler.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [SmartNudgeScheduler.notificationIdentifier])
        Task {
            let pending = await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter(PaydayPushScheduler.isPaydayIdentifier)
            center.removePendingNotificationRequests(withIdentifiers: pending)
            let delivered = await center.deliveredNotifications()
                .map(\.request.identifier)
                .filter(PaydayPushScheduler.isPaydayIdentifier)
            center.removeDeliveredNotifications(withIdentifiers: delivered)
        }

        // Nothing to clear here for the shift cache: every durable fact about
        // it lives in the sync checkpoint, and this function's one caller
        // already drops that whole key with PaydaySyncState.forget(userID:).
        // A second per-account store would
        // need its own eraser line and would be missed exactly once.

        // The widget reads the shared app-group store directly, so it has to
        // be told the store is empty or it keeps rendering the last total.
        PaydayWidgetRefresh.request()
    }

    /// TestFlight builds of 1.0.5 could import pay stubs and kept a map of
    /// them, with hours and deduction lines found nowhere else, in this file.
    /// That feature is gone, but a device that used it may still hold the
    /// file, so account deletion still removes it.
    static let retiredPayStubLedgerURL = URL.applicationSupportDirectory.appending(path: "PayrollImportLedger.json")

    /// Throws when the file is still there afterwards. No file is success.
    static func removeRetiredPayStubLedger(at url: URL = retiredPayStubLedgerURL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// Builds that rendered an Insights narration cached the last one, prose
    /// quoting the person's earnings, under this key. Nothing writes it any
    /// more, but a device that ran one of those builds may still hold it, so
    /// every launch and every account deletion removes it.
    static let retiredInsightsNarrationKey = "com.szakacsmedia.payday.insightsSnapshot"

    static func removeRetiredInsightsNarration(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: retiredInsightsNarrationKey)
    }
}
