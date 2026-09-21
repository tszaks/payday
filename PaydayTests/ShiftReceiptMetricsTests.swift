import Foundation
import Testing
@testable import Payday

@Suite("Shift receipt metrics")
struct ShiftReceiptMetricsTests {
    private let metrics = ShiftReceiptMetrics(
        guestCount: 4,
        creditCheckCount: 2,
        tableCount: 2,
        tableCountSource: .inferredFromChecks,
        netSalesCents: 11_800,
        taxCents: 606,
        printedTipPercentHundredths: 2_030,
        averageSpendPerGuestCents: 2_950,
        cashSalesCents: 0,
        gratuityFeesCents: 0,
        totalAmountCents: 14_806,
        categorySales: [
            .init(name: "Kitchen", quantity: 4, netSalesCents: 5_500),
            .init(name: "Sushi", quantity: 5, netSalesCents: 3_800)
        ],
        tipSharing: [
            .init(role: "Busser", amountCents: 118),
            .init(role: "Bartender", amountCents: 85)
        ]
    )

    @Test("round-trips through TipEntry's persisted JSON")
    func tipEntryJSONRoundTrip() {
        let entry = TipEntry(date: .now, amountCents: 2_400, kind: .credit, receiptMetrics: metrics)

        #expect(entry.receiptMetricsJSON != nil)
        #expect(entry.receiptMetrics == metrics)
    }

    @Test("empty metrics clear the persisted payload")
    func emptyMetricsClearPayload() {
        let entry = TipEntry(date: .now, amountCents: 2_400, kind: .credit, receiptMetrics: metrics)
        entry.receiptMetrics = ShiftReceiptMetrics()

        #expect(entry.receiptMetricsJSON == nil)
        #expect(entry.receiptMetrics == nil)
    }

    @Test("ShiftDetails keeps receipt metrics on the canonical credit row")
    func canonicalShiftStorage() {
        let cash = TipEntry(date: .now, amountCents: 500, kind: .cash, receiptMetrics: metrics)
        let credit = TipEntry(date: .now, amountCents: 2_400, kind: .credit)

        ShiftDetails.write(
            hoursWorked: 3,
            tipOutCents: 321,
            salesCents: 12_406,
            shiftPeriod: .lunch,
            receiptMetrics: metrics,
            into: [cash, credit]
        )

        #expect(credit.receiptMetrics == metrics)
        #expect(cash.receiptMetrics == nil)
        #expect(ShiftDetails.resolve(from: [cash, credit]).receiptMetrics == metrics)
    }

    @Test("the delete capture preserves receipt metrics")
    func deleteCapturePreservesMetrics() {
        let captured = ShiftCommands.DeletedShift(
            id: UUID(), workDate: .now, shiftPeriod: .dinner,
            cashTipsCents: 0, creditTipsCents: 2_400,
            tipOutCents: nil, salesCents: nil, hoursWorked: nil,
            clockIn: nil, clockOut: nil, serverCount: nil,
            receiptMetrics: metrics, note: nil, recordedAt: nil,
            source: .device, legacyEntryIDs: [], deletedAt: .now
        )

        #expect(captured.receiptMetrics == metrics)
    }

