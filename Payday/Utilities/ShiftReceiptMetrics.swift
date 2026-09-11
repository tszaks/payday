import Foundation

/// Where a shift's table count came from. A receipt normally exposes checks,
/// not physical tables, so that estimate stays visibly distinct until it is
/// corrected or confirmed by the person who worked the shift.
enum TableCountSource: String, Codable, Hashable, Sendable {
    case printed
    case inferredFromChecks
    case confirmed

    var isEstimated: Bool {
        self == .inferredFromChecks
    }
}

/// Rich facts captured from one end-of-shift printout. TipEntry persists this
/// as one optional JSON string on the shift's canonical row, which keeps the
/// CloudKit model compact while allowing new receipt fields to remain
/// additive and optional.
struct ShiftReceiptMetrics: Codable, Equatable, Hashable, Sendable {
    /// Version 2 means the parent TipEntry amount contains voluntary tips
    /// only, so gratuityFeesCents is a separate additive earnings category.
    /// Older saved JSON has this nil. Those entries predate the explicit
    /// Toast split and may already have gratuity folded into amountCents, so
    /// treating nil as legacy prevents a release from double-counting history.
    var earningsSchemaVersion: Int?

    struct CategorySales: Codable, Equatable, Hashable, Sendable {
        let name: String
        let quantity: Int?
        let netSalesCents: Int?
    }

    struct TipSharingLine: Codable, Equatable, Hashable, Sendable {
        let role: String
        let amountCents: Int
    }

    var guestCount: Int?
    var creditCheckCount: Int?
    var tableCount: Int?
    var tableCountSource: TableCountSource?
    var netSalesCents: Int?
    var taxCents: Int?
    /// Hundredths of one percent: 20.30% is stored as 2,030.
    var printedTipPercentHundredths: Int?
    var averageSpendPerGuestCents: Int?
    var cashSalesCents: Int?
    /// Toast Shift Review's "Total gratuity and fees" row: employee
    /// compensation to be paid out, including mandatory/automatic gratuity.
    /// It is non-tip income and is separate from both voluntary tips and
    /// employer-kept service charges included in restaurant net sales.
    var gratuityFeesCents: Int?
    /// The report-wide all-in amount after sales tax, gratuity/fees, and
    /// non-cash tips. This is intentionally separate from TipEntry.salesCents,
    /// which remains the pre-tip sales basis used by tip-percentage analytics.
    var totalAmountCents: Int?
    var categorySales: [CategorySales]?
    var tipSharing: [TipSharingLine]?

    init(
        earningsSchemaVersion: Int? = nil,
        guestCount: Int? = nil,
        creditCheckCount: Int? = nil,
        tableCount: Int? = nil,
        tableCountSource: TableCountSource? = nil,
        netSalesCents: Int? = nil,
        taxCents: Int? = nil,
        printedTipPercentHundredths: Int? = nil,
        averageSpendPerGuestCents: Int? = nil,
        cashSalesCents: Int? = nil,
        gratuityFeesCents: Int? = nil,
        totalAmountCents: Int? = nil,
        categorySales: [CategorySales]? = nil,
        tipSharing: [TipSharingLine]? = nil
    ) {
        self.earningsSchemaVersion = earningsSchemaVersion
        self.guestCount = guestCount
        self.creditCheckCount = creditCheckCount
        self.tableCount = tableCount
        self.tableCountSource = tableCountSource
        self.netSalesCents = netSalesCents
        self.taxCents = taxCents
        self.printedTipPercentHundredths = printedTipPercentHundredths
        self.averageSpendPerGuestCents = averageSpendPerGuestCents
        self.cashSalesCents = cashSalesCents
        self.gratuityFeesCents = gratuityFeesCents
        self.totalAmountCents = totalAmountCents
        self.categorySales = categorySales
        self.tipSharing = tipSharing
    }

    var isEmpty: Bool {
        guestCount == nil
            && creditCheckCount == nil
            && tableCount == nil
            && netSalesCents == nil
            && taxCents == nil
            && printedTipPercentHundredths == nil
            && averageSpendPerGuestCents == nil
            && cashSalesCents == nil
            && gratuityFeesCents == nil
            && totalAmountCents == nil
            && (categorySales?.isEmpty ?? true)
            && (tipSharing?.isEmpty ?? true)
    }

