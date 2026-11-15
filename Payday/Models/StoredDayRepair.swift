import Foundation
import OSLog
import SwiftData

/// Brings every stored day in the store to `StoredDay`'s rule.
///
/// Rows written before that rule hold midnight on the phone's calendar, and
/// a change to the policies can leave a row in a zone it is no longer read
/// in. Each row gets `StoredDay.repaired`, which keeps a row that already
/// follows the rule, so a run that finds nothing to do writes nothing.
///
/// A re-anchored row names the same civil day the server holds, so this is
/// not an edit: it never touches `modifiedAt`, and the upload fingerprint
/// digests `PaydayRemoteDate.stableDay`, which names the same day for both
/// instants when both zones lie in (UTC-10:30, UTC+13:30]. A row moving to or
/// from a zone outside that window (UTC-11, UTC+14) changes its fingerprint,
/// and then uploads once with the content the server already holds.
///
/// Three callers: launch, before any reader exists (`PaydayApp`); every
/// policy change (`RootView`, on `PolicyStore.didChange`); and the sync, once
/// a download has applied its rows and settings. Each pass re-anchors from
/// the calendars the last pass left the rows under, which the policy store
/// keeps (`PolicyStore.calendarsStoredDaysFollow`).
@MainActor
enum StoredDayRepair {
    private static let logger = Logger(subsystem: "com.szakacsmedia.payday", category: "StoredDayRepair")

    /// Re-anchors every stored day that breaks the rule, without saving.
    /// Returns whether any row moved.
    ///
    /// - Parameter previous: the calendars the rows were stored under, when
    ///   known. They name each day exactly; without them a row not on its
    ///   own zone's midnight is read by `StoredDay.repaired`'s fallbacks.
    @discardableResult
    static func reanchor(
        in context: ModelContext,
        from previous: [PayrollCalendarPolicy]? = nil,
        calendars: [PayrollCalendarPolicy],
        phoneTimeZone: TimeZone = .current
    ) throws -> Bool {
        // Rows that follow these calendars already have nowhere to move.
        guard previous != calendars else { return false }
        let workDay = StoredDay(.workDay, calendars: calendars)
        let periodDay = StoredDay(.periodDay, calendars: calendars)
        let workDayBefore = previous.map { StoredDay(.workDay, calendars: $0) }
        let periodDayBefore = previous.map { StoredDay(.periodDay, calendars: $0) }
        var moved = false
        for record in try context.fetch(FetchDescriptor<ShiftRecord>()) {
            let repaired = workDay.repaired(
                record.workDate, job: record.jobName, before: workDayBefore, phoneTimeZone: phoneTimeZone)
            guard repaired != record.workDate else { continue }
            record.workDate = repaired
            moved = true
        }
        for record in try context.fetch(FetchDescriptor<PaycheckRecord>()) {
            let start = periodDay.repaired(
                record.periodStart, job: record.jobName, before: periodDayBefore, phoneTimeZone: phoneTimeZone)
            let end = periodDay.repaired(
                record.periodEnd, job: record.jobName, before: periodDayBefore, phoneTimeZone: phoneTimeZone)
            guard start != record.periodStart || end != record.periodEnd else { continue }
            record.periodStart = start
            record.periodEnd = end
            moved = true
        }
        return moved
    }

    /// Re-anchors to the policy store's calendars, from the calendars its
    /// rows were last left under, without saving. For the sync, which saves.
    @discardableResult
    static func reanchor(in context: ModelContext, policyStore: PolicyStore) throws -> Bool {
        let calendars = policyStore.policies.calendars
        let moved = try reanchor(in: context, from: policyStore.calendarsStoredDaysFollow, calendars: calendars)
        policyStore.calendarsStoredDaysFollow = calendars
        return moved
    }

    /// The same, saved, for the callers where nothing else is about to save.
    /// A failed save is left for the next one rather than rolled back: a
    /// policy change can arrive in the middle of a sync whose downloaded rows
    /// are not saved yet, and a rollback would drop them.
    static func run(in context: ModelContext, policyStore: PolicyStore) {
        do {
            guard try reanchor(in: context, policyStore: policyStore) else { return }
            try context.save()
        } catch {
            logger.error("Stored day repair failed. type=\(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
