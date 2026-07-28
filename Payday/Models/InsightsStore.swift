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
        guard let decoded = try? JSONDecoder().decode(InsightsSnapshot.self, from: data) else { return nil }
        return scrubbed(decoded)
    }

    /// Cash-vs-credit was banned as a topic (2026-07-27, app facts + proxy
    /// prompt) — but a narration generated BEFORE the ban persists here and
    /// keeps displaying until the next due refresh, days away. Scrub the
    /// fossil at load so the ban takes effect immediately, and keep the
    /// filter permanently as a belt-and-braces guard against the model
    /// ever regressing.
    private static func scrubbed(_ snapshot: InsightsSnapshot) -> InsightsSnapshot {
        let cleaned = snapshot.sections.filter { section in
            let title = section.title.lowercased()
            return !(title.contains("cash") && title.contains("credit"))
        }
        guard cleaned.count != snapshot.sections.count else { return snapshot }
        return InsightsSnapshot(sections: cleaned, generatedAt: snapshot.generatedAt, facts: snapshot.facts)
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
