import Foundation
import OSLog
import UIKit

/// Reads a pay stub with the private app's configured OpenAI key. This is a
/// local-only build feature for Tyler's phone; Release builds resolve the key
/// to an empty value and automatically use PaycheckOCR's on-device fallback.
enum PaycheckAIParser {
    private static let model = "gpt-5.6-terra"
    private static let requestTimeout: TimeInterval = 30
    private static let logger = Logger(
        subsystem: "com.szakacsmedia.payday",
        category: "PaycheckAnalysis"
    )
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()
    private static let resultCache = ScanResultCache<PaycheckOCR.ParsedPaycheck>()

    private static let prompt = """
    Read only the earnings statement/pay-stub portion of this image as one paycheck for one pay period. Ignore the negotiable check face, written-out check amount, MICR numbers, check number, payment-distribution rows, employer-paid benefits, and repeated copies of net pay outside the pay-stub totals. Repeated earnings rows may show the two work weeks inside that single paycheck. Sum every distinct repeated current-period row for the same category exactly once, and never return separate weekly values. In earnings and tax tables, use the Current or Amount column immediately to the right of the label. Never use the YTD, hours, rate, or non-worked-hours columns.

    Return one earnings_rows item for every distinct current-period earnings row. Preserve repeated weekly rows as separate items. For each item, copy its printed label, classify it as tips, regular_wages, overtime_wages, or gratuity, and copy only the current Amount value. Classify Gratuity Owed only as gratuity, never tips. Payday will combine the rows deterministically; do not pre-sum or deduplicate them.

    Also return:
    - gross_pay: current-period gross earnings or total gross
    - taxes: current-period total taxes, not the YTD total
    - net_pay: current-period net pay

    Before returning, re-read every selected source amount and check whether tips + regular_wages + overtime_wages + gratuity equals gross_pay and whether gross_pay - taxes equals net_pay when the stub shows zero deductions. Use those identities only to detect and re-read a likely OCR digit; do not invent a missing field or silently force arithmetic to match. Return money as numbers in dollars, with up to two decimal places. Return null only when a field is not present.
    """

    private struct PaycheckValues: Decodable {
        struct EarningsRow: Decodable {
            enum Category: String, Decodable {
                case tips
                case regularWages = "regular_wages"
                case overtimeWages = "overtime_wages"
                case gratuity
            }

            let category: Category
            let label: String
            let currentAmount: Double

            enum CodingKeys: String, CodingKey {
                case category
                case label
                case currentAmount = "current_amount"
            }
        }

        let earningsRows: [EarningsRow]?
        // Keep decoding the original totals contract so an in-flight response
        // or an older local fixture remains readable during this transition.
        let tips: Double?
        let regularWages: Double?
        let overtimeWages: Double?
        let gratuity: Double?
        let grossPay: Double?
        let taxes: Double?
        let netPay: Double?

