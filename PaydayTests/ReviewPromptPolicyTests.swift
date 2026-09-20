import Foundation
import Testing
@testable import Payday

/// The policy shipped as a `private enum` inside a two-thousand-line view,
/// reachable from one line in that same file, with no test of any kind. Three
/// thresholds, a six-month gate and `UserDefaults` persistence, and the only
/// way to learn it was broken was for nobody to ever be asked for a rating --
/// which is indistinguishable from StoreKit quietly declining, the one
/// outcome this code is designed to be unable to observe.
@Suite("Review prompt policy")
struct ReviewPromptPolicyTests {
    /// A defaults suite per test. `.standard` would leak the milestone key
    /// between tests and, worse, between a test run and the developer's own
    /// simulator, where it would silently consume a real milestone.
    private func freshDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: milestones

    @Test("below the first milestone there is no ask")
    func belowFirstMilestone() {
        let defaults = freshDefaults()
        for count in 0...4 {
            #expect(ReviewPromptPolicy.milestoneReached(completedShifts: count) == nil)
            #expect(!ReviewPromptPolicy.shouldRequest(
                afterCompletedShifts: count, now: now, defaults: defaults))
        }
    }

    /// The boundary itself, which an off-by-one would move to 6.
    @Test("exactly the fifth completed shift earns the first ask")
    func exactlyAtFive() {
        let defaults = freshDefaults()
        #expect(ReviewPromptPolicy.milestoneReached(completedShifts: 5) == 5)
        #expect(ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: 5, now: now, defaults: defaults))
    }

    @Test("a count between milestones reports the lower one, not the next")
    func betweenMilestones() {
        #expect(ReviewPromptPolicy.milestoneReached(completedShifts: 24) == 5)
        #expect(ReviewPromptPolicy.milestoneReached(completedShifts: 25) == 25)
        #expect(ReviewPromptPolicy.milestoneReached(completedShifts: 99) == 25)
        #expect(ReviewPromptPolicy.milestoneReached(completedShifts: 100) == 100)
        #expect(ReviewPromptPolicy.milestoneReached(completedShifts: 10_000) == 100,
                "past the last milestone it stays at the last one, it does not reset")
    }

    // MARK: the predicate does not write

    /// The hazard the split exists for. The old `shouldRequest` called
    /// `defaults.set` twice before returning true, so asking the question
    /// twice gave two different answers and any future caller -- a guard, a
    /// log line, a debug print -- silently spent a milestone.
    @Test("asking twice gives the same answer, because the predicate writes nothing")
    func predicateIsPure() {
        let defaults = freshDefaults()
        #expect(ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: 5, now: now, defaults: defaults))
        #expect(ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: 5, now: now, defaults: defaults),
                "a second ask must not have been consumed by the first")
        #expect(defaults.integer(forKey: ReviewPromptPolicy.milestoneKey) == 0)
        #expect(defaults.object(forKey: ReviewPromptPolicy.dateKey) == nil)
    }

    @Test("recording the attempt is what consumes the milestone")
    func recordingConsumes() {
        let defaults = freshDefaults()
        ReviewPromptPolicy.recordRequested(afterCompletedShifts: 5, now: now, defaults: defaults)
        #expect(defaults.integer(forKey: ReviewPromptPolicy.milestoneKey) == 5)
        #expect(!ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: 5, now: now, defaults: defaults))
    }

    @Test("a consumed milestone stays consumed, but the next one still earns an ask")
    func nextMilestoneAfterConsumed() {
        let defaults = freshDefaults()
        ReviewPromptPolicy.recordRequested(afterCompletedShifts: 5, now: now, defaults: defaults)
        let wellPast = now.addingTimeInterval(ReviewPromptPolicy.minimumInterval + 1)
        #expect(!ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: 24, now: wellPast, defaults: defaults),
                "still the 5 milestone; it is spent")
        #expect(ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: 25, now: wellPast, defaults: defaults))
    }

    // MARK: the six-month gate, from both sides

    @Test("one second inside six months is refused, one second past it is allowed")
    func intervalBoundaryBothSides() {
        let interval = ReviewPromptPolicy.minimumInterval

        let tooSoon = freshDefaults()
        ReviewPromptPolicy.recordRequested(afterCompletedShifts: 5, now: now, defaults: tooSoon)
        #expect(!ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: 25,
            now: now.addingTimeInterval(interval - 1),
            defaults: tooSoon), "a second ask inside six months is nagging whatever the count says")

        let longEnough = freshDefaults()
        ReviewPromptPolicy.recordRequested(afterCompletedShifts: 5, now: now, defaults: longEnough)
        #expect(ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: 25,
            now: now.addingTimeInterval(interval + 1),
            defaults: longEnough))
    }

    @Test("the interval overrides a freshly earned milestone, it does not yield to it")
    func intervalBeatsMilestone() {
        let defaults = freshDefaults()
        ReviewPromptPolicy.recordRequested(afterCompletedShifts: 5, now: now, defaults: defaults)
        #expect(!ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: 100,
            now: now.addingTimeInterval(60),
            defaults: defaults),
            "reaching the LAST milestone a minute later still does not earn a second ask")
    }

    // MARK: which arm of the flip supplies the count

    /// The same class of defect as the Dashboard's empty state: a screen-level
    /// expression reading one arm of the flip ships working on legacy
    /// accounts and broken on converted ones. Post-flip the legacy grouping
    /// is empty by construction, so reading it would hold every converted
    /// user at zero completed shifts forever and no one would ever be asked.
    @Test("a flipped account counts records; the legacy grouping is empty for it")
    func flippedAccountCountsRecords() {
        #expect(ReviewPromptPolicy.completedShiftCount(
            recordCount: 30, legacyShiftCount: 0, usesRecords: true) == 30)
        // The disagreeing case: if this read the legacy arm it would be 0,
        // which is below the first milestone, forever.
        #expect(ReviewPromptPolicy.shouldRequest(
            afterCompletedShifts: ReviewPromptPolicy.completedShiftCount(
                recordCount: 30, legacyShiftCount: 0, usesRecords: true),
            now: now,
            defaults: freshDefaults()))
    }

    @Test("a legacy account counts the grouping; its record store is empty")
    func legacyAccountCountsGrouping() {
        #expect(ReviewPromptPolicy.completedShiftCount(
            recordCount: 0, legacyShiftCount: 30, usesRecords: false) == 30)
    }
}