    var employeeGratuityFeesCents: Int { gratuityFeesCents ?? 0 }

    /// The amount safe to add to the stored TipEntry amount. In v2 the stored
    /// amount is voluntary tips only. Legacy scanner output stored Toast's
    /// combined tips-and-gratuity amount, so its gratuity is already inside.
    var separatedGratuityFeesCents: Int {
        guard (earningsSchemaVersion ?? 1) >= 2 else { return 0 }
        return employeeGratuityFeesCents
    }

    /// Normalizes both storage generations to voluntary tips. This is what
    /// tip percentage and the paystub's Tips line must use.
    func voluntaryTipsCents(fromStoredAmount amountCents: Int) -> Int {
        guard (earningsSchemaVersion ?? 1) < 2 else { return amountCents }
        return max(0, amountCents - employeeGratuityFeesCents)
    }

    /// Normalizes both generations to the same all-in non-tip-out earnings.
    func employeeEarningsCents(fromStoredAmount amountCents: Int) -> Int {
        voluntaryTipsCents(fromStoredAmount: amountCents) + employeeGratuityFeesCents
    }

    /// Adds facts from a newer scan without letting an unreadable or cropped
    /// rescan erase values captured previously. A value that is actually
    /// present in the newer scan wins, including an explicit zero amount.
    func merging(_ newer: ShiftReceiptMetrics) -> ShiftReceiptMetrics {
        let invalidatesInferredTables = tableCountSource == .inferredFromChecks
            && newer.tableCount == nil
            && newer.cashSalesCents.map { $0 != 0 } == true
        let mergedTableCount = invalidatesInferredTables ? nil : (newer.tableCount ?? tableCount)
        let mergedTableCountSource = invalidatesInferredTables ? nil : (newer.tableCountSource ?? tableCountSource)

        return ShiftReceiptMetrics(
            earningsSchemaVersion: newer.earningsSchemaVersion ?? earningsSchemaVersion,
            guestCount: newer.guestCount ?? guestCount,
            creditCheckCount: newer.creditCheckCount ?? creditCheckCount,
            tableCount: mergedTableCount,
            tableCountSource: mergedTableCountSource,
            netSalesCents: newer.netSalesCents ?? netSalesCents,
            taxCents: newer.taxCents ?? taxCents,
            printedTipPercentHundredths: newer.printedTipPercentHundredths ?? printedTipPercentHundredths,
            averageSpendPerGuestCents: newer.averageSpendPerGuestCents ?? averageSpendPerGuestCents,
            cashSalesCents: newer.cashSalesCents ?? cashSalesCents,
            gratuityFeesCents: newer.gratuityFeesCents ?? gratuityFeesCents,
            totalAmountCents: newer.totalAmountCents ?? totalAmountCents,
            categorySales: Self.mergeCategorySales(categorySales, newer.categorySales),
            tipSharing: Self.mergeTipSharing(tipSharing, newer.tipSharing)
        )
    }

    private static func mergeCategorySales(
        _ older: [CategorySales]?,
        _ newer: [CategorySales]?
    ) -> [CategorySales]? {
        mergeRows(older, newer) { $0.name }
    }

    private static func mergeTipSharing(
        _ older: [TipSharingLine]?,
        _ newer: [TipSharingLine]?
    ) -> [TipSharingLine]? {
        mergeRows(older, newer) { $0.role }
    }

    /// A rescan can be cropped, so named receipt rows are updated by identity
    /// while rows absent from the newer image stay intact. Existing order is
    /// retained and genuinely new rows are appended in receipt order.
    private static func mergeRows<Row>(
        _ older: [Row]?,
        _ newer: [Row]?,
        name: (Row) -> String
    ) -> [Row]? {
        guard let newer else { return older }
        guard let older else { return newer }

        var result = older
        var indices: [String: Int] = [:]
        for (index, row) in older.enumerated() {
            indices[normalizedIdentity(name(row))] = index
        }
        for row in newer {
            let identity = normalizedIdentity(name(row))
            if let index = indices[identity] {
                result[index] = row
            } else {
                indices[identity] = result.count
                result.append(row)
            }
        }
        return result
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
