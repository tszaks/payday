import Foundation

/// When Payday may ask for an App Store rating.
///
/// A deliberately quiet cadence: the third, twenty-fifth and hundredth
/// completed shift, never twice inside six months. Apple may suppress any
/// request without telling us, so this records ATTEMPTS and never assumes a
/// prompt was actually shown.
///
/// Tied to completed shifts, not to a positive result, a record night, or any
/// other sentiment gate. Asking only after a good night would buy ratings
/// from the moments most likely to flatter us, which is both against the
/// review guidelines and a lie about what the average user thinks.
///
/// ## Why this is its own file
///
/// It lived as a `private enum` inside `LogTipSheet.swift`, a two-thousand
/// line view, reachable from exactly one line in that same file. Nothing
/// could test it. A policy with three thresholds, a time gate and
/// `UserDefaults` persistence and no tests is the shape of a feature that
/// silently never fires and nobody notices for a year -- the failure is
/// indistinguishable from StoreKit's own suppression, which is the one thing
/// this code is specifically designed not to be able to observe.
///
/// ## Why the predicate does not write
///
/// `shouldRequest` used to call `defaults.set` twice immediately before
/// `return true`. A question that answers differently the second time it is
/// asked is a trap: any future guard clause, log line, assertion or debug
/// print that calls it consumes a milestone the user never saw, and the bug
/// is invisible because the missing prompt looks exactly like StoreKit
/// declining to show one. The predicate is now pure and
/// `recordRequested(...)` is a separate, explicitly named write.
enum ReviewPromptPolicy {
    static let milestoneKey = "appReview.lastRequestedMilestone"
    static let dateKey = "appReview.lastRequestedAt"

    /// Completed-shift counts that earn an ask.
    static let milestones = [5, 25, 100]

    /// Six months. Two asks inside one season is nagging whatever the counts
    /// say, so the interval overrides the milestones rather than the reverse.
    static let minimumInterval: TimeInterval = 180 * 24 * 60 * 60

    /// The highest milestone this count has reached, or nil below the first.
    static func milestoneReached(completedShifts count: Int) -> Int? {
        milestones.last(where: { count >= $0 })
    }

    /// Whether an ask is earned. **Pure**: no writes, no defaults mutated,
    /// same answer however many times it is called.
    static func shouldRequest(
        afterCompletedShifts count: Int,
        now: Date = .now,
        defaults: UserDefaults = .standard
    ) -> Bool {
        #if DEBUG
        // The showcase seed fabricates a full history for screenshots. Asking
        // a screenshot run for a rating would both waste the milestone and
        // put a system alert in the middle of a marketing capture.
        guard !ProcessInfo.processInfo.arguments.contains("-SeedShowcase") else {
            return false
        }
        #endif
        guard let milestone = milestoneReached(completedShifts: count) else { return false }
        guard milestone > defaults.integer(forKey: milestoneKey) else { return false }
        if let lastRequestedAt = defaults.object(forKey: dateKey) as? Date,
           now.timeIntervalSince(lastRequestedAt) < minimumInterval {
            return false
        }
        return true
    }

    /// Record that an ask was ATTEMPTED. Called on the path that actually
    /// invokes `requestReview()`, never from the predicate.
    ///
    /// Deliberately recorded at the moment the attempt is decided rather than
    /// after the delay that precedes it: two saves in quick succession would
    /// otherwise both pass the predicate and queue two asks. A milestone
    /// spent on a request StoreKit silently declined is the intended
    /// behaviour -- "attempts, not impressions" is the whole contract, since
    /// the app cannot observe an impression.
    static func recordRequested(
        afterCompletedShifts count: Int,
        now: Date = .now,
        defaults: UserDefaults = .standard
    ) {
        guard let milestone = milestoneReached(completedShifts: count) else { return }
        defaults.set(milestone, forKey: milestoneKey)
        defaults.set(now, forKey: dateKey)
    }

    /// How many completed shifts the account holds, from whichever
    /// representation is authoritative.
    ///
    /// Extracted from the call site and given a test for the same reason the
    /// Dashboard's empty state was: a screen-level expression that reads one
    /// arm of the flip is exactly the thing that ships working on legacy
    /// accounts and broken on converted ones, and 1195 green tests will not
    /// mention it. Post-flip this must count RECORDS; the legacy grouping is
    /// empty for a converted account and would hold every such user at zero
    /// forever.
    static func completedShiftCount(
        recordCount: Int,
        legacyShiftCount: Int,
        usesRecords: Bool
    ) -> Int {
        usesRecords ? recordCount : legacyShiftCount
    }
}
