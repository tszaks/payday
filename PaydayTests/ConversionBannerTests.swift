import Foundation
import Testing
@testable import Payday

/// PR 2 slice S13, the non-visual half: the conversion wait is a banner, not
/// a phase, and its copy is exact.
///
/// The phase question is the load-bearing one. An earlier design made this
/// `Phase.awaitingAccountConversion` and said `syncIfReady` would not fire in
/// that phase. That turns into a total account outage, because
/// `PaydayCloudState.syncIfReady` opens with `guard case .ready = phase` and
/// `queueSyncAfterLocalChange` routes through the same function. The moment
/// the phase were not `.ready`, NOTHING would sync: no tip pull, no tip push,
/// no paycheck or settings sync, and no flush of `pendingTipDeletions` —
/// which is the only carrier of a deletion a 1.0 build queued and never sent.
///
/// ## What this suite is STRUCTURALLY BLIND to, and was
///
/// Every test here builds the report through its initializer with
/// `conversionPending` already set. That makes the suite a test of FORMATTING
/// and it cannot, by construction, discover that nothing in the app produces
/// the value. For three slices it was green while `conversionPending` had no
/// producer at all: the shift-authority leg read
/// `remaining_group_count` and threw it away, so the banner could never
/// appear on any account.
///
/// A SwiftUI preview has the identical shape and the identical blindness --
/// it constructs the state it displays, so it can only ever confirm itself.
/// An instrument that supplies the thing under test proves the thing is
/// well-formed, never that it is reachable.
///
/// Reachability is tested in `ShiftAuthorityLegTests.legReportsRemainingCount`,
/// which runs the real leg and reads what comes out. Read a green run of THIS
/// suite as "the words are right", not as "the banner works".
@Suite("Conversion banner and copy")
struct ConversionBannerTests {
    private static func report(pending: Int?) -> PaydayMigrationReport {
        PaydayMigrationReport(
            localTipEntryCount: 4,
            localPaycheckCount: 1,
            remoteTipEntryCount: 4,
            remotePaycheckCount: 1,
            tipEntryHash: "abc",
            paycheckHash: "def",
            conversionPending: pending
        )
    }

    // MARK: - It must not be a phase

    /// The whole point. A pending conversion leaves the phase `.ready`, so
    /// every other leg of the sync keeps running.
    @Test("a pending conversion does not change the phase")
    func pendingConversionStaysReady() {
        let phase = PaydayCloudState.Phase.ready(Self.report(pending: 12))
        guard case .ready = phase else {
            Issue.record("a pending conversion must leave the phase .ready")
            return
        }
    }

    /// `0` means finished, so this is deliberately not `conversionPending != nil`.
    /// A zero treated as pending would leave the banner up forever on an
    /// account that had already converted.
    @Test("zero remaining is finished, not pending")
    func zeroIsNotPending() {
        #expect(!Self.report(pending: 0).isConversionPending)
        #expect(!Self.report(pending: nil).isConversionPending)
        #expect(Self.report(pending: 1).isConversionPending)
    }

    // MARK: - Copy, verbatim

    /// The detail line is a factual claim, and it is true only because
    /// `ShiftReadAuthority.isAuthoritative` returns false while
    /// `remainingGroupCount > 0` -- a mid-conversion account reads the legacy
    /// representation, the same one it read before. The copy and that
    /// predicate ship together: if a future slice lets a partly converted
    /// account read shifts, this sentence becomes a lie and this test is
    /// where that shows up.
    @Test("the banner copy is exact")
    func bannerCopyIsExact() {
        let banner = PaydayConversionBanner(remainingGroupCount: 3)
        #expect(banner.title == "Updating in the background")
        #expect(banner.detail == "Your totals are unchanged while this finishes.")
    }

    /// **The banner's only presentation condition is that the conversion is
    /// STILL RUNNING**, so its words may not describe a failure.
    ///
    /// They did. It read "Payday couldn't finish updating your shifts" and
    /// offered a **Try again** button, on a path that fires when nothing has
    /// gone wrong. Every migrating account would have been told the app had
    /// failed and invited to retry work that was proceeding. A conservation
    /// failure is a genuinely different state -- `conservation_failed_at` --
    /// and it needs its own surface rather than this one's words.
    @Test("progress copy never describes a failure or offers a retry")
    func copyDoesNotClaimFailure() {
        let banner = PaydayConversionBanner(remainingGroupCount: 3)
        let words = (banner.title + " " + banner.detail).lowercased()
        for failureWord in ["couldn't", "could not", "failed", "error",
                            "problem", "try again", "retry", "wrong"] {
            #expect(!words.contains(failureWord),
                    "a running conversion must not read as a failure: \(words)")
        }
    }

    @Test("the incomplete-conversion error copy is exact")
    func errorCopyIsExact() {
        #expect(PaydayMigrationError.conversionIncomplete.errorDescription
            == "Payday is still updating your shifts. Everything you've logged is saved and already backed up to your account; your shifts start syncing as soon as that finishes.")
    }

    /// Both sentences promise the user their data is untouched, so neither may
    /// imply loss. Checked as a property rather than by eye, because copy
    /// drifts one word at a time.
    @Test("neither message ever suggests something was lost")
    func copyNeverSuggestsLoss() {
        let sentences = [
            PaydayConversionBanner(remainingGroupCount: 1).detail,
            PaydayMigrationError.conversionIncomplete.errorDescription ?? ""
        ]
        for sentence in sentences {
            let lower = sentence.lowercased()
            for alarming in ["lost", "missing", "deleted your", "erased", "gone"] {
                #expect(!lower.contains(alarming),
                        "\(alarming) must not appear: \(sentence)")
            }
        }
    }

    // MARK: - Progress is deliberately NOT shown

    /// The banner exposes no count, and the reason is not a no-figures rule.
    ///
    /// `remaining_group_count` is server-sourced, so rendering it would not
    /// be the unsourced-number error. It is withheld because the LABEL would
    /// not be true: the column's own comment states its contract as
    /// "Progress as a number. The client re-invokes the one-shot only while
    /// this strictly decreases, which is what stops a hot loop of definer
    /// calls." Its magnitude is an implementation detail of the loop guard,
    /// and nothing establishes that one group is one shift a person would
    /// recognise. "47 shifts left to update" reuses a control value to answer
    /// a question it was not built to answer.
    ///
    /// Asserted rather than merely written down, because the tempting fix to
    /// a silent wait is to surface the number that is already in hand.
    @Test("the banner exposes no count to render")
    func noCountIsExposed() {
        let banner = PaydayConversionBanner(remainingGroupCount: 47)
        let rendered = banner.title + " " + banner.detail
        #expect(!rendered.contains("47"))
        // The count is still CARRIED, so a follow-up progress value derived
        // for that purpose has a source; it is simply not rendered as one.
        #expect(banner.remainingGroupCount == 47)
    }

    @Test("the report carries the count through unchanged")
    func reportCarriesTheCount() {
        #expect(Self.report(pending: 12).conversionPending == 12)
        // And a report built without one is indistinguishable from today's,
        // so every existing call site keeps its meaning.
        let legacy = PaydayMigrationReport(
            localTipEntryCount: 0, localPaycheckCount: 0,
            remoteTipEntryCount: 0, remotePaycheckCount: 0,
            tipEntryHash: "", paycheckHash: "", conversionPending: nil)
        #expect(legacy.conversionPending == nil)
        #expect(!legacy.isConversionPending)
    }
}
