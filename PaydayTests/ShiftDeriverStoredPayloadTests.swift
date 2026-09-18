import Foundation
import Testing
@testable import Payday

/// The device half of one SQL guarantee: every receipt payload
/// `private.derive_shifts` can STORE in `public.shifts.receipt_metrics`
/// decodes as `ShiftReceiptMetrics`.
///
/// `ShiftRecord.receiptPayloadIsUnreadable` is load-bearing:
/// `shifts.gratuity_fees_cents` is a generated column, so a nil-metrics getter
/// feeding `applyEarnings` would zero the gratuity locally and push that zero
/// over the server's value. Such a record is excluded from the sync push set
/// and shown in Data health forever, because the server keeps re-folding the
/// same payload. So a payload the fold stores but the device cannot read is a
/// permanent, silent defect rather than a crash — which is exactly why the
/// fold sanitizes `earningsSchemaVersion` and `gratuityFeesCents` through
/// integer-valued helpers instead of copying the scanner's value through.
///
/// The literals below are the same eight payloads
/// `supabase/tests/shift_deriver_test.sql` pins as the COMPLETE set its
/// fixtures produce (assertion
/// `theStoredPayloadSetIsExactlyWhatTheSwiftDecoderTestCarries`). Neither side
/// re-derives and neither trusts the other's code: job E asserts the fold
/// stores exactly these, this suite asserts the device reads exactly these.
/// Change what the sanitizer writes and BOTH files fail, which is the point.
@Suite("Deriver stored payloads")
struct ShiftDeriverStoredPayloadTests {
    /// Byte-for-byte the `receipt_metrics` values the SQL suite pins, in its
    /// text-sorted order.
    private static let storedPayloads: [String] = [
        #"{"gratuityFeesCents": 0, "earningsSchemaVersion": 2}"#,
        #"{"gratuityFeesCents": 1000, "earningsSchemaVersion": 2}"#,
        #"{"gratuityFeesCents": 1234, "earningsSchemaVersion": 2}"#,
        #"{"gratuityFeesCents": 1235, "earningsSchemaVersion": 2}"#,
        #"{"gratuityFeesCents": 2000000, "earningsSchemaVersion": 2}"#,
        #"{"gratuityFeesCents": 2147483647, "earningsSchemaVersion": 2}"#,
        #"{"gratuityFeesCents": 4200, "earningsSchemaVersion": 2}"#,
        // N2's payload. Its v1 receipt is duplicated across BOTH rows of its
        // group, and the fold has to count the gratuity once and normalize the
        // credit once. Sorts before guestCount 42 because "40" < "42" by text.
        #"{"guestCount": 40, "netSalesCents": 80000, "creditCheckCount": 18, "gratuityFeesCents": 500, "earningsSchemaVersion": 2}"#,
        #"{"guestCount": 42, "gratuityFeesCents": 4200, "earningsSchemaVersion": 2}"#
    ]

    private func decode(_ json: String) -> ShiftReceiptMetrics? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ShiftReceiptMetrics.self, from: data)
    }

    @Test("every payload the fold can store decodes as ShiftReceiptMetrics",
          arguments: ShiftDeriverStoredPayloadTests.storedPayloads)
    func storedPayloadDecodes(_ json: String) {
        let decoded = decode(json)
        #expect(decoded != nil, "the fold stored a payload the device cannot read: \(json)")
        // v2 means the stored amounts are voluntary tips only and the gratuity
        // is a separate additive category, so the label has to survive the
        // round trip or the gratuity is counted twice or not at all.
        #expect(decoded?.earningsSchemaVersion == 2)
        #expect(decoded?.gratuityFeesCents != nil)
    }

    @Test("a stored payload carries the fold's integer gratuity unchanged")
    func gratuityValuesSurvive() {
        #expect(decode(Self.storedPayloads[0])?.gratuityFeesCents == 0)
        #expect(decode(Self.storedPayloads[3])?.gratuityFeesCents == 1_235)
        #expect(decode(Self.storedPayloads[5])?.gratuityFeesCents == 2_147_483_647)
        #expect(decode(Self.storedPayloads[7])?.guestCount == 40)
        #expect(decode(Self.storedPayloads[7])?.gratuityFeesCents == 500)
        #expect(decode(Self.storedPayloads[8])?.guestCount == 42)
    }

    @Test("a v2 stored payload is idempotent under normalizedToV2")
    func normalizingAStoredPayloadIsANoOp() {
        // The fold relabels to 2 precisely because it has already performed
        // the subtraction. If the device normalized such a payload again it
        // would subtract the gratuity twice, which is the whole reason
        // ShiftReceiptMetrics is the only file allowed to touch the version.
        let metrics = decode(Self.storedPayloads[6])
        #expect(metrics?.gratuityFeesCents == 4_200)
        let result = ShiftReceiptMetrics.normalizedToV2(
            cashCents: 5_000, creditCents: 0, metrics: metrics!, owner: .credit)
        #expect(result.cash == 5_000)
        #expect(result.credit == 0)
        #expect(result.metrics.earningsSchemaVersion == 2)
    }

    /// The counterexamples, which is what makes the sanitizer worth its cost.
    /// Each of these is legally storable in `public.tip_entries` today
    /// (`receipt_metrics` has no CHECK at all and `ReceiptAIParser` is an LLM
    /// scanner), and each fails to decode AS A WHOLE because
    /// `earningsSchemaVersion` and `gratuityFeesCents` are `Int?` — so one
    /// junk field does not degrade, it loses the entire receipt.
    @Test("the raw scanner payloads the fold rewrites would NOT decode",
          arguments: [
            #"{"gratuityFeesCents": true}"#,
            #"{"gratuityFeesCents": "42"}"#,
            #"{"gratuityFeesCents": 1234.6}"#,
            #"{"gratuityFeesCents": 1e30}"#,
            #"{"earningsSchemaVersion": "1", "gratuityFeesCents": 100}"#,
            #"{"earningsSchemaVersion": true, "gratuityFeesCents": 1000}"#
          ])
    func unsanitizedPayloadsFailToDecode(_ json: String) {
        #expect(decode(json) == nil, "this payload no longer needs sanitizing: \(json)")
    }

    /// The second, separate reason the sanitizer rewrites `gratuityFeesCents`:
    /// a magnitude that decodes perfectly well on a 64-bit device but does NOT
    /// fit `int4`, so the device would read one number while the server's
    /// generated column holds the clamped one. Rewriting the key through the
    /// same helper the fold's arithmetic used makes the stored payload and the
    /// generated column agree by construction.
    @Test("an out-of-int4-range gratuity decodes on device and would disagree with the server")
    func anOutOfRangeGratuityDecodesButDisagreesWithTheClampedColumn() {
        let raw = decode(#"{"gratuityFeesCents": 99999999999}"#)
        #expect(raw?.gratuityFeesCents == 99_999_999_999)
        #expect(raw?.gratuityFeesCents != 2_147_483_647)
        // What the fold actually stores for that input, and what the generated
        // column then computes, are the same clamped value.
        #expect(decode(Self.storedPayloads[5])?.gratuityFeesCents == 2_147_483_647)
    }
}
