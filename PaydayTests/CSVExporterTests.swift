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
        #expect(CSVExporter.header == "Date,Shift,Cash,Credit,Tip-Out,Net,Hours,Start,End,Sales,Double,Note,Period,Paycheck")
    }

    @Test("one row per shift, cash and credit merged, net already accounting for tip-out")
    func mergesCashAndCreditIntoOneRow() {
        let shift = UUID()
        let entries = [
            TipEntry(date: date(2026, 7, 8), amountCents: 8600, kind: .credit, tipOutCents: 1500, shiftID: shift),
            TipEntry(date: date(2026, 7, 8), amountCents: 3200, kind: .cash, shiftID: shift)
        ]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let rows = csv.split(separator: "\n")
        #expect(rows.count == 2) // header + one merged shift
        let fields = rows[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[2] == "32.00") // cash
        #expect(fields[3] == "86.00") // credit
        #expect(fields[4] == "15.00") // tip-out
        #expect(fields[5] == "103.00") // net: 8600 + 3200 - 1500
    }

    @Test("hours, start, end, sales, and tip-out columns are blank when nothing was logged for them")
    func blankColumnsWhenUnset() {
        let entries = [TipEntry(date: date(2026, 7, 8), amountCents: 5000, kind: .cash)]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[4] == "") // tip-out
        #expect(fields[6] == "") // hours
        #expect(fields[7] == "") // start
        #expect(fields[8] == "") // end
        #expect(fields[9] == "") // sales
    }

    @Test("clock times export as fixed 24-hour HH:mm, regardless of locale-facing am/pm copy elsewhere")
    func startEndColumnsPopulated() {
        let day = date(2026, 7, 8)
        let calendar = Calendar.current
        let clockIn = calendar.date(bySettingHour: 17, minute: 30, second: 0, of: day)!
        let clockOut = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day)!
        let entries = [TipEntry(date: day, amountCents: 5000, kind: .cash, clockIn: clockIn, clockOut: clockOut)]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[7] == "17:30")
        #expect(fields[8] == "22:00")
    }

    @Test("a shift on a double day is marked Y; a lone shift is marked N")
    func doubleColumn() {
        let entries = [
            // Two closeouts on 7/8 → a double day → both rows flagged Y.
            TipEntry(date: date(2026, 7, 8), amountCents: 5000, kind: .cash, shiftID: UUID()),
            TipEntry(date: date(2026, 7, 8), amountCents: 4000, kind: .cash, shiftID: UUID()),
            // One closeout on 7/9 → N.
            TipEntry(date: date(2026, 7, 9), amountCents: 5000, kind: .cash, shiftID: UUID())
        ]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let rows = csv.split(separator: "\n")
        #expect(rows[1].contains(",Y,"))
        #expect(rows[2].contains(",Y,"))
        #expect(rows[3].contains(",N,"))
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
        #expect(fields[13] == "48.00")
        #expect(fields[12].contains("to"))
    }

    @Test("hours/tip-out/sales set on BOTH entries (corruption) resolve to one canonical value, never a sum")
    func shiftDetailsNeverDoubleCountAcrossEntries() {
        let shift = UUID()
        let entries = [
            TipEntry(date: date(2026, 7, 8), amountCents: 8600, kind: .credit, hoursWorked: 5, tipOutCents: 1500, salesCents: 43000, shiftID: shift),
            TipEntry(date: date(2026, 7, 8), amountCents: 3200, kind: .cash, hoursWorked: 5, tipOutCents: 1000, salesCents: 10000, shiftID: shift)
        ]
        let csv = CSVExporter.export(entries: entries, paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[4] == "15.00") // tip-out: credit's value, not 15+10
        #expect(fields[6] == "5") // hours: credit's value, not 5+5
        #expect(fields[9] == "430.00") // sales: credit's value, not 430+100
        #expect(fields[5] == "103.00") // net: 8600+3200-1500, not -2500
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
