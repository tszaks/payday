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
    - cash_tips: cash tips, cash tips owed, or cash payout when explicitly labeled as tips. Do not use cash sales.
    - credit_tips: credit, card, or charge tips when explicitly labeled.
    - tip_out: tip-out, tipout, or paid-out amount when explicitly labeled.
    - sales: post-tax sales only, meaning the shift's sales total including sales tax but excluding tips. Prefer a clearly labeled after-tax, gross, or final sales total. Never use net sales, pre-tax sales, taxable sales, or subtotal. If an after-tax sales number is not unambiguous, return null.
    - server_count: number of servers, staff, or server count when explicitly printed.

    Ignore standalone tax amounts, checks, payment totals, discounts, totals that are not labeled as sales or tips, dates, employee IDs, and any weekly or year-to-date values. Do not add tax to a pre-tax number yourself. Do not infer a cash/credit split from a combined tip total. Do not calculate a missing field from another field.

    Return money as numbers in dollars, with up to two decimal places. Return null when a field is not present or not unambiguous. Return server_count as an integer or null.
    """

    struct ParsedValues: Decodable {
        let cashTips: Double?
        let creditTips: Double?
        let tipOut: Double?
        let sales: Double?
        let serverCount: Int?

        enum CodingKeys: String, CodingKey {
            case cashTips = "cash_tips"
            case creditTips = "credit_tips"
            case tipOut = "tip_out"
            case sales
            case serverCount = "server_count"
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
        let cashTipsCents: Int?
        let creditTipsCents: Int?
        let tipOutCents: Int?
        let salesCents: Int?
        let serverCount: Int?

        var filledFieldCount: Int {
            [cashTipsCents, creditTipsCents, tipOutCents, salesCents, serverCount]
                .compactMap { $0 }
                .count
        }
    }

    enum ParseError: LocalizedError, Sendable {
        case notConfigured
        case imageUnavailable
        case requestFailed
        case invalidResponse
        case noFieldsFound

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "AI receipt reading is not configured for this build."
            case .imageUnavailable:
                "The receipt photo could not be prepared."
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
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw ParseError.requestFailed
        }

        let parsed = try parse(responseData: data)
        guard parsed.filledFieldCount > 0 else { throw ParseError.noFieldsFound }
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
            serverCount: positiveCount(values.serverCount)
        )
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

    private static func positiveCount(_ count: Int?) -> Int? {
        guard let count, count > 0 else { return nil }
        return count
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
                "server_count": ["type": ["integer", "null"]]
            ],
            "required": ["cash_tips", "credit_tips", "tip_out", "sales", "server_count"],
            "additionalProperties": false
        ]
    }
}
