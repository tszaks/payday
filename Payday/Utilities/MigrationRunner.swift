import Foundation
import SwiftData

/// One-time, idempotent data migrations that run at launch. Kept tiny and
/// self-guarding: each pass fetches only the rows that still need work, so
/// running it every launch is cheap and also heals rows that arrive late
/// from another device via CloudKit sync.
enum MigrationRunner {
    /// Backfills `shiftID` on legacy TipEntry rows created before shift
    /// grouping existed. Assigns exactly ONE shiftID per pre-existing
    /// calendar day, so old data (including old lumped "doubles", which were
    /// logged as a single blob) stays a single shift and behaves identically.
    ///
    /// The id is derived deterministically from the day, NOT random: two
    /// devices backfilling the same legacy day independently must land on the
    /// same id so a CloudKit merge coalesces them into one shift instead of
    /// forking the day into two. New logs (LogTipSheet) mint random UUIDs.
    static func backfillShiftIDs(in context: ModelContext, calendar: Calendar = .current) {
        // Cheap short-circuit: nothing to do once every row has an id.
        let pendingDescriptor = FetchDescriptor<TipEntry>(
            predicate: #Predicate { $0.shiftID == nil }
        )
        guard let pending = try? context.fetch(pendingDescriptor), !pending.isEmpty else { return }

        // Group ALL rows by day (not just the nil ones) so a day that already
        // has an id — from an earlier run or a synced device — coalesces its
        // nil siblings onto that same id rather than forking the day.
        guard let all = try? context.fetch(FetchDescriptor<TipEntry>()) else { return }
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
        try? context.save()
    }
}
