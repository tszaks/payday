import Foundation

/// Turns logged shifts into a plain CSV, one row per calendar night (cash
/// and credit merged, same "a shift, not a row" rule as ShiftDayRow) — a
/// pure, fully-tested function, no SwiftUI, no file I/O of its own.
///
/// Hours/Tip-Out/Sales are shift-level facts, not per-entry ones: each
/// column reflects ShiftDetails.resolve's single canonical value (credit
/// entry preferred, else cash), never a sum across the night's entries —
/// a night with a stray value on both entries (legacy data) still reports
/// one number here, matching every other reader in the app, rather than
/// double-counting it.
enum CSVExporter {
    static let header = "Date,Cash,Credit,Tip-Out,Net,Hours,Sales,Double,Note,Period,Paycheck"

    static func export(entries: [TipEntry], paycheckRecords: [PaycheckRecord], calculator: PayPeriodCalculator, calendar: Calendar = .current) -> String {
        let shiftDays = ShiftDays.groupedByDay(entries, date: \.date).sorted { $0.day < $1.day }
        let rows = shiftDays.map { group -> String in
            row(for: group.items, day: group.day, paycheckRecords: paycheckRecords, calculator: calculator, calendar: calendar)
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private static func row(for items: [TipEntry], day: Date, paycheckRecords: [PaycheckRecord], calculator: PayPeriodCalculator, calendar: Calendar) -> String {
        let cashCents = items.filter { $0.kind == .cash }.reduce(0) { $0 + $1.amountCents }
        let creditCents = items.filter { $0.kind == .credit }.reduce(0) { $0 + $1.amountCents }
        let shiftDetails = ShiftDetails.resolve(from: items)
        let netCents = cashCents + creditCents - (shiftDetails.tipOutCents ?? 0)
        let isDouble = items.contains { $0.isDouble }
        let note = items.compactMap(\.note).joined(separator: "; ")

        let period = calculator.period(containing: day)
        let paycheck = paycheckRecords.first { $0.periodEnd >= period.start && $0.periodEnd <= period.end }

        // Bound individually rather than inline in the array literal below —
        // that many chained `.map(...) ?? ""` expressions in one array
        // literal was slow enough to trip the type checker's time budget.
        let tipOutField: String = shiftDetails.tipOutCents.map(dollars) ?? ""
        let hoursField: String = shiftDetails.hoursWorked.map(trimmedHours) ?? ""
        let salesField: String = shiftDetails.salesCents.map(dollars) ?? ""
        let paycheckField: String = paycheck.map { dollars($0.paidTipsCents) } ?? ""
        let periodField = "\(isoDate(period.start)) to \(isoDate(period.end))"

        let fields = [
            isoDate(day),
            dollars(cashCents),
            dollars(creditCents),
            tipOutField,
            dollars(netCents),
            hoursField,
            salesField,
            isDouble ? "Y" : "N",
            escape(note),
            periodField,
            paycheckField
        ]
        return fields.joined(separator: ",")
    }

    private static func isoDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    private static func dollars(_ cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100)
    }

    private static func trimmedHours(_ hours: Double) -> String {
        var formatted = String(format: "%.2f", (hours * 4).rounded() / 4)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return formatted
    }

    /// Quotes and escapes a field only when it actually needs it — a plain
    /// note with no comma, quote, or newline stays unquoted.
    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