    @Test("a partial rescan updates known values without erasing prior facts")
    func partialRescanMergesMetrics() {
        let newer = ShiftReceiptMetrics(
            guestCount: 5,
            cashSalesCents: 0,
            categorySales: [.init(name: "Kitchen", quantity: 5, netSalesCents: 6_500)],
            tipSharing: [.init(role: "Busser", amountCents: 125)]
        )

        let merged = metrics.merging(newer)

        #expect(merged.guestCount == 5)
        #expect(merged.taxCents == 606)
        #expect(merged.totalAmountCents == 14_806)
        #expect(merged.categorySales == [
            .init(name: "Kitchen", quantity: 5, netSalesCents: 6_500),
            .init(name: "Sushi", quantity: 5, netSalesCents: 3_800)
        ])
        #expect(merged.tipSharing == [
            .init(role: "Busser", amountCents: 125),
            .init(role: "Bartender", amountCents: 85)
        ])
        #expect(merged.cashSalesCents == 0)
    }

    @Test("a rescan with cash sales clears a prior check-based table estimate")
    func cashSalesInvalidateInferredTables() {
        let merged = metrics.merging(ShiftReceiptMetrics(cashSalesCents: 2_000))

        #expect(merged.cashSalesCents == 2_000)
        #expect(merged.tableCount == nil)
        #expect(merged.tableCountSource == nil)
    }

    @Test("legacy receipt JSON never starts double-counting captured gratuity")
    func legacyJSONKeepsGratuityNonAdditive() throws {
        let legacy = Data(#"{"gratuityFeesCents":4050}"#.utf8)
        let decoded = try JSONDecoder().decode(ShiftReceiptMetrics.self, from: legacy)

        #expect(decoded.gratuityFeesCents == 4_050)
        #expect(decoded.earningsSchemaVersion == nil)
        #expect(decoded.separatedGratuityFeesCents == 0)
        #expect(decoded.voluntaryTipsCents(fromStoredAmount: 16_186) == 12_136)
        #expect(decoded.employeeEarningsCents(fromStoredAmount: 16_186) == 16_186)
    }

    @Test("v2 receipt JSON adds gratuity as its own earnings category")
    func versionTwoMakesGratuityAdditive() {
        let metrics = ShiftReceiptMetrics(
            earningsSchemaVersion: 2,
            gratuityFeesCents: 4_050
        )

        #expect(metrics.separatedGratuityFeesCents == 4_050)
    }

    // MARK: - normalizedToV2

    /// The N4 shape: cash 5000, credit 2000, and a v1 receipt on the CREDIT
    /// row carrying a folded gratuity of 4200 that the credit amount is short
    /// of. The read path gives cash 5000 / credit 0 / gratuity 4200 /
    /// non-wage 8200 (with a tip-out of 1000).
    @Test("normalizedToV2 on N4 reproduces the read path, not the edit path")
    func normalizedToV2MatchesTheReadPathOnN4() {
        let v1 = ShiftReceiptMetrics(earningsSchemaVersion: nil, gratuityFeesCents: 4_200)

        let result = ShiftReceiptMetrics.normalizedToV2(
            cashCents: 5_000,
            creditCents: 2_000,
            metrics: v1,
            owner: .credit
        )

        #expect(result.cash == 5_000)
        #expect(result.credit == 0)
        #expect(result.metrics.earningsSchemaVersion == 2)
        #expect(result.metrics.employeeGratuityFeesCents == 4_200)
        // cash + credit + gratuity - tip-out
        #expect(result.cash + result.credit + result.metrics.employeeGratuityFeesCents - 1_000 == 8_200)

        // The edit path's rule would have produced 800 / 2000 / 4200 / 6000
        // on this same shift: $22.00 less, and a different cash-versus-credit
        // split, which is the number the paycheck comparison runs on.
        #expect(result.cash != 800)
        #expect(result.credit != 2_000)
    }

    @Test("the owner decides which amount the folded gratuity comes out of")
    func theOwnerDecidesWhichAmountIsReduced() {
        let v1 = ShiftReceiptMetrics(earningsSchemaVersion: nil, gratuityFeesCents: 4_200)

        let creditOwned = ShiftReceiptMetrics.normalizedToV2(
            cashCents: 5_000, creditCents: 2_000, metrics: v1, owner: .credit
        )
        #expect(creditOwned.cash == 5_000)
        #expect(creditOwned.credit == 0)

        let cashOwned = ShiftReceiptMetrics.normalizedToV2(
            cashCents: 5_000, creditCents: 2_000, metrics: v1, owner: .cash
        )
        #expect(cashOwned.cash == 800)
        #expect(cashOwned.credit == 2_000)
    }

    @Test("normalizedToV2 is idempotent")
    func normalizedToV2IsIdempotent() {
        let v1 = ShiftReceiptMetrics(earningsSchemaVersion: nil, gratuityFeesCents: 4_200)

        let once = ShiftReceiptMetrics.normalizedToV2(
            cashCents: 5_000, creditCents: 2_000, metrics: v1, owner: .credit
        )
        let twice = ShiftReceiptMetrics.normalizedToV2(
            cashCents: once.cash, creditCents: once.credit, metrics: once.metrics, owner: .credit
        )
        let thrice = ShiftReceiptMetrics.normalizedToV2(
            cashCents: twice.cash, creditCents: twice.credit, metrics: twice.metrics, owner: .credit
        )

        #expect(twice.cash == once.cash)
        #expect(twice.credit == once.credit)
        #expect(twice.metrics == once.metrics)
        #expect(thrice.cash == once.cash)
        #expect(thrice.credit == once.credit)
        #expect(thrice.metrics == once.metrics)
    }

    @Test("a payload already labelled v2 is returned untouched")
    func versionTwoInputIsReturnedUntouched() {
        let v2 = ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: 4_200)

        let result = ShiftReceiptMetrics.normalizedToV2(
            cashCents: 5_000, creditCents: 2_000, metrics: v2, owner: .credit
        )

        #expect(result.cash == 5_000)
        #expect(result.credit == 2_000)
        #expect(result.metrics == v2)
    }

    @Test("an absent earningsSchemaVersion is treated as v1, because that is live data")
    func anAbsentVersionIsTreatedAsV1() throws {
        // ReceiptAIParser writes `earningsSchemaVersion: creditTipsCents != nil
        // ? 2 : nil`, and older scans never wrote the key at all, so this
        // payload shape is in production stores right now.
        let stored = Data(#"{"gratuityFeesCents":4200}"#.utf8)
        let metrics = try JSONDecoder().decode(ShiftReceiptMetrics.self, from: stored)
        #expect(metrics.earningsSchemaVersion == nil)

        let result = ShiftReceiptMetrics.normalizedToV2(
            cashCents: 5_000, creditCents: 2_000, metrics: metrics, owner: .credit
        )

        #expect(result.credit == 0)
        #expect(result.metrics.earningsSchemaVersion == 2)
    }

    @Test("the subtraction floors at zero rather than going negative")
    func theSubtractionFloorsAtZero() {
        let v1 = ShiftReceiptMetrics(earningsSchemaVersion: nil, gratuityFeesCents: 9_999)

        let result = ShiftReceiptMetrics.normalizedToV2(
            cashCents: 100, creditCents: 0, metrics: v1, owner: .cash
        )

        #expect(result.cash == 0)
        #expect(result.credit == 0)
    }

    @Test("a v1 payload with no gratuity moves nothing but is still relabelled")
    func aV1PayloadWithNoGratuityMovesNothing() {
        let v1 = ShiftReceiptMetrics(earningsSchemaVersion: nil, netSalesCents: 11_800)

        let result = ShiftReceiptMetrics.normalizedToV2(
            cashCents: 5_000, creditCents: 2_000, metrics: v1, owner: .credit
        )

        #expect(result.cash == 5_000)
        #expect(result.credit == 2_000)
        #expect(result.metrics.earningsSchemaVersion == 2)
        #expect(result.metrics.netSalesCents == 11_800)
    }
}
