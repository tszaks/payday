import Foundation
import SwiftData

/// The one fact `PolicyStore.runMigrationsIfNeeded` needs from the store: the
/// instant of the user's first shift, which the assumed rate policy takes
/// effect on so that nothing before their first shift is priced.
///
/// It reads BOTH representations and takes the earlier. `ShiftRecord` is the
/// read-authoritative mirror of `public.shifts`, but the server-side deriver
/// lands in a later PR 2 slice, so on a device that has not yet received
/// derived rows the only history is `TipEntry`. Reading one and not the other
/// would put the rate's effective date after some of the user's real shifts
/// and value them `.rateNotSet` — a silent "no wage" on history they worked.
enum PolicyMigrationInputs {
    /// The earliest shift instant across both representations, or nil when
    /// there is no history at all.
    @MainActor
    static func earliestShiftDate(in context: ModelContext) -> Date? {
        var candidates: [Date] = []

        var shiftDescriptor = FetchDescriptor<ShiftRecord>(
            sortBy: [SortDescriptor(\.workDate, order: .forward)]
        )
        shiftDescriptor.fetchLimit = 1
        if let earliestShift = try? context.fetch(shiftDescriptor).first?.workDate {
            candidates.append(earliestShift)
        }

        var entryDescriptor = FetchDescriptor<TipEntry>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        entryDescriptor.fetchLimit = 1
        if let earliestEntry = try? context.fetch(entryDescriptor).first?.date {
            candidates.append(earliestEntry)
        }

        return candidates.min()
    }

    /// How many shifts the user has, across both representations, for the
    /// "is the rate-history prompt owed" question. A count, not a merge: it
    /// only has to answer "any at all".
    @MainActor
    static func shiftCount(in context: ModelContext) -> Int {
        let shifts = (try? context.fetchCount(FetchDescriptor<ShiftRecord>())) ?? 0
        guard shifts == 0 else { return shifts }
        return (try? context.fetchCount(FetchDescriptor<TipEntry>())) ?? 0
    }
}
