import Foundation
import SwiftData

/// One-time, idempotent data migrations. A durable version prevents the
/// exact-hours pass from scanning every punch-backed row on every launch.
enum MigrationRunner {
    private static let versionKey = "com.szakacsmedia.payday.localMigrationVersion"
    private static let currentVersion = 2

    static func runPending(in context: ModelContext, defaults: UserDefaults = AppGroup.defaults) {
        let version = defaults.integer(forKey: versionKey)
        var completedVersion = version
        if version < 1 {
            guard backfillShiftIDs(in: context) else { return }
            completedVersion = 1
        }
        if version < 2 {
            guard recomputeExactHours(in: context) else {
                defaults.set(completedVersion, forKey: versionKey)
                return
            }
            completedVersion = 2
        }
        if completedVersion > version {
            defaults.set(completedVersion, forKey: versionKey)
        }
    }

    /// Backfills `shiftID` on legacy TipEntry rows created before shift
    /// grouping existed. Assigns exactly ONE shiftID per pre-existing
    /// calendar day, so old data (including old lumped "doubles", which were
    /// logged as a single blob) stays a single shift and behaves identically.
    ///
    /// The id is derived deterministically from the day, NOT random: two
    /// devices backfilling the same legacy day independently must land on the
    /// same id so a CloudKit merge coalesces them into one shift instead of
    /// forking the day into two. New logs (LogTipSheet) mint random UUIDs.
    @discardableResult
    static func backfillShiftIDs(in context: ModelContext, calendar: Calendar = .current) -> Bool {
        // Cheap short-circuit: nothing to do once every row has an id.
        let pendingDescriptor = FetchDescriptor<TipEntry>(
            predicate: #Predicate { $0.shiftID == nil }
        )
        let pending: [TipEntry]
        do {
            pending = try context.fetch(pendingDescriptor)
        } catch {
            return false
        }
        guard !pending.isEmpty else { return true }

        // Group ALL rows by day (not just the nil ones) so a day that already
        // has an id — from an earlier run or a synced device — coalesces its
        // nil siblings onto that same id rather than forking the day.
        let all: [TipEntry]
        do {
            all = try context.fetch(FetchDescriptor<TipEntry>())
        } catch {
            return false
        }
        let byDay = Dictionary(grouping: all) { calendar.startOfDay(for: $0.date) }
        for (day, rows) in byDay {
            let nilRows = rows.filter { $0.shiftID == nil }
            guard !nilRows.isEmpty else { continue }
            let existing = rows.compactMap(\.shiftID).first
            let id = existing ?? ShiftDays.deterministicShiftID(for: day, calendar: calendar)
            for row in nilRows {
                row.shiftID = id
            }
        }
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }

    /// Recomputes hoursWorked from clockIn/clockOut using ShiftTimes' exact,
    /// never-quarter-rounded rule (Tyler's law: every minute, every penny).
    /// Only rows that actually carry BOTH punches are touched — those are
    /// always a shift's one canonical ShiftDetails entry (clockIn/clockOut/
    /// hoursWorked all live together there), never split across rows, so no
    /// shift-grouping is needed here. A shift with no punches — manual
    /// hours, entered some other way — is left exactly as entered.
    /// Naturally idempotent: recomputing the same punches always yields the
    /// same answer, so this is safe to run on every launch with no separate
    /// "already migrated" flag.
    @discardableResult
    static func recomputeExactHours(in context: ModelContext, calendar: Calendar = .current) -> Bool {
        let descriptor = FetchDescriptor<TipEntry>(
            predicate: #Predicate { $0.clockIn != nil && $0.clockOut != nil }
        )
        let punchBacked: [TipEntry]
        do {
            punchBacked = try context.fetch(descriptor)
        } catch {
            return false
        }
        guard !punchBacked.isEmpty else { return true }
        for entry in punchBacked {
            guard let exact = ShiftTimes.hours(clockIn: entry.clockIn, clockOut: entry.clockOut, calendar: calendar) else { continue }
            if entry.hoursWorked != exact {
                entry.hoursWorked = exact
            }
        }
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }
}
