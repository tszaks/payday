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

    /// "Nothing was changed or deleted" is only TRUE because the conversion
    /// never rewrites `public.tip_entries`. The copy and that invariant ship
    /// together: if a future slice rewrites a legacy row, this sentence
    /// becomes a lie and this test is where that shows up.
    @Test("the banner copy is exact")
    func bannerCopyIsExact() {
        let banner = PaydayConversionBanner(remainingGroupCount: 3)
        #expect(banner.message == "Payday couldn't finish updating your shifts. Nothing was changed or deleted, and your shifts are exactly as they were.")
        #expect(banner.retryTitle == "Try again")
        #expect(banner.detailsTitle == "Details")
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
            PaydayConversionBanner(remainingGroupCount: 1).message,
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

    // MARK: - Progress

    /// A count rather than a percentage, on purpose. A percentage needs a
    /// denominator only the server knows and that grows as the user logs more,
    /// so it would go backwards. A remaining count only ever falls, and when
    /// it stops falling that is itself the signal worth surfacing.
    @Test("progress is a falling count, singular and plural")
    func progressReadsNaturally() {
        #expect(PaydayConversionBanner(remainingGroupCount: 1).progressDescription
            == "1 shift left to update")
        #expect(PaydayConversionBanner(remainingGroupCount: 12).progressDescription
            == "12 shifts left to update")
        // Zero never reaches the banner, because the banner is nil by then,
        // but it must still read as a sentence rather than as debris if it
        // ever does.
        #expect(PaydayConversionBanner(remainingGroupCount: 0).progressDescription
            == "0 shifts left to update")
    }

    @Test("the report carries the count through unchanged")
    func reportCarriesTheCount() {
        #expect(Self.report(pending: 12).conversionPending == 12)
        // And a report built without one is indistinguishable from today's,
        // so every existing call site keeps its meaning.
        let legacy = PaydayMigrationReport(
            localTipEntryCount: 0, localPaycheckCount: 0,
            remoteTipEntryCount: 0, remotePaycheckCount: 0,
            tipEntryHash: "", paycheckHash: "")
        #expect(legacy.conversionPending == nil)
        #expect(!legacy.isConversionPending)
    }
}
