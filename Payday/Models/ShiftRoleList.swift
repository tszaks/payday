import Foundation
import PaydayCore

/// The account's roles, read off its shifts. One place, so the log sheet's
/// chips, the Insights filter and Settings > Roles and rates agree on what
/// the roles are and how two spellings of one role collapse.
///
/// Roles compare trimmed and case-insensitively (`ShiftRole.key`). The name
/// shown is the spelling on the most recent shift with that role.
///
/// Pure functions over plain values, so the rules are testable without a
/// model container; the `ShiftRecord` overloads only map.
enum ShiftRoleList {
    /// One shift as these rules see it.
    struct Entry: Equatable {
        let roleName: String?
        let workDate: Date
        let recordedAt: Date?
        let shiftPeriod: ShiftPeriod?
    }

    @MainActor
    static func entries(_ records: [ShiftRecord]) -> [Entry] {
        records.map {
            Entry(roleName: $0.roleName, workDate: $0.workDate, recordedAt: $0.recordedAt, shiftPeriod: $0.shiftPeriod)
        }
    }

    /// Newest first: work date, then when it was logged.
    private static func newestFirst(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            ($0.workDate, $0.recordedAt ?? .distantPast) > ($1.workDate, $1.recordedAt ?? .distantPast)
        }
    }

    /// Distinct roles, most recently used first. The log sheet's chip order.
    static func byRecency(_ entries: [Entry]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in newestFirst(entries) {
            guard let name = ShiftRole.normalized(entry.roleName), let key = ShiftRole.key(name) else { continue }
            if seen.insert(key).inserted { result.append(name) }
        }
        return result
    }

    /// Distinct roles, most shifts first; ties go to the more recent role.
    /// The Insights filter's order.
    static func byUse(_ entries: [Entry]) -> [String] {
        let recency = byRecency(entries)
        var counts: [String: Int] = [:]
        for entry in entries {
            if let key = ShiftRole.key(entry.roleName) { counts[key, default: 0] += 1 }
        }
        return recency.enumerated()
            .sorted { lhs, rhs in
                let l = counts[ShiftRole.key(lhs.element) ?? ""] ?? 0
                let r = counts[ShiftRole.key(rhs.element) ?? ""] ?? 0
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The role a new shift starts with: the role of the most recent shift
    /// on the same weekday AND period, else the role of the most recent
    /// shift. Nil when the most recent match has no role, or no shift has one.
    static func preselected(
        _ entries: [Entry],
        weekday: Int,
        period: ShiftPeriod?,
        calendar: Calendar = .current
    ) -> String? {
        let ordered = newestFirst(entries)
        if let match = ordered.first(where: {
            calendar.component(.weekday, from: $0.workDate) == weekday && $0.shiftPeriod == period
        }), let role = ShiftRole.normalized(match.roleName) {
            return role
        }
        return ordered.first.flatMap { ShiftRole.normalized($0.roleName) }
    }

    /// Whether `roleName` is `role` under the comparison rule.
    static func matches(_ roleName: String?, _ role: String) -> Bool {
        guard let key = ShiftRole.key(roleName) else { return false }
        return key == ShiftRole.key(role)
    }
}