        enum CodingKeys: String, CodingKey {
            case earningsRows = "earnings_rows"
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
        case timedOut
        case requestFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Pay stub analysis is not configured for this build."
            case .timedOut:
                "Pay stub analysis took too long. Check your connection and try again."
            case .requestFailed:
                "Pay stub analysis is temporarily unavailable."
            case .invalidResponse:
                "Pay stub analysis returned an unreadable result."
            }
        }
    }

    static var isConfigured: Bool {
        apiKey != nil
    }

    static func parse(image: UIImage) async throws -> PaycheckOCR.ParsedPaycheck {
        let analysisStartedAt = Date()
        logger.notice(
            "Paycheck analysis invoked. model=\(model, privacy: .public) timeoutSeconds=\(Int(requestTimeout)) sourcePixels=\(Int(image.size.width))x\(Int(image.size.height))"
        )
        guard let apiKey else {
            logger.error("Paycheck analysis stopped before request: API key unavailable")
            throw ParseError.notConfigured
        }
        guard let imageData = jpegData(for: image) else {
            logger.error("Paycheck analysis stopped before request: JPEG preparation failed")
            throw PaycheckOCR.ScanError.imageUnavailable
        }
        logger.notice("Paycheck JPEG prepared. bytes=\(imageData.count)")
        if let cached = await resultCache.value(for: imageData) {
            logger.notice("Paycheck analysis reused a cached result; no network request needed")
            return cached
        }

        return try await resultCache.value(for: imageData) {
        let imageURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        let requestBody: [String: Any] = [
            "model": model,
            "reasoning": ["effort": "medium"],
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
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        logger.notice(
            "Paycheck request encoded. bodyBytes=\(request.httpBody?.count ?? 0)"
        )

        let data: Data
        let response: URLResponse
        let networkStartedAt = Date()
        logger.notice("Paycheck network request started")
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(networkStartedAt) * 1_000)
            logger.error(
                "Paycheck network request timed out. elapsedMs=\(elapsedMilliseconds) code=\(error.code.rawValue)"
            )
            throw ParseError.timedOut
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(networkStartedAt) * 1_000)
            logger.error(
                "Paycheck network request failed. elapsedMs=\(elapsedMilliseconds) code=\(error.code.rawValue)"
            )
            throw ParseError.requestFailed
        } catch {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(networkStartedAt) * 1_000)
            let errorType = String(describing: type(of: error))
            logger.error(
                "Paycheck network request failed. elapsedMs=\(elapsedMilliseconds) type=\(errorType, privacy: .public)"
            )
            throw ParseError.requestFailed
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Paycheck network request returned a non-HTTP response")
            throw ParseError.requestFailed
        }
        let networkMilliseconds = Int(Date().timeIntervalSince(networkStartedAt) * 1_000)
        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id") ?? "unavailable"
        logger.notice(
            "Paycheck network request completed. status=\(httpResponse.statusCode) responseBytes=\(data.count) elapsedMs=\(networkMilliseconds) requestId=\(requestID, privacy: .public)"
        )
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.error("Paycheck API rejected request. status=\(httpResponse.statusCode)")
            throw ParseError.requestFailed
        }

        do {
            let parsed = try parse(responseData: data)
            let totalMilliseconds = Int(Date().timeIntervalSince(analysisStartedAt) * 1_000)
            logger.notice(
                "Paycheck analysis succeeded. filledFields=\(parsed.filledFieldCount) elapsedMs=\(totalMilliseconds)"
            )
            return parsed
        } catch {
            let errorType = String(describing: type(of: error))
            logger.error(
                "Paycheck response decoding failed. type=\(errorType, privacy: .public)"
            )
            throw error
        }
        }
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
            tipsCents: combinedCents(.tips, in: values) ?? cents(values.tips),
            regularWagesCents: combinedCents(.regularWages, in: values) ?? cents(values.regularWages),
            overtimeWagesCents: combinedCents(.overtimeWages, in: values) ?? cents(values.overtimeWages),
            gratuityCents: combinedCents(.gratuity, in: values) ?? cents(values.gratuity),
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

    private static func combinedCents(
        _ category: PaycheckValues.EarningsRow.Category,
        in values: PaycheckValues
    ) -> Int? {
        guard let rows = values.earningsRows else { return nil }
        let matchingRows = rows.filter { $0.category == category }
        guard !matchingRows.isEmpty else { return nil }
        return matchingRows.reduce(0) { total, row in
            total + (cents(row.currentAmount) ?? 0)
        }
    }

    private static func jpegData(for image: UIImage) -> Data? {
        // A full paycheck photo can contain a small, dense earnings table plus
        // a much larger check face. Preserve enough pixels for decimal points
        // and narrow current-period columns to survive model-side resizing.
        ScanImageEncoder.jpegData(
            for: image,
            maxDimension: 3_200,
            maxBytes: 2_000_000,
            initialQuality: 0.90
        )
    }

    private static func schema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "earnings_rows": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "category": [
                                "type": "string",
                                "enum": ["tips", "regular_wages", "overtime_wages", "gratuity"]
                            ],
                            "label": ["type": "string"],
                            "current_amount": ["type": "number"]
                        ],
                        "required": ["category", "label", "current_amount"],
                        "additionalProperties": false
                    ]
                ],
                "gross_pay": ["type": ["number", "null"]],
                "taxes": ["type": ["number", "null"]],
                "net_pay": ["type": ["number", "null"]]
            ],
            "required": ["earnings_rows", "gross_pay", "taxes", "net_pay"],
            "additionalProperties": false
        ]
    }
}
