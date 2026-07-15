import Foundation

/// Tracks the first time each Move (keyed by its stable per-type id, e.g.
/// "weekdaySwap") was ever shown to the user - the ledger StatsEngine's
/// followUps(ledger:) reads to judge whether a recommendation was followed
/// and whether it paid off, at least 28 days after the fact. One entry per
/// move id, never overwritten once set - a move that stops and later
/// re-fires doesn't reset its clock. Persistence mirrors InsightsStore.
@Observable
final class MoveLedgerStore {
    private static let key = "com.szakacsmedia.payday.moveLedger"
    private let defaults: UserDefaults

    private(set) var firstShownAt: [String: Date] {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.firstShownAt = Self.load(from: defaults)
    }

    /// Clears every ledger entry — debug/test convenience, mirrors the
    /// reset hooks on the app's other stores.
    func reset() {
        firstShownAt = [:]
    }

    /// Records `now` as the first-shown date for any move id not already
    /// in the ledger; ids already present are left untouched.
    func recordShown(_ moves: [Move], now: Date = .now) {
        var updated = firstShownAt
        var changed = false
        for move in moves where updated[move.id] == nil {
            updated[move.id] = now
            changed = true
        }
        guard changed else { return }
        firstShownAt = updated
    }

    private static func load(from defaults: UserDefaults) -> [String: Date] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(firstShownAt) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
