import Foundation
import Testing
@testable import Payday

@Suite("ReceiptAIParser")
struct ReceiptAIParserTests {
    @Test("decodes shift fields in dollars into cents")
    func decodesShiftFields() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":100.50,\"credit_tips\":300.25,\"tip_out\":25,\"sales\":2200,\"server_count\":4}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.cashTipsCents == 10_050)
        #expect(parsed.creditTipsCents == 30_025)
        #expect(parsed.tipOutCents == 2_500)
        #expect(parsed.salesCents == 220_000)
        #expect(parsed.serverCount == 4)
        #expect(parsed.filledFieldCount == 5)
    }

    @Test("keeps explicitly missing values empty")
    func keepsMissingValuesEmpty() throws {
        let response = Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cash_tips\":null,\"credit_tips\":75,\"tip_out\":null,\"sales\":null,\"server_count\":null}"}]}]}"#.utf8)

        let parsed = try ReceiptAIParser.parse(responseData: response)

        #expect(parsed.cashTipsCents == nil)
        #expect(parsed.creditTipsCents == 7_500)
        #expect(parsed.tipOutCents == nil)
        #expect(parsed.salesCents == nil)
        #expect(parsed.serverCount == nil)
        #expect(parsed.filledFieldCount == 1)
    }
}
