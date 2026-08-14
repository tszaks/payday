import Foundation
import Testing
@testable import Payday

@Suite("ReceiptAIParser")
struct ReceiptAIParserTests {
    @Test("decodes shift fields in dollars into cents")
    func decodesShiftFields() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":100.50,\"credit_tips\":300.25,\"tip_out\":25,\"sales\":2200,\"server_count\":4,\"guest_count\":12,\"credit_check_count\":6,\"table_count\":5,\"net_sales\":2050,\"tax\":150,\"printed_tip_percent\":19.54,\"average_spend_per_guest\":170.83,\"cash_sales\":40,\"gratuity_fees\":0,\"category_sales\":[{\"name\":\"Kitchen\",\"quantity\":8,\"net_sales\":1100}],\"tip_sharing\":[{\"role\":\"Busser\",\"amount\":12.50}],\"shift_date\":\"2026-07-21\",\"clock_in\":\"10:31\",\"clock_out\":\"13:21\"}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.cashTipsCents == 10_050)
        #expect(parsed.creditTipsCents == 30_025)
        #expect(parsed.tipOutCents == 2_500)
        #expect(parsed.salesCents == 220_000)
        #expect(parsed.serverCount == 4)
        #expect(parsed.guestCount == 12)
        #expect(parsed.creditCheckCount == 6)
        #expect(parsed.tableCount == 5)
        #expect(parsed.tableCountSource == .printed)
        #expect(parsed.netSalesCents == 205_000)
        #expect(parsed.taxCents == 15_000)
        #expect(parsed.printedTipPercentHundredths == 1_954)
        #expect(parsed.averageSpendPerGuestCents == 17_083)
        #expect(parsed.cashSalesCents == 4_000)
        #expect(parsed.gratuityFeesCents == 0)
        #expect(parsed.categorySales == [.init(name: "Kitchen", quantity: 8, netSalesCents: 110_000)])
        #expect(parsed.tipSharing == [.init(role: "Busser", amountCents: 1_250)])
        #expect(parsed.shiftDate == .init(year: 2026, month: 7, day: 21))
        #expect(parsed.clockIn == .init(hour: 10, minute: 31))
        #expect(parsed.clockOut == .init(hour: 13, minute: 21))
        #expect(parsed.filledFieldCount == 10)
    }

    @Test("keeps explicitly missing values empty")
    func keepsMissingValuesEmpty() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":null,\"credit_tips\":75,\"tip_out\":null,\"sales\":null,\"server_count\":null,\"guest_count\":null,\"credit_check_count\":null,\"table_count\":null,\"net_sales\":null,\"tax\":null,\"printed_tip_percent\":null,\"average_spend_per_guest\":null,\"cash_sales\":null,\"gratuity_fees\":null,\"category_sales\":[],\"tip_sharing\":[],\"shift_date\":null,\"clock_in\":null,\"clock_out\":null}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.cashTipsCents == nil)
        #expect(parsed.creditTipsCents == 7_500)
        #expect(parsed.tipOutCents == nil)
        #expect(parsed.salesCents == nil)
        #expect(parsed.serverCount == nil)
        #expect(parsed.receiptMetrics == nil)
        #expect(parsed.shiftDate == nil)
        #expect(parsed.clockIn == nil)
        #expect(parsed.clockOut == nil)
        #expect(parsed.filledFieldCount == 1)
    }

    @Test("decodes the verified shift review summary result")
    func decodesVerifiedShiftReviewSummary() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":null,\"credit_tips\":24.0,\"tip_out\":3.21,\"sales\":124.06,\"server_count\":null,\"guest_count\":4,\"credit_check_count\":2,\"table_count\":null,\"net_sales\":118,\"tax\":6.06,\"printed_tip_percent\":20.3,\"average_spend_per_guest\":29.5,\"cash_sales\":0,\"gratuity_fees\":0,\"category_sales\":[{\"name\":\"Kitchen\",\"quantity\":4,\"net_sales\":55},{\"name\":\"Liquor\",\"quantity\":1,\"net_sales\":17},{\"name\":\"NA Beverage\",\"quantity\":1,\"net_sales\":8},{\"name\":\"Sushi\",\"quantity\":5,\"net_sales\":38}],\"tip_sharing\":[{\"role\":\"Busser - 1% of Kitchen, Liquor, NA Beverage, Sushi\",\"amount\":1.18},{\"role\":\"Bartender - 5% of Liquor\",\"amount\":0.85}],\"shift_date\":\"2026-07-21\",\"clock_in\":\"10:31\",\"clock_out\":\"13:21\"}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.cashTipsCents == nil)
        #expect(parsed.creditTipsCents == 2_400)
        #expect(parsed.tipOutCents == 321)
        #expect(parsed.salesCents == 12_406)
        #expect(parsed.serverCount == nil)
        #expect(parsed.guestCount == 4)
        #expect(parsed.creditCheckCount == 2)
        #expect(parsed.printedTableCount == nil)
        #expect(parsed.tableCount == 2)
        #expect(parsed.tableCountSource == .inferredFromChecks)
        #expect(parsed.netSalesCents == 11_800)
        #expect(parsed.taxCents == 606)
        #expect(parsed.printedTipPercentHundredths == 2_030)
        #expect(parsed.averageSpendPerGuestCents == 2_950)
        #expect(parsed.cashSalesCents == 0)
        #expect(parsed.gratuityFeesCents == 0)
        #expect(parsed.categorySales.count == 4)
        #expect(parsed.tipSharing.count == 2)
        #expect(parsed.receiptMetrics?.tableCountSource == .inferredFromChecks)
        #expect(parsed.shiftDate == .init(year: 2026, month: 7, day: 21))
        #expect(parsed.clockIn == .init(hour: 10, minute: 31))
        #expect(parsed.clockOut == .init(hour: 13, minute: 21))
    }

    @Test("rejects malformed dates and times")
    func rejectsMalformedDateAndTime() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":null,\"credit_tips\":24,\"tip_out\":3.21,\"sales\":124.06,\"server_count\":null,\"guest_count\":null,\"credit_check_count\":null,\"table_count\":null,\"net_sales\":null,\"tax\":null,\"printed_tip_percent\":null,\"average_spend_per_guest\":null,\"cash_sales\":null,\"gratuity_fees\":null,\"category_sales\":[],\"tip_sharing\":[],\"shift_date\":\"2026-19-42\",\"clock_in\":\"25:00\",\"clock_out\":\"13:99\"}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.shiftDate == nil)
        #expect(parsed.clockIn == nil)
        #expect(parsed.clockOut == nil)
    }

    @Test("does not infer tables when cash checks may be missing")
    func avoidsUnsafeTableInference() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":null,\"credit_tips\":24,\"tip_out\":null,\"sales\":124.06,\"server_count\":null,\"guest_count\":4,\"credit_check_count\":2,\"table_count\":null,\"net_sales\":118,\"tax\":6.06,\"printed_tip_percent\":null,\"average_spend_per_guest\":29.5,\"cash_sales\":20,\"gratuity_fees\":0,\"category_sales\":[],\"tip_sharing\":[],\"shift_date\":null,\"clock_in\":null,\"clock_out\":null}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.creditCheckCount == 2)
        #expect(parsed.tableCount == nil)
        #expect(parsed.tableCountSource == nil)
    }

    @Test("reports exhausted API credits with an actionable message")
    func reportsExhaustedCredits() {
        let response = Data(#"{"error":{"type":"insufficient_quota","code":"credit_balance_exhausted"}}"#.utf8)

        let error = ReceiptAIParser.requestError(statusCode: 429, responseData: response)

        #expect(error.errorDescription == "Receipt analysis credits have run out. Add API credits, then try again.")
    }

    @Test("keeps unrelated HTTP failures generic")
    func keepsOtherRequestFailuresGeneric() {
        let error = ReceiptAIParser.requestError(statusCode: 503, responseData: Data())

        #expect(error.errorDescription == "Receipt analysis is temporarily unavailable.")
    }
}
