import Foundation

/// Which job's shifts a snapshot query selects (Pillar 9). `.all` is every
/// job and the default everywhere, so a query written before jobs keeps its
/// meaning. `.job(nil)` is the primary job: the shifts with no job tag.
public enum JobScope: Hashable, Sendable {
    case all
    case job(String?)

    /// Whether a shift tagged `jobName` belongs to this scope (trimmed,
    /// case-insensitive, like roles).
    public func includes(_ jobName: String?) -> Bool {
        switch self {
        case .all: return true
        case .job(let name): return ShiftRole.key(name) == ShiftRole.key(jobName)
        }
    }
}
