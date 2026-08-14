import Foundation
import ImageIO
import UIKit
import Vision

/// On-device pay-stub reading. Vision recognizes the words, then this type
/// matches those words to the fields Payday already captures. No image or
/// recognized text leaves the phone.
enum PaycheckOCR {
    struct ParsedPaycheck: Equatable, Sendable {
        var tipsCents: Int?
        var regularWagesCents: Int?
        var overtimeWagesCents: Int?
        var grossPayCents: Int?
        var taxesCents: Int?
        var netPayCents: Int?

        var filledFieldCount: Int {
            [tipsCents, regularWagesCents, overtimeWagesCents, grossPayCents, taxesCents, netPayCents]
                .compactMap { $0 }
                .count
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
        var result = ParsedPaycheck(
            tipsCents: nil,
            regularWagesCents: nil,
            overtimeWagesCents: nil,
            grossPayCents: nil,
            taxesCents: nil,
            netPayCents: nil
        )
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

            if result.overtimeWagesCents == nil, matches(normalized, anyOf: [
                "OVERTIME PAY", "OVERTIME WAGES", "OVERTIME EARNINGS", "OT PAY", "OT WAGES"
            ]) {
                result.overtimeWagesCents = cents
                continue
            }

            if result.regularWagesCents == nil, matches(normalized, anyOf: [
                "REGULAR PAY", "REGULAR WAGES", "REGULAR EARNINGS", "BASE PAY", "BASE WAGES"
            ]) || normalized == "REGULAR" || normalized == "SALARY" {
                result.regularWagesCents = cents
                continue
            }

            if result.tipsCents == nil,
               matches(normalized, anyOf: ["CARD TIPS", "CREDIT TIPS", "TIP EARNINGS", "TIPS", "GRATUITY"]),
               !matches(normalized, anyOf: ["TIP OUT", "TIPOUT", "WITHHELD"])
            {
                result.tipsCents = cents
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
    /// recognized lines into the existing paycheck fields.
    static func parse(image: UIImage) async throws -> ParsedPaycheck {
        guard let imageData = image.jpegData(compressionQuality: 1) else {
            throw ScanError.imageUnavailable
        }

        let parsed = try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
                throw ScanError.imageUnavailable
            }

            let lines = try recognizeLines(
                in: cgImage,
                orientation: image.ocrOrientation
            )
            let parsed = parse(lines: lines)
            guard parsed.filledFieldCount > 0 else {
                throw ScanError.noPaycheckFieldsFound
            }
            return parsed
        }.value

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
        request.minimumTextHeight = 0.01

        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])

        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        guard !lines.isEmpty else { throw ScanError.noTextFound }
        return lines
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
        guard let match = regex.firstMatch(in: line, range: range),
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
