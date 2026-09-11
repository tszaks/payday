import Foundation
import ImageIO
import UIKit
import Vision

/// On-device pay-stub reading. Vision recognizes the words, then this type
/// matches those words to the fields Payday already captures. No image or
/// recognized text leaves the phone when the AI parser is unavailable.
enum PaycheckOCR {
    struct RecognizedText: Equatable, Sendable {
        let text: String
        let boundingBox: CGRect
    }

    struct ParsedPaycheck: Equatable, Sendable {
        var tipsCents: Int?
        var regularWagesCents: Int?
        var overtimeWagesCents: Int?
        var gratuityCents: Int?
        var grossPayCents: Int?
        var taxesCents: Int?
        var netPayCents: Int?

        var filledFieldCount: Int {
            [tipsCents, regularWagesCents, overtimeWagesCents, gratuityCents, grossPayCents, taxesCents, netPayCents]
                .compactMap { $0 }
                .count
        }

        /// Correct a small OCR error in the tips field when every printed
        /// earnings component independently proves the intended value. Keep
        /// larger differences untouched because they can represent a real,
        /// uncaptured earnings row rather than a transposed digit.
        func correctingSmallGrossMismatch() -> Self {
            guard let tipsCents,
                  let regularWagesCents,
                  let overtimeWagesCents,
                  let gratuityCents,
                  let grossPayCents
            else { return self }

            var corrected = self
            corrected.tipsCents = PaycheckRecord.reconciledTipsCents(
                tipsCents: tipsCents,
                regularWagesCents: regularWagesCents,
                overtimeWagesCents: overtimeWagesCents,
                gratuityCents: gratuityCents,
                grossPayCents: grossPayCents
            )
            return corrected
        }
    }

    enum ScanError: LocalizedError, Sendable {
        case imageUnavailable
        case noTextFound
        case noPaycheckFieldsFound

        var errorDescription: String? {
            switch self {
            case .imageUnavailable:
                "Payday could not read that photo. Try taking it again in brighter light."
            case .noTextFound:
                "Payday could not find any readable text in that photo."
            case .noPaycheckFieldsFound:
                "Payday could not find paycheck amounts. Make sure the whole pay stub is visible."
            }
        }
    }

    /// Parses OCR output without touching UIKit or Vision. Keeping this pure
    /// makes the label matching easy to test with representative pay stubs.
    static func parse(lines: [String]) -> ParsedPaycheck {
        var result = ParsedPaycheck(tipsCents: nil, regularWagesCents: nil, overtimeWagesCents: nil, gratuityCents: nil, grossPayCents: nil, taxesCents: nil, netPayCents: nil)
        var taxLineCents: [Int] = []
        var explicitTaxesCents: Int?

        for line in lines {
            let normalized = normalize(line)
            guard !normalized.isEmpty, let cents = firstMoneyValue(in: line) else { continue }

            if result.netPayCents == nil, matches(normalized, anyOf: [
                "NET PAY", "NET EARNINGS", "TAKE HOME", "TAKEHOME", "DIRECT DEPOSIT"
            ]) || normalized == "NET" {
                result.netPayCents = cents
                continue
            }

            if result.grossPayCents == nil, matches(normalized, anyOf: [
                "GROSS PAY", "GROSS WAGES", "GROSS EARNINGS", "TOTAL GROSS"
            ]) || normalized == "GROSS" {
                result.grossPayCents = cents
                continue
            }

            if matches(normalized, anyOf: [
                "OVERTIME", "OVERTIME PAY", "OVERTIME WAGES", "OVERTIME EARNINGS", "OT PAY", "OT WAGES"
            ]) {
                result.overtimeWagesCents = (result.overtimeWagesCents ?? 0) + cents
                continue
            }

            if matches(normalized, anyOf: [
                "REGULAR", "REGULAR PAY", "REGULAR WAGES", "REGULAR EARNINGS", "BASE PAY", "BASE WAGES"
            ]) || normalized == "REGULAR" || normalized == "SALARY" {
                result.regularWagesCents = (result.regularWagesCents ?? 0) + cents
                continue
            }

            if matches(normalized, anyOf: ["GRATUITY", "GRATUITIES"]) {
                result.gratuityCents = (result.gratuityCents ?? 0) + cents
                continue
            }

            if matches(normalized, anyOf: ["CARD TIPS", "CREDIT TIPS", "TIP EARNINGS", "TIPS"]),
               !matches(normalized, anyOf: ["TIP OUT", "TIPOUT", "WITHHELD"])
            {
                result.tipsCents = (result.tipsCents ?? 0) + cents
                continue
            }

            if matches(normalized, anyOf: ["TOTAL TAXES", "TOTAL TAX", "TAXES TOTAL"])
                || normalized == "TAXES"
                || normalized == "TAX"
            {
                explicitTaxesCents = cents
                continue
            }

            if isTaxLine(normalized) {
                taxLineCents.append(cents)
            }
        }

        result.taxesCents = explicitTaxesCents ?? (taxLineCents.isEmpty ? nil : taxLineCents.reduce(0, +))
        return result
    }

