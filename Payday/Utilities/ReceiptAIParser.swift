import Foundation
import UIKit

/// Reads a restaurant shift closeout receipt and returns only the fields that
/// are explicitly printed on that receipt. This is intentionally separate
/// from PaycheckAIParser because a receipt is one shift, not one pay period.
enum ReceiptAIParser {
    private static let model = "gpt-5.6-terra"

    private static let prompt = """
    Read this restaurant shift closeout receipt. It represents one current shift, not a paycheck or a weekly/pay-period summary. Extract only values that are explicitly printed for this shift.

    Return:
    - cash_tips: cash tips when explicitly labeled, including a "Cash tips (declared)" line. Do not use Cash in hand, Cash in drawer, Cash bank, Owed to employee, cash sales, or cash payments.
    - credit_tips: credit, card, charge, or "Non-cash tips" when explicitly labeled. A credit-tip audit may repeat the same tip total shown in the summary. Return that shift total once; never add repeated summary and audit values together.
    - tip_out: the final Total in a "TIP SHARING" section, or an explicitly labeled tip-out/tipout total. Prefer the printed section total instead of adding its individual rows.
    - sales: post-tax sales only, meaning the shift's sales total including sales tax but excluding tips. On a Shift Review Summary, use "Gross sales" under "SALES & TAXES SUMMARY." Never use Total amount, net sales, pre-tax sales, taxable sales, a credit-audit Subtotal, or another subtotal. If an after-tax sales number is not unambiguous, return null.
    - server_count: number of servers, staff, or server count when explicitly printed.
    - guest_count: the explicitly printed "Total guests served" count.
    - credit_check_count: count the distinct check data rows in the "CREDIT TIP AUDIT" section. Exclude its header and Total row.
    - table_count: the number of physical tables only when explicitly printed. Do not infer tables from checks; the app handles that estimate separately.
    - net_sales: the explicitly printed pre-tax "Total net sales" amount.
    - tax: the explicitly printed sales tax amount.
    - printed_tip_percent: the explicitly printed tip percentage as a percent number, so 20.3% is 20.3.
    - average_spend_per_guest: the explicitly printed average spend per guest.
    - cash_sales: the explicitly printed collected cash sales amount, including a zero when one is printed. Do not use cash tips.
    - gratuity_fees: the explicitly printed total gratuity and fees.
    - category_sales: rows from the "SALES & TAXES SUMMARY" that represent sales categories. For each row return its printed name, quantity, and pre-tax net sales. Exclude totals, tax, tips, gratuity/fees, discounts, and payment rows. Return an empty array when unavailable.
    - tip_sharing: numeric role/amount rows from "TIP SHARING." Exclude the Total row and skip rows whose amount is NA or missing. Return an empty array when unavailable.
    - shift_date: the date printed for this shift, formatted YYYY-MM-DD.
    - clock_in: the start of the printed shift time range, formatted HH:mm in 24-hour time.
    - clock_out: the end of the printed shift time range, formatted HH:mm in 24-hour time.

    The same value may be printed in multiple sections. Never sum duplicated shift totals. "Total guests served" and any guest count are never a server count. A check is not necessarily a physical table because one table can split into multiple checks. Do not infer a table count. Ignore check identifiers, card last-four digits, employee IDs, and any weekly or year-to-date values. Do not add tax to a pre-tax number yourself. Do not infer a cash/credit split from a combined tip total. Do not calculate a missing field from another field.

    Return money as numbers in dollars, with up to two decimal places. Return null when a scalar field is not present or not unambiguous. Return counts as integers or null. Return shift_date, clock_in, and clock_out as strings in the requested formats or null.
    """

    struct ParsedValues: Decodable {
        struct CategoryValue: Decodable {
            let name: String
            let quantity: Int?
            let netSales: Double?

            enum CodingKeys: String, CodingKey {
                case name
                case quantity
                case netSales = "net_sales"
            }
        }

        struct TipSharingValue: Decodable {
            let role: String
            let amount: Double
        }

