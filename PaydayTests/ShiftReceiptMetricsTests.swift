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

    @Test("delete undo snapshot preserves receipt metrics")
    func undoSnapshotPreservesMetrics() {
        let entry = TipEntry(date: .now, amountCents: 2_400, kind: .credit, receiptMetrics: metrics)

        let restored = DeletedTipSnapshot(entry: entry).restored()

        #expect(restored.receiptMetrics == metrics)
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
}
