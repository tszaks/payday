import Foundation
import UIKit

/// Reads a pay stub with the private app's configured OpenAI key. This is a
/// local-only build feature for Tyler's phone; Release builds resolve the key
/// to an empty value and automatically use PaycheckOCR's on-device fallback.
enum PaycheckAIParser {
    private static let model = "gpt-5.6-terra"

    private static let prompt = """
    Read this pay stub as one paycheck for one pay period. Repeated rows may show the two work weeks inside that single paycheck. Sum every repeated current-period row for the same category, and never return separate weekly values. Ignore YTD columns and values. Use the current-period values only.

    Return:
    - tips: the sum of current-period Tips Owed, Card Tips, Credit Tips, or similar tip rows
    - regular_wages: the sum of current-period REGULAR or base-pay rows
    - overtime_wages: the sum of current-period OVERTIME rows, including zero when the stub explicitly shows zero
    - gratuity: the sum of current-period gratuity rows, separate from tips
    - gross_pay: current-period gross earnings or total gross
    - taxes: current-period total taxes, not the YTD total
    - net_pay: current-period net pay

    Return money as numbers in dollars, with up to two decimal places. Return null only when a field is not present. Do not infer or calculate a missing field from another field.
    """

    private struct PaycheckValues: Decodable {
        let tips: Double?
        let regularWages: Double?
        let overtimeWages: Double?
        let gratuity: Double?
        let grossPay: Double?
        let taxes: Double?
        let netPay: Double?

        enum CodingKeys: String, CodingKey {
            case tips
            case regularWages = "regular_wages"
            case overtimeWages = "overtime_wages"
            case gratuity
            case grossPay = "gross_pay"
            case taxes
            case netPay = "net_pay"
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

    enum ParseError: LocalizedError, Sendable {
        case notConfigured
        case requestFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "AI pay-stub reading is not configured for this build."
            case .requestFailed:
                "AI pay-stub reading is temporarily unavailable."
            case .invalidResponse:
                "AI pay-stub reading returned an unreadable result."
            }
        }
    }

    static var isConfigured: Bool {
        apiKey != nil
    }

    static func parse(image: UIImage) async throws -> PaycheckOCR.ParsedPaycheck {
        guard let apiKey else { throw ParseError.notConfigured }
        guard let imageData = jpegData(for: image) else {
            throw PaycheckOCR.ScanError.imageUnavailable
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
                    "name": "paycheck_totals",
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

        return try parse(responseData: data)
    }

    /// Pure response decoding keeps the model contract testable without
    /// sending a pay stub to the network.
    static func parse(responseData: Data) throws -> PaycheckOCR.ParsedPaycheck {
        guard let envelope = try? JSONDecoder().decode(ResponsesEnvelope.self, from: responseData),
              let outputText = envelope.outputText,
              let valuesData = outputText.data(using: .utf8),
              let values = try? JSONDecoder().decode(PaycheckValues.self, from: valuesData)
        else {
            throw ParseError.invalidResponse
        }

        return PaycheckOCR.ParsedPaycheck(
            tipsCents: cents(values.tips),
            regularWagesCents: cents(values.regularWages),
            overtimeWagesCents: cents(values.overtimeWages),
            gratuityCents: cents(values.gratuity),
            grossPayCents: cents(values.grossPay),
            taxesCents: cents(values.taxes),
            netPayCents: cents(values.netPay)
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
                "tips": ["type": ["number", "null"]],
                "regular_wages": ["type": ["number", "null"]],
                "overtime_wages": ["type": ["number", "null"]],
                "gratuity": ["type": ["number", "null"]],
                "gross_pay": ["type": ["number", "null"]],
                "taxes": ["type": ["number", "null"]],
                "net_pay": ["type": ["number", "null"]]
            ],
            "required": ["tips", "regular_wages", "overtime_wages", "gratuity", "gross_pay", "taxes", "net_pay"],
            "additionalProperties": false
        ]
    }
}
