import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private let calculator = PayPeriodCalculator(schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: date(2026, 7, 19), firstWeekday: 2))

@Suite("CSV export")
struct CSVExporterTests {
    @Test("header names every documented column, in order")
    func headerColumns() {
        #expect(CSVExporter.header == "Date,Cash,Credit,Tip-Out,Net,Hours,Sales,Double,Note,Period,Paycheck")
    }

    @Test("one row per night, cash and credit merged, net already accounting for tip-out")
    func mergesCashAndCreditIntoOneRow() {
        let entries = [
            TipEntry(date: date(2026, 7, 8), amountCents: 8600, kind: .credit, tipOutCents: 1500),
            TipEntry(date: date(2026, 7, 8), amountCents: 3200, kind: .cash)
        ]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let rows = csv.split(separator: "\n")
        #expect(rows.count == 2) // header + one merged night
        let fields = rows[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[1] == "32.00") // cash
        #expect(fields[2] == "86.00") // credit
        #expect(fields[3] == "15.00") // tip-out
        #expect(fields[4] == "103.00") // net: 8600 + 3200 - 1500
    }

    @Test("hours, sales, and tip-out columns are blank when nothing was logged for them")
    func blankColumnsWhenUnset() {
        let entries = [TipEntry(date: date(2026, 7, 8), amountCents: 5000, kind: .cash)]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[3] == "") // tip-out
        #expect(fields[5] == "") // hours
        #expect(fields[6] == "") // sales
    }

    @Test("double shift is marked Y, an ordinary shift is marked N")
    func doubleColumn() {
        let entries = [
            TipEntry(date: date(2026, 7, 8), amountCents: 5000, kind: .cash, isDouble: true),
            TipEntry(date: date(2026, 7, 9), amountCents: 5000, kind: .cash, isDouble: false)
        ]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let rows = csv.split(separator: "\n")
        #expect(rows[1].contains(",Y,"))
        #expect(rows[2].contains(",N,"))
    }

    @Test("a note containing a comma is quoted and escaped")
    func noteWithCommaIsQuoted() {
        let entries = [TipEntry(date: date(2026, 7, 8), amountCents: 5000, kind: .cash, note: "slow night, rainy")]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        #expect(csv.contains("\"slow night, rainy\""))
    }

    @Test("period and paycheck columns reflect the night's own period")
    func periodAndPaycheckColumns() {
        let period = calculator.period(containing: date(2026, 7, 8))
        let entries = [TipEntry(date: date(2026, 7, 8), amountCents: 5000, kind: .credit)]
        let paycheck = PaycheckRecord(periodStart: period.start, periodEnd: period.end, paidTipsCents: 4800)
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [paycheck], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[10] == "48.00")
        #expect(fields[9].contains("to"))
    }

    @Test("hours/tip-out/sales set on BOTH entries (corruption) resolve to one canonical value, never a sum")
    func shiftDetailsNeverDoubleCountAcrossEntries() {
        let entries = [
            TipEntry(date: date(2026, 7, 8), amountCents: 8600, kind: .credit, hoursWorked: 5, tipOutCents: 1500, salesCents: 43000),
            TipEntry(date: date(2026, 7, 8), amountCents: 3200, kind: .cash, hoursWorked: 5, tipOutCents: 1000, salesCents: 10000)
        ]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[3] == "15.00") // tip-out: credit's value, not 15+10
        #expect(fields[5] == "5") // hours: credit's value, not 5+5
        #expect(fields[6] == "430.00") // sales: credit's value, not 430+100
        #expect(fields[4] == "103.00") // net: 8600+3200-1500, not -2500
    }

    @Test("rows are ordered chronologically, oldest first")
    func rowsChronological() {
        let entries = [
            TipEntry(date: date(2026, 7, 9), amountCents: 5000, kind: .cash),
            TipEntry(date: date(2026, 7, 8), amountCents: 5000, kind: .cash)
        ]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let rows = csv.split(separator: "\n")
        #expect(rows[1].hasPrefix("2026-07-08"))
        #expect(rows[2].hasPrefix("2026-07-09"))
    }
}