    /// Runs Apple's on-device OCR away from the main actor, then parses the
    /// recognized lines into the existing paycheck fields. The AI parser gets
    /// first chance when a local key is present because it understands that
    /// repeated weekly rows can belong to one biweekly paycheck. Vision stays
    /// as a private, offline fallback.
    static func parse(image: UIImage) async throws -> ParsedPaycheck {
        if PaycheckAIParser.isConfigured {
            do {
                return try await PaycheckAIParser.parse(image: image).correctingSmallGrossMismatch()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A temporary network or model failure should not make the
                // photo feature unusable. Fall through to on-device Vision.
            }
        }

        return try await parseWithVision(image: image).correctingSmallGrossMismatch()
    }

    private static func parseWithVision(image: UIImage) async throws -> ParsedPaycheck {
        guard let imageData = image.jpegData(compressionQuality: 1) else {
            throw ScanError.imageUnavailable
        }

        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
                throw ScanError.imageUnavailable
            }

            try Task.checkCancellation()
            let lines = try recognizeLines(
                in: cgImage,
                orientation: image.ocrOrientation
            )
            try Task.checkCancellation()
            let parsed = parse(lines: lines)
            guard parsed.filledFieldCount > 0 else {
                throw ScanError.noPaycheckFieldsFound
            }
            return parsed
        }

        let parsed = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }

        return parsed
    }

    private static func recognizeLines(
        in image: CGImage,
        orientation: CGImagePropertyOrientation
    ) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        // Pay stubs commonly contain dense tables whose current-period values
        // are much smaller than the check amount printed below them.
        request.minimumTextHeight = 0.004
        request.customWords = [
            "REGULAR", "OVERTIME", "GRATUITY", "YTD", "WITHHOLDING",
            "SUI", "FICA", "MEDICARE", "PAYCHECK"
        ]

        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])

        let observations = (request.results ?? []).compactMap { observation -> RecognizedText? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return RecognizedText(text: text, boundingBox: observation.boundingBox)
        }
        let lines = visualLines(from: observations)
        guard !lines.isEmpty else { throw ScanError.noTextFound }
        return lines
    }

    /// Vision frequently returns a payroll table's label and amount columns as
    /// separate observations. Rebuild visual rows before label matching so the
    /// parser retains the table relationship instead of flattening it away.
    static func visualLines(from observations: [RecognizedText]) -> [String] {
        struct Row {
            var items: [RecognizedText]
            var centerY: CGFloat
            var height: CGFloat
        }

        let ordered = observations.sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.001 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        var rows: [Row] = []

        for observation in ordered {
            let centerY = observation.boundingBox.midY
            let bestIndex = rows.indices
                .filter { index in
                    let tolerance = max(0.004, max(rows[index].height, observation.boundingBox.height) * 0.85)
                    return abs(rows[index].centerY - centerY) <= tolerance
                }
                .min { abs(rows[$0].centerY - centerY) < abs(rows[$1].centerY - centerY) }

            if let bestIndex {
                rows[bestIndex].items.append(observation)
                let count = CGFloat(rows[bestIndex].items.count)
                rows[bestIndex].centerY = ((rows[bestIndex].centerY * (count - 1)) + centerY) / count
                rows[bestIndex].height = max(rows[bestIndex].height, observation.boundingBox.height)
            } else {
                rows.append(Row(items: [observation], centerY: centerY, height: observation.boundingBox.height))
            }
        }

        return rows
            .sorted { $0.centerY > $1.centerY }
            .map { row in
                row.items
                    .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .map(\.text)
                    .joined(separator: " ")
            }
    }

    private static func normalize(_ line: String) -> String {
        line
            .uppercased()
            .replacingOccurrences(of: "[^A-Z0-9]+", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func matches(_ line: String, anyOf phrases: [String]) -> Bool {
        phrases.contains { line.contains($0) }
    }

    private static func isTaxLine(_ line: String) -> Bool {
        guard !line.hasPrefix("YTD"), !line.contains("TAXABLE"), !line.contains("TAX RATE") else {
            return false
        }
        return matches(line, anyOf: [
            "FEDERAL TAX", "FEDERAL INCOME TAX", "STATE TAX", "STATE INCOME TAX",
            "LOCAL TAX", "CITY TAX", "COUNTY TAX", "SOCIAL SECURITY", "MEDICARE",
            "MEDICAID", "FICA", "FEDERAL WITHHOLDING", "STATE WITHHOLDING",
            "LOCAL WITHHOLDING"
        ])
    }

    private static func firstMoneyValue(in line: String) -> Int? {
        let pattern = #"\(?\$?\s*[0-9][0-9,]*(?:\.[0-9]{1,2})?\)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, range: range)
        // A merged row may contain hours, rate, current amount, and YTD.
        // Prefer an explicitly printed currency cell. Without a currency
        // marker, accept only an unambiguous single numeric value rather than
        // silently treating hours or rate as wages.
        let currencyMatch = matches.first { match in
            guard let matchRange = Range(match.range, in: line) else { return false }
            return line[matchRange].contains("$")
        }
        let match = currencyMatch ?? (matches.count == 1 ? matches[0] : nil)
        guard let match,
              let matchRange = Range(match.range, in: line)
        else { return nil }

        let token = String(line[matchRange])
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let decimal = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        let cents = NSDecimalNumber(decimal: decimal)
            .multiplying(by: NSDecimalNumber(value: 100))
            .intValue
        return max(0, cents)
    }
}

private extension UIImage {
    var ocrOrientation: CGImagePropertyOrientation {
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
