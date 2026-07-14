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

/// Caches the last Insights analysis so it survives app relaunch — the
/// network call only happens again when the user explicitly taps
/// "Analyze Again," never automatically on open.
@Observable
final class InsightsStore {
    private static let key = "com.szakacsmedia.payday.insightsSnapshot"
    private let defaults: UserDefaults

    var snapshot: InsightsSnapshot? {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.snapshot = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> InsightsSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(InsightsSnapshot.self, from: data)
    }

    private func persist() {
        guard let snapshot else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
