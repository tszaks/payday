import Testing
import Foundation
@testable import Payday

private func at(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

/// The rule that decides when Insights spends a narration call. Pinned because
/// the version without a failure cooldown fired one request per visit to the
/// tab for ten days straight.
@Suite("Narration refresh cadence")
struct NarrationRefreshTests {
    @Test("no narration yet is always due")
    func firstRunIsDue() {
        #expect(NarrationRefresh.isDue(
            now: at(8, 4),
            snapshotGeneratedAt: nil,
            factsMatchSnapshot: false,
            lastAttemptFailed: false,
            lastAttemptAt: nil
        ))
    }

    @Test("unchanged numbers are never due, however long it has been")
    func unchangedFactsNeverDue() {
        #expect(!NarrationRefresh.isDue(
            now: at(8, 4),
            snapshotGeneratedAt: at(1, 1),
            factsMatchSnapshot: true,
            lastAttemptFailed: false,
            lastAttemptAt: at(1, 1)
        ))
    }

    @Test("changed numbers still wait out the interval")
    func changedFactsWaitForInterval() {
        // 2 days after the last narration, short of the 3.5-day floor.
        #expect(!NarrationRefresh.isDue(
            now: at(8, 4),
            snapshotGeneratedAt: at(8, 2),
            factsMatchSnapshot: false,
            lastAttemptFailed: false,
            lastAttemptAt: at(8, 2)
        ))
    }

    @Test("changed numbers past the interval are due")
    func changedFactsPastIntervalDue() {
        #expect(NarrationRefresh.isDue(
            now: at(8, 4),
            snapshotGeneratedAt: at(7, 28),
            factsMatchSnapshot: false,
            lastAttemptFailed: false,
            lastAttemptAt: at(7, 28)
        ))
    }

    // MARK: The cooldown — the part that was missing

    @Test("a retryable failure does NOT retry again within the hour")
    func failureWaitsOutCooldown() {
        // This is the exact shape of the bug: failed, numbers unchanged, and
        // the tab opened again ten minutes later. It used to return true here,
        // once per visit, forever.
        #expect(!NarrationRefresh.isDue(
            now: at(8, 4, hour: 12),
            snapshotGeneratedAt: at(8, 1),
            factsMatchSnapshot: true,
            lastAttemptFailed: true,
            lastAttemptAt: at(8, 4, hour: 12).addingTimeInterval(-600)
        ))
    }

    @Test("a retryable failure retries once the hour is up")
    func failureRetriesAfterCooldown() {
        #expect(NarrationRefresh.isDue(
            now: at(8, 4, hour: 12),
            snapshotGeneratedAt: at(8, 1),
            factsMatchSnapshot: true,
            lastAttemptFailed: true,
            lastAttemptAt: at(8, 4, hour: 12).addingTimeInterval(-NarrationRefresh.failedRetryInterval)
        ))
    }

    @Test("a stuck failure flag with no recorded attempt still gets one retry")
    func upgradeFromBuildWithoutTimestamp() {
        // A build that predates lastAttemptAt can carry lastAttemptFailed=true
        // with no timestamp. Treating nil as "never attempted" must not strand
        // it at never-retry.
        #expect(NarrationRefresh.isDue(
            now: at(8, 4),
            snapshotGeneratedAt: at(8, 1),
            factsMatchSnapshot: true,
            lastAttemptFailed: true,
            lastAttemptAt: nil
        ))
    }

    @Test("a failure inside the cooldown still falls through to the normal rules")
    func cooldownDoesNotBlockAGenuinelyDueRefresh() {
        // Failed 10 minutes ago, but the numbers moved AND the interval has
        // passed — the cooldown suppresses the bypass, not the refresh itself.
        #expect(NarrationRefresh.isDue(
            now: at(8, 4, hour: 12),
            snapshotGeneratedAt: at(7, 20),
            factsMatchSnapshot: false,
            lastAttemptFailed: true,
            lastAttemptAt: at(8, 4, hour: 12).addingTimeInterval(-600)
        ))
    }

    // MARK: Which failures are even allowed to retry

    @Test("transient failures are retryable, deterministic ones are not")
    func retryabilityByErrorKind() {
        #expect(InsightsError.generationFailed("no network").isRetryable)
        // A 4xx and an unparseable answer both fail identically on identical
        // input, and the parse case has already been billed.
        #expect(!InsightsError.requestRejected("Narration turned down this request (400).").isRetryable)
        #expect(!InsightsError.requestRejected("Couldn't read the analysis.").isRetryable)
        #expect(!InsightsError.notEnoughData.isRetryable)
    }
}
