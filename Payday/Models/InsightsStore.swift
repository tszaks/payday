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
    private static let lastAttemptAtKey = "com.szakacsmedia.payday.insightsLastAttemptAt"
    private static let ruleVersionKey = "com.szakacsmedia.payday.insightsRuleVersion"

    /// Bump this whenever the rules that PRODUCE a narration change — the
    /// facts sent, the prompt, or what's allowed to be said. A cached
    /// narration written under the old rules is discarded once on the next
    /// launch, so a rule change takes effect immediately instead of waiting
    /// out the multi-day refresh interval.
    ///
    /// Version 2 (2026-08-05): notes gained a 30-day window and the prompt
    /// gained a retirement clause. Without this bump, a WORTH KNOWING section
    /// explaining July 17 would have stayed on screen for another four days
    /// after both fixes shipped — the snapshot was fresh, so nothing was due.
    /// This is the general form of the one-off cash-vs-credit scrub below,
    /// which had to filter fossils by title because there was no version to
    /// key on.
    private static let currentRuleVersion = 2
    private let defaults: UserDefaults

    var snapshot: InsightsSnapshot? {
        didSet { persistSnapshot() }
    }

    /// Set on a RETRYABLE failed refresh (no network, a timeout, a 5xx),
    /// cleared on the next success. While true, a visit may retry ahead of the
    /// normal interval — a network hiccup shouldn't lock someone out of a
    /// refresh for days with no "Analyze Again" button to fall back on.
    ///
    /// Deliberately NOT set for a deterministic failure (a 4xx, or an answer
    /// that won't parse): retrying byte-identical input fails identically, and
    /// in the parse case the OpenAI call has already been billed.
    var lastAttemptFailed: Bool {
        didSet { defaults.set(lastAttemptFailed, forKey: Self.lastAttemptFailedKey) }
    }

    /// When the last refresh attempt ran, successful or not. Pairs with
    /// `lastAttemptFailed` to make the early retry once per COOLDOWN WINDOW
    /// rather than once per visit to the tab, which is what it used to be.
    /// nil (a build that predates this, or no attempt yet) reads as "cooldown
    /// elapsed" so an upgrade can never wedge itself into never retrying.
    var lastAttemptAt: Date? {
        didSet {
            guard let lastAttemptAt else {
                defaults.removeObject(forKey: Self.lastAttemptAtKey)
                return
            }
            defaults.set(lastAttemptAt.timeIntervalSinceReferenceDate, forKey: Self.lastAttemptAtKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A narration written under superseded rules is dropped, not shown. The
        // next visit to Insights sees no snapshot and regenerates immediately.
        let storedRuleVersion = defaults.integer(forKey: Self.ruleVersionKey)
        let rulesChanged = storedRuleVersion != Self.currentRuleVersion
        self.snapshot = rulesChanged ? nil : Self.load(from: defaults)
        self.lastAttemptFailed = defaults.bool(forKey: Self.lastAttemptFailedKey)
        let storedAttemptAt = defaults.double(forKey: Self.lastAttemptAtKey)
        self.lastAttemptAt = storedAttemptAt == 0 ? nil : Date(timeIntervalSinceReferenceDate: storedAttemptAt)

        if rulesChanged {
            // Clear the stored narration too, and record the new version so the
            // discard happens exactly once. lastAttemptAt is left alone: a
            // rule change is not a failed attempt, and the empty snapshot is
            // itself enough to make the next visit refresh.
            defaults.removeObject(forKey: Self.key)
            defaults.set(Self.currentRuleVersion, forKey: Self.ruleVersionKey)
        }
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
