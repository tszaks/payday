import Foundation

/// One gate the user hasn't cleared yet, and how close they are to clearing
/// it — turns StatsEngine's silent sample-size gates (insights needs 5
/// shifts, a weekday read needs 3, $/hr and tip percent each need 3 with
/// the right field logged) into something the app can actually say out
/// loud. Pure and unit-testable like StatsEngine, and deliberately NOT
/// referenced from StatsEngine.swift itself — that file also compiles into
/// the widget target, and this one doesn't (see project.yml).
struct Unlock: Equatable, Identifiable {
    enum Kind: Equatable {
        case insights
        case weekday(Int)
        case hourlyRate
        case tipPercent
    }

    let kind: Kind
    let have: Int
    let need: Int

    var remaining: Int { need - have }

    var id: String {
        switch kind {
        case .insights: return "insights"
        case .weekday(let weekday): return "weekday-\(weekday)"
        case .hourlyRate: return "hourly-rate"
        case .tipPercent: return "tip-percent"
        }
    }

    var line: String { UnlockCopy.line(for: kind, remaining: remaining) }
}

/// The user-facing sentence for each unlock, kept separate from Unlock
/// itself so the wording rules (singular vs. plural, weekday naming) live
/// in one obvious place. Calm and specific, no exclamation marks.
enum UnlockCopy {
    static func line(for kind: Unlock.Kind, remaining: Int) -> String {
        let shiftWord = remaining == 1 ? "shift" : "shifts"
        switch kind {
        case .insights:
            return "\(remaining) more \(shiftWord) and Payday starts reading your patterns."
        case .weekday(let weekday):
            // Calendar.current, not the caller's calendar — matches how
            // StatsEngine's own Move copy names weekdays (see weekdaySwapMove).
            let name = Calendar.current.weekdaySymbols[weekday - 1]
            return "\(remaining) more \(name) \(shiftWord) and \(name)s get their own read."
        case .hourlyRate:
            return "\(remaining) more \(shiftWord) with times and your hourly rate unlocks."
        case .tipPercent:
            return "\(remaining) more \(shiftWord) with sales and your tip percent unlocks."
        }
    }
}

/// Computes which sample-size gates are closest to opening next. No I/O, no
/// SwiftData — plain TipRecord facts in, plain Unlocks out.
enum UnlockProgress {
    /// Total shift count, grouped exactly the way the rest of the app groups
    /// shifts (see ShiftDays.groupedByShift): records sharing a shiftID are
    /// one shift; legacy nil-shiftID records fall back to a day-derived id.
    static func shiftCount(records: [TipRecord], calendar: Calendar = .current) -> Int {
        groupedShifts(records: records, calendar: calendar).count
    }

    /// The next `limit` gates worth telling the user about, closest first.
    /// Insights always leads when it hasn't unlocked yet; everything else is
    /// ranked by how few shifts remain, with weekday/hourlyRate/tipPercent as
    /// the tiebreak order. Empty when nothing qualifies — a mature account
    /// has nothing left to anticipate.
    static func nextUnlocks(records: [TipRecord], asOf: Date = .now, calendar: Calendar = .current, limit: Int = 2) -> [Unlock] {
        let shifts = groupedShifts(records: records, calendar: calendar)

        let insightsNeed = StatsEngine.minimumShiftsForInsights
        let insightsUnlock: Unlock? = shifts.count < insightsNeed
            ? Unlock(kind: .insights, have: shifts.count, need: insightsNeed)
            : nil

        // Order index used only to break remaining-count ties, per spec:
        // weekday, then hourlyRate, then tipPercent.
        var rest: [(order: Int, unlock: Unlock)] = []
        if let weekday = weekdayUnlock(shifts: shifts, asOf: asOf, calendar: calendar) {
            rest.append((0, weekday))
        }
        if let hourly = thresholdUnlock(shifts: shifts, need: StatsEngine.minimumNightsForRate, kind: .hourlyRate, predicate: { ($0.hoursWorked ?? 0) > 0 }) {
            rest.append((1, hourly))
        }
        if let tip = thresholdUnlock(shifts: shifts, need: StatsEngine.minimumNightsForSales, kind: .tipPercent, predicate: { ($0.salesCents ?? 0) > 0 }) {
            rest.append((2, tip))
        }

        let sortedRest = rest
            .sorted { lhs, rhs in
                if lhs.unlock.remaining != rhs.unlock.remaining { return lhs.unlock.remaining < rhs.unlock.remaining }
                return lhs.order < rhs.order
            }
            .map(\.unlock)

        let ordered = [insightsUnlock].compactMap { $0 } + sortedRest
        return Array(ordered.prefix(limit))
    }

    private static func groupedShifts(records: [TipRecord], calendar: Calendar) -> [(day: Date, shiftID: UUID, items: [TipRecord])] {
        ShiftDays.groupedByShift(records, shiftID: { $0.shiftID }, date: { $0.date }, calendar: calendar)
    }

    /// At most one weekday candidate: a weekday worked only 1 or 2 times,
    /// whose most recent shift is within 45 days of `asOf` (a Sunday pickup
    /// from months ago shouldn't nag forever). Smallest remaining wins; ties
    /// go to whichever weekday was worked more recently.
    private static func weekdayUnlock(shifts: [(day: Date, shiftID: UUID, items: [TipRecord])], asOf: Date, calendar: Calendar) -> Unlock? {
        let need = StatsEngine.minimumNightsForWeekdayBest
        let today = calendar.startOfDay(for: asOf)
        let byWeekday = Dictionary(grouping: shifts) { calendar.component(.weekday, from: $0.day) }

        let candidates: [(weekday: Int, count: Int, mostRecent: Date)] = byWeekday.compactMap { weekday, group in
            guard group.count == 1 || group.count == 2, let mostRecent = group.map(\.day).max() else { return nil }
            let daysSince = calendar.dateComponents([.day], from: mostRecent, to: today).day ?? Int.max
            guard abs(daysSince) <= 45 else { return nil }
            return (weekday: weekday, count: group.count, mostRecent: mostRecent)
        }

        guard let winner = candidates.min(by: { lhs, rhs in
            let lhsRemaining = need - lhs.count
            let rhsRemaining = need - rhs.count
            if lhsRemaining != rhsRemaining { return lhsRemaining < rhsRemaining }
            return lhs.mostRecent > rhs.mostRecent
        }) else { return nil }

        return Unlock(kind: .weekday(winner.weekday), have: winner.count, need: need)
    }

    /// Shared shape for hourlyRate and tipPercent: counts shifts where any
    /// record satisfies `predicate`, and only surfaces once at least one
    /// such shift exists — zero means the habit hasn't started yet, and
    /// silence beats nagging about something never begun.
    private static func thresholdUnlock(shifts: [(day: Date, shiftID: UUID, items: [TipRecord])], need: Int, kind: Unlock.Kind, predicate: (TipRecord) -> Bool) -> Unlock? {
        let have = shifts.filter { $0.items.contains(where: predicate) }.count
        guard have >= 1, have < need else { return nil }
        return Unlock(kind: kind, have: have, need: need)
    }
}
