import Foundation

/// Decides whether Insights should spend a narration call right now. Pure and
/// stateless so the rule that governs real money is testable without a view,
/// a store, or "now" — same treatment as PaydayMoment and WorkScheduleNudge.
///
/// The rule, in plain terms: narrate at most twice a week, only when the
/// numbers actually moved, and give a genuinely transient failure one early
/// retry per hour rather than one per visit to the tab.
///
/// That last clause is the whole reason this exists. It used to read
/// `if lastAttemptFailed { return true }` with no floor, so for as long as
/// narration stayed broken every single visit to the Insights tab fired a
/// request — ten days of that through Jul/Aug 2026. It happened to cost
/// nothing, because the proxy was rejecting each one with a 400 before
/// reaching OpenAI, but a failure that lands AFTER a billed call (an answer
/// that won't parse) would have charged for every visit. Deterministic
/// failures no longer set the flag at all (see InsightsError.isRetryable), and
/// the ones that do are floored by a cooldown.
enum NarrationRefresh {
    /// Upper bound on cadence — "maybe weekly, twice a week at most."
    static let minimumInterval: TimeInterval = 3.5 * 24 * 3600

    /// How long a retryable failure waits before it may try again. An hour
    /// keeps a real hiccup feeling recoverable while bounding the worst case
    /// at 24 attempts a day instead of however many times the tab is opened.
    static let failedRetryInterval: TimeInterval = 3600

    /// - Parameters:
    ///   - snapshotGeneratedAt: when the displayed narration was generated,
    ///     nil if there has never been one.
    ///   - factsMatchSnapshot: whether the numbers are unchanged since that
    ///     narration. Unchanged means there is nothing new to say.
    ///   - lastAttemptFailed: whether the last attempt failed RETRYABLY.
    ///   - lastAttemptAt: when the last attempt ran. nil (no attempt yet, or a
    ///     build predating the timestamp) reads as "cooldown elapsed", so an
    ///     upgrade carrying a stuck failure flag can never strand itself with
    ///     no retry.
    static func isDue(
        now: Date,
        snapshotGeneratedAt: Date?,
        factsMatchSnapshot: Bool,
        lastAttemptFailed: Bool,
        lastAttemptAt: Date?
    ) -> Bool {
        if lastAttemptFailed {
            let sinceLastAttempt = lastAttemptAt.map { now.timeIntervalSince($0) } ?? .infinity
            if sinceLastAttempt >= failedRetryInterval { return true }
        }
        guard let snapshotGeneratedAt else { return true }
        guard !factsMatchSnapshot else { return false }
        return now.timeIntervalSince(snapshotGeneratedAt) >= minimumInterval
    }
}