        let cashTips: Double?
        let creditTips: Double?
        let tipOut: Double?
        let sales: Double?
        let serverCount: Int?
        let guestCount: Int?
        let creditCheckCount: Int?
        let tableCount: Int?
        let netSales: Double?
        let tax: Double?
        let printedTipPercent: Double?
        let averageSpendPerGuest: Double?
        let cashSales: Double?
        let gratuityFees: Double?
        let categorySales: [CategoryValue]
        let tipSharing: [TipSharingValue]
        let shiftDate: String?
        let clockIn: String?
        let clockOut: String?

        enum CodingKeys: String, CodingKey {
            case cashTips = "cash_tips"
            case creditTips = "credit_tips"
            case tipOut = "tip_out"
            case sales
            case serverCount = "server_count"
            case guestCount = "guest_count"
            case creditCheckCount = "credit_check_count"
            case tableCount = "table_count"
            case netSales = "net_sales"
            case tax
            case printedTipPercent = "printed_tip_percent"
            case averageSpendPerGuest = "average_spend_per_guest"
            case cashSales = "cash_sales"
            case gratuityFees = "gratuity_fees"
            case categorySales = "category_sales"
            case tipSharing = "tip_sharing"
            case shiftDate = "shift_date"
            case clockIn = "clock_in"
            case clockOut = "clock_out"
        }
    }

    private struct ResponsesEnvelope: Decodable {
        struct OutputItem: Decodable {
            let type: String
            let content: [ContentItem]?
        }

        struct ContentItem: Decodable {
            let type: String
            let text: String?
        }

        let output: [OutputItem]

        var outputText: String? {
            output.first(where: { $0.type == "message" })?.content?
                .first(where: { $0.type == "output_text" })?.text
        }
    }

    struct ParsedReceipt: Equatable, Sendable {
        struct ShiftDate: Equatable, Sendable {
            let year: Int
            let month: Int
            let day: Int
        }

        struct ClockTime: Equatable, Sendable {
            let hour: Int
            let minute: Int
        }

        let cashTipsCents: Int?
        let creditTipsCents: Int?
        let tipOutCents: Int?
        let salesCents: Int?
        let serverCount: Int?
        let guestCount: Int?
        let creditCheckCount: Int?
        let printedTableCount: Int?
        let netSalesCents: Int?
        let taxCents: Int?
        let printedTipPercentHundredths: Int?
        let averageSpendPerGuestCents: Int?
        let cashSalesCents: Int?
        let gratuityFeesCents: Int?
        let categorySales: [ShiftReceiptMetrics.CategorySales]
        let tipSharing: [ShiftReceiptMetrics.TipSharingLine]
        let shiftDate: ShiftDate?
        let clockIn: ClockTime?
        let clockOut: ClockTime?

        /// Physical table count when printed; otherwise a conservative check
        /// proxy only when the receipt explicitly says there were no cash
        /// sales. Cash checks can be absent from a credit audit, so a nonzero
        /// or unknown cash-sales value disables the estimate.
        var tableCount: Int? {
            if let printedTableCount { return printedTableCount }
            guard let creditCheckCount, cashSalesCents == 0 else { return nil }
            return creditCheckCount
        }

        var tableCountSource: TableCountSource? {
            if printedTableCount != nil { return .printed }
            return tableCount == nil ? nil : .inferredFromChecks
        }

        var receiptMetrics: ShiftReceiptMetrics? {
            let metrics = ShiftReceiptMetrics(
                guestCount: guestCount,
                creditCheckCount: creditCheckCount,
                tableCount: tableCount,
                tableCountSource: tableCountSource,
                netSalesCents: netSalesCents,
                taxCents: taxCents,
                printedTipPercentHundredths: printedTipPercentHundredths,
                averageSpendPerGuestCents: averageSpendPerGuestCents,
                cashSalesCents: cashSalesCents,
                gratuityFeesCents: gratuityFeesCents,
                categorySales: categorySales.isEmpty ? nil : categorySales,
                tipSharing: tipSharing.isEmpty ? nil : tipSharing
            )
            return metrics.isEmpty ? nil : metrics
        }

