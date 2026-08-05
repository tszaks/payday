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

/// Counts in prose are spelled; digits belong to money and clock times. The
/// sentence that forced the rule read "Only 5 5PM starts to compare against
/// so far," where a count digit butted straight against a time digit.
@Suite("Number words")
struct NumberWordsTests {
    @Test("small counts spell out")
    func spellsSmallCounts() {
        #expect(NumberWords.spell(1) == "one")
        #expect(NumberWords.spell(5) == "five")
        #expect(NumberWords.spell(24) == "twenty-four")
    }

    @Test("above the ceiling, digits read better than words")
    func digitsAboveCeiling() {
        #expect(NumberWords.spell(100) == "100")
        #expect(NumberWords.spell(143) == "143")
    }

    @Test("negatives fall back to digits rather than producing prose")
    func negativeFallsBack() {
        #expect(NumberWords.spell(-3) == "-3")
    }

    @Test("phrase pluralizes on the count, not the spelling")
    func phrasePluralizes() {
        #expect(NumberWords.phrase(1, singular: "shift", plural: "shifts") == "one shift")
        #expect(NumberWords.phrase(5, singular: "shift", plural: "shifts") == "five shifts")
        #expect(NumberWords.phrase(0, singular: "shift", plural: "shifts") == "zero shifts")
    }

    @Test("a count never lands adjacent to a clock time as two digits")
    func noDigitCollisionWithClockTime() {
        // The exact regression: five 5 PM starts.
        let phrase = "Only \(NumberWords.phrase(5, singular: "5 PM start", plural: "5 PM starts")) to compare against so far."
        #expect(phrase == "Only five 5 PM starts to compare against so far.")
        #expect(!phrase.contains("5 5"))
    }
}

/// Notes age out of narration on their own clock, much shorter than the
/// 180-day facts window. A Toast-error note from July 17 was still the
/// highest-priority thing narration could say on August 5.
@Suite("Insights note recency")
struct InsightsNoteRecencyTests {
    private func record(_ day: Int, note: String?, cents: Int = 20000) -> TipRecord {
        TipRecord(
            date: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: day))!,
            amountCents: cents,
            kind: .credit,
            isDouble: false,
            shiftID: UUID(),
            note: note
        )
    }

    @Test("a note older than the window is dropped, its shift still counted")
    func staleNoteDropped() {
        // Aug 5 reference: Jul 17 is 19 days back (inside), Jun 20 is 46 (outside).
        let asOf = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 8, day: 5))!
        var records = (10...20).map { record($0, note: nil) }
        records.append(record(17, note: "Toast error carried lunch tips into dinner"))
        let facts = StatsEngine(records: records).insightsFacts(referenceDate: asOf)
        #expect(facts != nil)
        #expect(facts?.notes.contains { $0.text.contains("Toast") } == true)

        // Same note, now beyond the 30-day note window.
        let laterAsOf = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let laterFacts = StatsEngine(records: records).insightsFacts(referenceDate: laterAsOf)
        #expect(laterFacts?.notes.isEmpty == true)
        // The shifts themselves are still inside the 180-day facts window.
        #expect(laterFacts?.shiftCount == records.count)
    }
}
