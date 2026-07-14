import Foundation

struct InsightsSnapshot: Codable {
    let sections: [InsightSection]
    let generatedAt: Date
    /// The facts this narration was generated from — lets the caller
    /// detect "the underlying numbers changed since last time" and
    /// regenerate, instead of a time-based schedule. Optional so a
    /// pre-existing persisted snapshot (from before this field existed)
    /// still decodes; it just always looks stale once, which self-heals.
    let facts: InsightsFacts?
}

/// Caches the last Insights analysis so it survives app relaunch. The
/// refresh itself is autonomous (InsightsView decides when it's due) —
/// this store just persists the result and whether the last attempt
/// failed, so a failed call can retry on the next visit instead of
/// waiting out the full interval with no recourse.
@Observable
final class InsightsStore {
    private static let key = "com.szakacsmedia.payday.insightsSnapshot"
    private static let lastAttemptFailedKey = "com.szakacsmedia.payday.insightsLastAttemptFailed"
    private let defaults: UserDefaults

    var snapshot: InsightsSnapshot? {
        didSet { persistSnapshot() }
    }

    /// Set on a failed refresh, cleared on the next success. While true,
    /// the next visit retries immediately, bypassing the normal interval
    /// gate — a network hiccup shouldn't lock someone out of a refresh
    /// for days with no "Analyze Again" button to fall back on.
    var lastAttemptFailed: Bool {
        didSet { defaults.set(lastAttemptFailed, forKey: Self.lastAttemptFailedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.snapshot = Self.load(from: defaults)
        self.lastAttemptFailed = defaults.bool(forKey: Self.lastAttemptFailedKey)
    }

    private static func load(from defaults: UserDefaults) -> InsightsSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(InsightsSnapshot.self, from: data)
    }

    private func persistSnapshot() {
        guard let snapshot else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