        /// Count only fields a person can review in the compact shift form.
        /// Rich category and tip-sharing rows are saved in the background.
        var filledFieldCount: Int {
            let amountCount = [cashTipsCents, creditTipsCents, tipOutCents, salesCents, serverCount]
                .compactMap { $0 }.count
            let dateAndTimeCount = [shiftDate != nil, clockIn != nil, clockOut != nil]
                .filter { $0 }.count
            let peopleAndTablesCount = [guestCount, tableCount].compactMap { $0 }.count
            return amountCount + dateAndTimeCount + peopleAndTablesCount
        }

        var hasCapturedFacts: Bool {
            filledFieldCount > 0 || receiptMetrics != nil
        }
    }

    enum ParseError: LocalizedError, Sendable {
        case notConfigured
        case imageUnavailable
        case quotaExhausted
        case requestFailed
        case invalidResponse
        case noFieldsFound

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "AI receipt reading is not configured for this build."
            case .imageUnavailable:
                "The receipt photo could not be prepared."
            case .quotaExhausted:
                "AI receipt credits have run out. Add API credits, then try again."
            case .requestFailed:
                "AI receipt reading is temporarily unavailable."
            case .invalidResponse:
                "AI receipt reading returned an unreadable result."
            case .noFieldsFound:
                "No shift amounts were found. Take a closer, well-lit photo of the receipt."
            }
        }
    }

    static var isConfigured: Bool {
        apiKey != nil
    }

    static func parse(image: UIImage) async throws -> ParsedReceipt {
        guard let apiKey else { throw ParseError.notConfigured }
        guard let imageData = jpegData(for: image) else {
            throw ParseError.imageUnavailable
        }

        let imageURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        let requestBody: [String: Any] = [
            "model": model,
            "reasoning": ["effort": "xhigh"],
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": prompt],
                    ["type": "input_image", "image_url": imageURL, "detail": "high"]
                ]
            ]],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "shift_receipt_values",
                    "strict": true,
                    "schema": schema()
                ]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw ParseError.requestFailed }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw requestError(statusCode: httpResponse.statusCode, responseData: data)
        }

        let parsed = try parse(responseData: data)
        guard parsed.hasCapturedFacts else { throw ParseError.noFieldsFound }
        return parsed
    }

    /// Pure response decoding keeps the model contract testable without
    /// sending a receipt to the network.
    static func parse(responseData: Data) throws -> ParsedReceipt {
        guard let envelope = try? JSONDecoder().decode(ResponsesEnvelope.self, from: responseData),
              let outputText = envelope.outputText,
              let valuesData = outputText.data(using: .utf8),
              let values = try? JSONDecoder().decode(ParsedValues.self, from: valuesData)
        else {
            throw ParseError.invalidResponse
        }

        return ParsedReceipt(
            cashTipsCents: cents(values.cashTips),
            creditTipsCents: cents(values.creditTips),
            tipOutCents: cents(values.tipOut),
            salesCents: cents(values.sales),
            serverCount: positiveCount(values.serverCount),
            guestCount: positiveCount(values.guestCount),
            creditCheckCount: positiveCount(values.creditCheckCount),
            printedTableCount: positiveCount(values.tableCount),
            netSalesCents: cents(values.netSales),
            taxCents: cents(values.tax),
            printedTipPercentHundredths: hundredths(values.printedTipPercent),
            averageSpendPerGuestCents: cents(values.averageSpendPerGuest),
            cashSalesCents: cents(values.cashSales),
            gratuityFeesCents: cents(values.gratuityFees),
            categorySales: values.categorySales.compactMap { category in
                let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return ShiftReceiptMetrics.CategorySales(
                    name: name,
                    quantity: positiveCount(category.quantity),
                    netSalesCents: cents(category.netSales)
                )
            },
            tipSharing: values.tipSharing.compactMap { line in
                let role = line.role.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !role.isEmpty, let amountCents = cents(line.amount) else { return nil }
                return ShiftReceiptMetrics.TipSharingLine(role: role, amountCents: amountCents)
            },
            shiftDate: shiftDate(values.shiftDate),
            clockIn: clockTime(values.clockIn),
            clockOut: clockTime(values.clockOut)
        )
    }

    /// Keeps billing failures actionable without exposing raw API responses
    /// or account details in the UI. Other HTTP failures retain the generic,
    /// retry-friendly message.
    static func requestError(statusCode: Int, responseData: Data) -> ParseError {
        struct ErrorEnvelope: Decodable {
            struct APIError: Decodable {
                let type: String?
                let code: String?
            }

            let error: APIError
        }

        if statusCode == 429,
           let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: responseData),
           envelope.error.type == "insufficient_quota" || envelope.error.code == "credit_balance_exhausted" {
            return .quotaExhausted
        }
        return .requestFailed
    }

    private static var apiKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cents(_ dollars: Double?) -> Int? {
        guard let dollars else { return nil }
        return max(0, Int((dollars * 100).rounded()))
    }

    private static func hundredths(_ percent: Double?) -> Int? {
        guard let percent else { return nil }
        return max(0, Int((percent * 100).rounded()))
    }

    private static func positiveCount(_ count: Int?) -> Int? {
        guard let count, count > 0 else { return nil }
        return count
    }

    private static func shiftDate(_ value: String?) -> ParsedReceipt.ShiftDate? {
        guard let value else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              (1...12).contains(parts[1]),
              (1...31).contains(parts[2])
        else { return nil }
        return ParsedReceipt.ShiftDate(year: parts[0], month: parts[1], day: parts[2])
    }

    private static func clockTime(_ value: String?) -> ParsedReceipt.ClockTime? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              (0...23).contains(parts[0]),
              (0...59).contains(parts[1])
        else { return nil }
        return ParsedReceipt.ClockTime(hour: parts[0], minute: parts[1])
    }

    private static func jpegData(for image: UIImage) -> Data? {
        let maxDimension: CGFloat = 2400
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / max(longestSide, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.jpegData(withCompressionQuality: 0.84) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func schema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "cash_tips": ["type": ["number", "null"]],
                "credit_tips": ["type": ["number", "null"]],
                "tip_out": ["type": ["number", "null"]],
                "sales": ["type": ["number", "null"]],
                "server_count": ["type": ["integer", "null"]],
                "guest_count": ["type": ["integer", "null"]],
                "credit_check_count": ["type": ["integer", "null"]],
                "table_count": ["type": ["integer", "null"]],
                "net_sales": ["type": ["number", "null"]],
                "tax": ["type": ["number", "null"]],
                "printed_tip_percent": ["type": ["number", "null"]],
                "average_spend_per_guest": ["type": ["number", "null"]],
                "cash_sales": ["type": ["number", "null"]],
                "gratuity_fees": ["type": ["number", "null"]],
                "category_sales": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "quantity": ["type": ["integer", "null"]],
                            "net_sales": ["type": ["number", "null"]]
                        ],
                        "required": ["name", "quantity", "net_sales"],
                        "additionalProperties": false
                    ]
                ],
                "tip_sharing": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "role": ["type": "string"],
                            "amount": ["type": "number"]
                        ],
                        "required": ["role", "amount"],
                        "additionalProperties": false
                    ]
                ],
                "shift_date": ["type": ["string", "null"]],
                "clock_in": ["type": ["string", "null"]],
                "clock_out": ["type": ["string", "null"]]
            ],
            "required": ["cash_tips", "credit_tips", "tip_out", "sales", "server_count", "guest_count", "credit_check_count", "table_count", "net_sales", "tax", "printed_tip_percent", "average_spend_per_guest", "cash_sales", "gratuity_fees", "category_sales", "tip_sharing", "shift_date", "clock_in", "clock_out"],
            "additionalProperties": false
        ]
    }
}
