import Foundation
import ImageIO
import OSLog
import UIKit
import Vision

/// Reads a restaurant shift closeout receipt and returns only the fields that
/// are explicitly printed on that receipt. This is intentionally separate
/// from PaycheckAIParser because a receipt is one shift, not one pay period.
enum ReceiptAIParser {
    private static let endpoint = URL(
        string: "https://payday-website-eta.vercel.app/api/receipt-analyze"
    )
    private static let requestTimeout: TimeInterval = 30
    private static let logger = Logger(
        subsystem: "com.szakacsmedia.payday",
        category: "ReceiptAnalysis"
    )
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()

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
        case noTextFound
        case quotaExhausted
        case timedOut
        case requestFailed
        case invalidResponse
        case noFieldsFound

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Receipt analysis is not configured for this build."
            case .imageUnavailable:
                "The receipt photo could not be prepared."
            case .noTextFound:
                "No readable receipt text was found. Try a closer, well-lit photo."
            case .quotaExhausted:
                "Receipt analysis credits have run out. Add API credits, then try again."
            case .timedOut:
                "Receipt analysis took too long. Check your connection and try again."
            case .requestFailed:
                "Receipt analysis is temporarily unavailable."
            case .invalidResponse:
                "Receipt analysis returned an unreadable result."
            case .noFieldsFound:
                "No shift amounts were found. Take a closer, well-lit photo of the receipt."
            }
        }
    }

    static var isConfigured: Bool {
        endpoint != nil
    }

    static func parse(image: UIImage) async throws -> ParsedReceipt {
        let analysisStartedAt = Date()
        logger.notice(
            "Receipt analysis invoked. route=payday-proxy timeoutSeconds=\(Int(requestTimeout)) sourcePixels=\(Int(image.size.width))x\(Int(image.size.height))"
        )
        guard let endpoint else {
            logger.error("Receipt analysis stopped before request: endpoint unavailable")
            throw ParseError.notConfigured
        }
        let ocrStartedAt = Date()
        let transcript: String
        do {
            transcript = try await recognizeTranscript(in: image)
        } catch {
            let errorType = String(describing: type(of: error))
            logger.error(
                "Receipt OCR failed. type=\(errorType, privacy: .public)"
            )
            throw error
        }
        let ocrMilliseconds = Int(Date().timeIntervalSince(ocrStartedAt) * 1_000)
        logger.notice(
            "Receipt OCR completed. characters=\(transcript.count) elapsedMs=\(ocrMilliseconds)"
        )
        guard let imageData = jpegData(for: image) else {
            logger.error("Receipt analysis stopped before request: compressed image unavailable")
            throw ParseError.imageUnavailable
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(transcript: transcript, imageData: imageData)
        )
        logger.notice(
            "Receipt request encoded. bodyBytes=\(request.httpBody?.count ?? 0)"
        )

        let data: Data
        let response: URLResponse
        let networkStartedAt = Date()
        logger.notice("Receipt network request started")
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(networkStartedAt) * 1_000)
            logger.error(
                "Receipt network request timed out. elapsedMs=\(elapsedMilliseconds) code=\(error.code.rawValue)"
            )
            throw ParseError.timedOut
        } catch let error as URLError {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(networkStartedAt) * 1_000)
            logger.error(
                "Receipt network request failed. elapsedMs=\(elapsedMilliseconds) code=\(error.code.rawValue)"
            )
            throw ParseError.requestFailed
        } catch {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(networkStartedAt) * 1_000)
            let errorType = String(describing: type(of: error))
            logger.error(
                "Receipt network request failed. elapsedMs=\(elapsedMilliseconds) type=\(errorType, privacy: .public)"
            )
            throw ParseError.requestFailed
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Receipt network request returned a non-HTTP response")
            throw ParseError.requestFailed
        }
        let networkMilliseconds = Int(Date().timeIntervalSince(networkStartedAt) * 1_000)
        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id") ?? "unavailable"
        logger.notice(
            "Receipt network request completed. status=\(httpResponse.statusCode) responseBytes=\(data.count) elapsedMs=\(networkMilliseconds) requestId=\(requestID, privacy: .public)"
        )
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.error("Receipt API rejected request. status=\(httpResponse.statusCode)")
            throw requestError(statusCode: httpResponse.statusCode, responseData: data)
        }

        let parsed: ParsedReceipt
        do {
            parsed = try parse(responseData: data)
        } catch {
            let errorType = String(describing: type(of: error))
            logger.error(
                "Receipt response decoding failed. type=\(errorType, privacy: .public)"
            )
            throw error
        }
        guard parsed.hasCapturedFacts else {
            logger.error("Receipt response decoded but contained no captured facts")
            throw ParseError.noFieldsFound
        }
        let totalMilliseconds = Int(Date().timeIntervalSince(analysisStartedAt) * 1_000)
        logger.notice(
            "Receipt analysis succeeded. filledFields=\(parsed.filledFieldCount) hasMetrics=\(parsed.receiptMetrics != nil) elapsedMs=\(totalMilliseconds)"
        )
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

    struct OCRFragment: Equatable, Sendable {
        let text: String
        let minX: Double
        let midY: Double
    }

    static func transcript(fragments: [OCRFragment]) -> String {
        let sorted = fragments.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 0.000_1 {
                return lhs.midY > rhs.midY
            }
            return lhs.minX < rhs.minX
        }

        var rows: [[OCRFragment]] = []
        for fragment in sorted {
            if let rowIndex = rows.indices.last,
               let anchorY = rows[rowIndex].first?.midY,
               abs(anchorY - fragment.midY) <= 0.0045
            {
                rows[rowIndex].append(fragment)
            } else {
                rows.append([fragment])
            }
        }

        return rows.map { row in
            let rowText = row
                .sorted { $0.minX < $1.minX }
                .map(\.text)
                .joined(separator: " | ")
            return "[row] \(rowText)"
        }
        .joined(separator: "\n")
    }

    static func requestBody(transcript: String, imageData: Data) -> [String: Any] {
        let imageURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"

        return [
            "transcript": transcript,
            "image_data_url": imageURL
        ]
    }

    private static func recognizeTranscript(in image: UIImage) async throws -> String {
        guard let imageData = image.jpegData(compressionQuality: 1) else {
            throw ParseError.imageUnavailable
        }

        return try await Task.detached(priority: .userInitiated) {
            guard let localImage = UIImage(data: imageData),
                  let cgImage = localImage.cgImage
            else {
                throw ParseError.imageUnavailable
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.customWords = [
                "Kooma", "Sake", "Sushi", "Busser", "Gratuity", "Tipout"
            ]
            request.minimumTextHeight = 0.003

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: localImage.receiptOCROrientation,
                options: [:]
            )
            try handler.perform([request])

            let fragments = (request.results ?? []).compactMap { observation -> OCRFragment? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return OCRFragment(
                    text: text,
                    minX: Double(observation.boundingBox.minX),
                    midY: Double(observation.boundingBox.midY)
                )
            }
            guard !fragments.isEmpty else { throw ParseError.noTextFound }
            return transcript(fragments: fragments)
        }.value
    }

    /// Apple Vision keeps the request fast and gives the model explicit row
    /// order. The compact image is sent alongside it so a missed OCR label or
    /// detached amount cannot silently turn an obvious printed fact into nil.
    static func jpegData(for image: UIImage, maxDimension: CGFloat = 1_800) -> Data? {
        let longestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / max(longestSide, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.jpegData(withCompressionQuality: 0.80) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

}

private extension UIImage {
    var receiptOCROrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
