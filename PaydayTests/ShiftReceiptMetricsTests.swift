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
}
