import Foundation
import Testing
@testable import Payday

@Suite("ReceiptAIParser")
struct ReceiptAIParserTests {
    @Test("decodes shift fields in dollars into cents")
    func decodesShiftFields() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":100.50,\"credit_tips\":300.25,\"tip_out\":25,\"sales\":2200,\"server_count\":4,\"shift_date\":\"2026-07-21\",\"clock_in\":\"10:31\",\"clock_out\":\"13:21\"}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.cashTipsCents == 10_050)
        #expect(parsed.creditTipsCents == 30_025)
        #expect(parsed.tipOutCents == 2_500)
        #expect(parsed.salesCents == 220_000)
        #expect(parsed.serverCount == 4)
        #expect(parsed.shiftDate == .init(year: 2026, month: 7, day: 21))
        #expect(parsed.clockIn == .init(hour: 10, minute: 31))
        #expect(parsed.clockOut == .init(hour: 13, minute: 21))
        #expect(parsed.filledFieldCount == 8)
    }

    @Test("keeps explicitly missing values empty")
    func keepsMissingValuesEmpty() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":null,\"credit_tips\":75,\"tip_out\":null,\"sales\":null,\"server_count\":null,\"shift_date\":null,\"clock_in\":null,\"clock_out\":null}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.cashTipsCents == nil)
        #expect(parsed.creditTipsCents == 7_500)
        #expect(parsed.tipOutCents == nil)
        #expect(parsed.salesCents == nil)
        #expect(parsed.serverCount == nil)
        #expect(parsed.shiftDate == nil)
        #expect(parsed.clockIn == nil)
        #expect(parsed.clockOut == nil)
        #expect(parsed.filledFieldCount == 1)
    }

    @Test("decodes the verified shift review summary result")
    func decodesVerifiedShiftReviewSummary() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":null,\"credit_tips\":24.0,\"tip_out\":3.21,\"sales\":124.06,\"server_count\":null,\"shift_date\":\"2026-07-21\",\"clock_in\":\"10:31\",\"clock_out\":\"13:21\"}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.cashTipsCents == nil)
        #expect(parsed.creditTipsCents == 2_400)
        #expect(parsed.tipOutCents == 321)
        #expect(parsed.salesCents == 12_406)
        #expect(parsed.serverCount == nil)
        #expect(parsed.shiftDate == .init(year: 2026, month: 7, day: 21))
        #expect(parsed.clockIn == .init(hour: 10, minute: 31))
        #expect(parsed.clockOut == .init(hour: 13, minute: 21))
    }

    @Test("rejects malformed dates and times")
    func rejectsMalformedDateAndTime() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":null,\"credit_tips\":24,\"tip_out\":3.21,\"sales\":124.06,\"server_count\":null,\"shift_date\":\"2026-19-42\",\"clock_in\":\"25:00\",\"clock_out\":\"13:99\"}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.shiftDate == nil)
        #expect(parsed.clockIn == nil)
        #expect(parsed.clockOut == nil)
    }
}
