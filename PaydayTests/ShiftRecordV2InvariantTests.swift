import Foundation
import Testing
@testable import Payday

/// **One absent field must not read as two generations.**
///
/// `ShiftRecord` stores v2 earnings by invariant and its own
/// `nonWageEarningsCents` reads the fields RAW on that basis. But the
/// setter's assert used to spell that invariant `(version ?? 2) >= 2`, so a
/// payload with NO `earningsSchemaVersion` satisfied it -- while
/// `ShiftReceiptMetrics` reads the same missing key as `(version ?? 1)` and
/// folds a gratuity out of amounts that never contained one.
///
/// Measured, on a record built directly rather than through a writer:
/// `ShiftRecord.nonWageEarningsCents` and the `StatsRecordAdapter` path
/// differed by exactly the gratuity -- 300c, and 100c where the fold's
/// `max(0,)` clamped.
///
/// **No sanctioned writer produces that state**, which is why this is a
/// hazard rather than a live defect, and why the fix belongs here rather
/// than downstream. The SQL deriver folds THEN stamps
/// (`greatest(0, amount_cents - owner_gratuity_cents)`, then
/// `jsonb_set('{earningsSchemaVersion}', '2')`), and `applyEarnings` goes
/// through `normalizedToV2`, which does both and is idempotent.
///
/// Relabelling a payload downstream without subtracting the folded gratuity
/// double-counts that money permanently. `design-lint` refuses it, and it
/// refused exactly that attempt.
@Suite("ShiftRecord v2 invariant")
struct ShiftRecordV2InvariantTests {

    private func metrics(version: Int?, gratuity: Int = 300) -> ShiftReceiptMetrics {
        var m = ShiftReceiptMetrics()
        m.earningsSchemaVersion = version
        m.gratuityFeesCents = gratuity
        return m
    }

    @Test("a present payload with NO version is not v2")
    func absentVersionIsRejected() {
        #expect(ShiftRecord.storesV2Earnings(metrics(version: nil)) == false)
    }

    @Test("an explicit v1 payload is not v2")
    func v1IsRejected() {
        #expect(ShiftRecord.storesV2Earnings(metrics(version: 1)) == false)
    }

    @Test("a v2 payload, and anything later, is accepted")
    func v2AndLaterAccepted() {
        #expect(ShiftRecord.storesV2Earnings(metrics(version: 2)))
        #expect(ShiftRecord.storesV2Earnings(metrics(version: 3)))
    }

    /// Clearing is how a payload is REMOVED, and the first draft of the
    /// tightened assert broke it: `nil?.version ?? 0` fails `>= 2` where the
    /// old `?? 2` passed. It took out six tests, four of them in
    /// `ShiftReconcileTests` where a remote row simply had no receipt.
    @Test("clearing the payload to nil stays legal")
    func nilIsAccepted() {
        #expect(ShiftRecord.storesV2Earnings(nil))
    }
}
