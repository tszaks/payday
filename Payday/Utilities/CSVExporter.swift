import Foundation

/// Turns logged shifts into a plain CSV, one row per shift (one closeout;
/// cash and credit merged, same "a shift, not a row" rule as ShiftDayRow) —
/// a pure, fully-tested function, no SwiftUI, no file I/O of its own. A
/// double day produces two rows, one per closeout, distinguished by the
/// Shift column and both flagged Double.
///
/// Hours/Start/End/Tip-Out/Sales/Servers are shift-level facts, not
/// per-entry ones: each column reflects ShiftDetails.resolve's single
/// canonical value (credit entry preferred, else cash), never a sum across
/// the shift's entries — a shift with a stray value on both entries (legacy
/// data) still reports one number here, matching every other reader in the
/// app, rather than double-counting it.
enum CSVExporter {
    static let header = "Date,Shift,Cash,Credit,Tip-Out,Net,Hours,Start,End,Sales,Servers,Double,Note,Period,Paycheck"

    static func export(entries: [TipEntry], paycheckRecords: [PaycheckRecord], calculator: PayPeriodCalculator, calendar: Calendar = .current) -> String {
        let shifts = ShiftDays.groupedByShift(entries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod, calendar: calendar)
            .sorted { $0.day < $1.day }
        var dayShiftCounts: [Date: Int] = [:]
        for shift in shifts { dayShiftCounts[shift.day, default: 0] += 1 }
        let rows = shifts.map { group -> String in
            row(for: group.items, day: group.day, dayHasMultipleShifts: (dayShiftCounts[group.day] ?? 0) >= 2, paycheckRecords: paycheckRecords, calculator: calculator, calendar: calendar)
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private static func row(for items: [TipEntry], day: Date, dayHasMultipleShifts: Bool, paycheckRecords: [PaycheckRecord], calculator: PayPeriodCalculator, calendar: Calendar) -> String {
        let cashCents = items.filter { $0.kind == .cash }.reduce(0) { $0 + $1.amountCents }
        let creditCents = items.filter { $0.kind == .credit }.reduce(0) { $0 + $1.amountCents }
        let shiftDetails = ShiftDetails.resolve(from: items)
        let netCents = cashCents + creditCents - (shiftDetails.tipOutCents ?? 0)
        let shiftField = shiftDetails.shiftPeriod?.displayName ?? ""
        let note = items.compactMap(\.note).joined(separator: "; ")

        let period = calculator.period(containing: day)
        let paycheck = paycheckRecords.first { $0.periodEnd >= period.start && $0.periodEnd <= period.end }

        // Bound individually rather than inline in the array literal below —
        // that many chained `.map(...) ?? ""` expressions in one array
        // literal was slow enough to trip the type checker's time budget.
        let tipOutField: String = shiftDetails.tipOutCents.map(dollars) ?? ""
        let hoursField: String = shiftDetails.hoursWorked.map(trimmedHours) ?? ""
        let startField: String = shiftDetails.clockIn.map { time24($0, calendar: calendar) } ?? ""
        let endField: String = shiftDetails.clockOut.map { time24($0, calendar: calendar) } ?? ""
        let salesField: String = shiftDetails.salesCents.map(dollars) ?? ""
        let serversField: String = shiftDetails.serverCount.map(String.init) ?? ""
        let paycheckField: String = paycheck.map { dollars($0.paidTipsCents) } ?? ""
        let periodField = "\(isoDate(period.start)) to \(isoDate(period.end))"

        let fields = [
            isoDate(day),
            shiftField,
            dollars(cashCents),
            dollars(creditCents),
            tipOutField,
            dollars(netCents),
            hoursField,
            startField,
            endField,
            salesField,
            serversField,
            dayHasMultipleShifts ? "Y" : "N",
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

    /// Fixed 24-hour "HH:mm" — deliberately locale-independent, unlike the
    /// am/pm rendering Moves and Insights narration use for prose. A CSV
    /// column needs one unambiguous format regardless of who opens it, same
    /// reasoning as isoDate below.
    private static func time24(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    /// Quotes and escapes a field only when it actually needs it — a plain
    /// note with no comma, quote, or newline stays unquoted.
    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
