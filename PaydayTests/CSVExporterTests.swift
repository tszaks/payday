import Testing
import Foundation
import SwiftData
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private let calculator = PayPeriodCalculator(payrollTimeZone: PaydayTestZone.payroll, schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: date(2026, 7, 19), firstWeekday: 2))

@MainActor
private func makeContext() throws -> ModelContext {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: ShiftRecord.self, PaycheckRecord.self, configurations: config)
    return ModelContext(container)
}

@Suite("CSV export")
@MainActor
struct CSVExporterTests {
    /// Locate a cell by HEADER NAME, never by index.
    ///
    /// Fixture E1 requires this of readers, and for the reason the rest of
    /// this file demonstrates: 25 assertions below still reach for
    /// `fields[7]`, and they only survived this slice appending six columns
    /// because the columns were appended at the END rather than inserted. The
    /// next person who inserts one breaks all of them at once. New assertions
    /// use this.
    static func cell(_ csv: String, row: Int = 1, column: String) -> String? {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > row else { return nil }
        let headers = CSVExporter.header.split(separator: ",").map(String.init)
        guard let index = headers.firstIndex(of: column) else { return nil }
        let fields = lines[row].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count > index else { return nil }
        return fields[index]
    }

    @Test("header names every documented column, in order")
    func headerColumns() {
        // The six engine columns are APPENDED, not inserted, so an existing
        // spreadsheet formula keyed on column position keeps working. See the
        // comment on CSVExporter.header.
        #expect(CSVExporter.header == "Date,Shift,Cash,Credit,Gratuity-Fees,Tip-Out,Net,Hours,Start,End,Sales,Servers,Double,Note,Period,Paycheck,Hours-Clock,Non-Wage-Earnings,Regular-Wages,Overtime-Wages,Earned-Income,Completeness")
    }

    /// The first sixteen columns keep both their names and their positions,
    /// which is the promise "appended, never inserted" makes to a file
    /// somebody already built on.
    @Test("appending the engine columns did not move any existing column")
    func existingColumnsDidNotMove() {
        let shipped = ["Date", "Shift", "Cash", "Credit", "Gratuity-Fees", "Tip-Out",
                       "Net", "Hours", "Start", "End", "Sales", "Servers", "Double",
                       "Note", "Period", "Paycheck"]
        let headers = CSVExporter.header.split(separator: ",").map(String.init)
        #expect(Array(headers.prefix(shipped.count)) == shipped)
    }

    @Test("one row per shift, cash and credit merged, net already accounting for tip-out")
    func mergesCashAndCreditIntoOneRow() {
        let records = [
            ShiftRecord(workDate: date(2026, 7, 8), cashTipsCents: 3_200,
                        creditTipsCents: 8_600, tipOutCents: 1_500)
        ]
        let csv = CSVExporter.export(records: records, paycheckRecords: [], calculator: calculator)
        let rows = csv.split(separator: "\n")
        #expect(rows.count == 2) // header + one shift
        let fields = rows[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[2] == "32.00") // cash
        #expect(fields[3] == "86.00") // credit
        #expect(fields[4] == "") // gratuity/fees
        #expect(fields[5] == "15.00") // tip-out
        #expect(fields[6] == "103.00") // net: 8600 + 3200 - 1500
    }

    @Test("hours, start, end, sales, servers, and tip-out columns are blank when nothing was logged for them")
    func blankColumnsWhenUnset() {
        let records = [ShiftRecord(workDate: date(2026, 7, 8), cashTipsCents: 5_000)]
        let csv = CSVExporter.export(records: records, paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[4] == "") // gratuity/fees
        #expect(fields[5] == "") // tip-out
        #expect(fields[7] == "") // hours
        #expect(fields[8] == "") // start
        #expect(fields[9] == "") // end
        #expect(fields[10] == "") // sales
        #expect(fields[11] == "") // servers
    }

    @Test("Toast employee gratuity exports separately and contributes to net earnings")
    func gratuityColumnIsSeparate() {
        let record = ShiftRecord(
            workDate: date(2026, 8, 23),
            creditTipsCents: 12_136,
            tipOutCents: 2_243,
            receiptMetrics: ShiftReceiptMetrics(
                earningsSchemaVersion: 2,
                gratuityFeesCents: 4_050
            )
        )

        let csv = CSVExporter.export(records: [record], paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        #expect(fields[3] == "121.36")
        #expect(fields[4] == "40.50")
        #expect(fields[5] == "22.43")
        #expect(fields[6] == "139.43")
    }

    @Test("servers column exports the canonical count when logged")
    func serversColumnPopulated() {
        let records = [ShiftRecord(workDate: date(2026, 7, 8), cashTipsCents: 5_000, serverCount: 3)]
        let csv = CSVExporter.export(records: records, paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[11] == "3")
    }

    @Test("clock times export as fixed 24-hour HH:mm, regardless of locale-facing am/pm copy elsewhere")
    func startEndColumnsPopulated() {
        let day = date(2026, 7, 8)
        let calendar = Calendar.current
        let clockIn = calendar.date(bySettingHour: 17, minute: 30, second: 0, of: day)!
        let clockOut = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day)!
        let records = [ShiftRecord(workDate: day, cashTipsCents: 5_000, clockIn: clockIn, clockOut: clockOut)]
        let csv = CSVExporter.export(records: records, paycheckRecords: [], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[8] == "17:30")
        #expect(fields[9] == "22:00")
    }

    @Test("a shift on a double day is marked Y; a lone shift is marked N")
    func doubleColumn() {
        let records = [
            // Two closeouts on 7/8 → a double day → both rows flagged Y.
            ShiftRecord(workDate: date(2026, 7, 8), shiftPeriod: .lunch, cashTipsCents: 5_000),
            ShiftRecord(workDate: date(2026, 7, 8), shiftPeriod: .dinner, cashTipsCents: 4_000),
            // One closeout on 7/9 → N.
            ShiftRecord(workDate: date(2026, 7, 9), cashTipsCents: 5_000)
        ]
        let csv = CSVExporter.export(records: records, paycheckRecords: [], calculator: calculator)
        let rows = csv.split(separator: "\n")
        #expect(rows[1].contains(",Y,"))
        #expect(rows[2].contains(",Y,"))
        #expect(rows[3].contains(",N,"))
    }

    @Test("a note containing a comma is quoted and escaped")
    func noteWithCommaIsQuoted() {
        let records = [ShiftRecord(workDate: date(2026, 7, 8), cashTipsCents: 5_000, note: "slow night, rainy")]
        let csv = CSVExporter.export(records: records, paycheckRecords: [], calculator: calculator)
        #expect(csv.contains("\"slow night, rainy\""))
    }

    @Test("period and paycheck columns reflect the night's own period")
    func periodAndPaycheckColumns() {
        let period = calculator.period(containing: date(2026, 7, 8))
        let records = [ShiftRecord(workDate: date(2026, 7, 8), creditTipsCents: 5_000)]
        let paycheck = PaycheckRecord(periodStart: period.start, periodEnd: period.end, paidTipsCents: 4800)
        let csv = CSVExporter.export(records: records, paycheckRecords: [paycheck], calculator: calculator)
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[15] == "48.00")
        #expect(fields[14].contains("to"))
    }

    /// The corruption this used to pin — hours/tip-out/sales on BOTH of a
    /// shift's entries — is unrepresentable on `ShiftRecord`, which carries
    /// one of each. What survives is the contract: the columns render the
    /// record's own values, and Net is net of the shift's tip-out.
    @Test("the shift-level columns render the record's canonical values")
    func shiftDetailsRenderCanonically() {
        let records = [
            ShiftRecord(workDate: date(2026, 7, 8), cashTipsCents: 3_200,
                        creditTipsCents: 8_600, tipOutCents: 1_500,
                        salesCents: 43_000, hoursWorked: 5)
        ]
        let csv = CSVExporter.export(records: records, paycheckRecords: [], calculator: calculator)
        // By header name, per E1's rule, rather than by index.
        #expect(Self.cell(csv, column: "Tip-Out") == "15.00")
        // "5.0000" and not "5": hours are now a fixed four decimal places, so
        // the column has one width and a spreadsheet can compute on it. The
        // old renderer trimmed trailing zeros AND rounded to the quarter hour,
        // and it is the rounding that fixture E1 forbids.
        #expect(Self.cell(csv, column: "Hours") == "5.0000")
        #expect(Self.cell(csv, column: "Hours-Clock") == "5:00")
        #expect(Self.cell(csv, column: "Sales") == "430.00")
        #expect(Self.cell(csv, column: "Net") == "103.00", "8600+3200-1500")
    }

    @Test("rows are ordered chronologically, oldest first")
    func rowsChronological() {
        let records = [
            ShiftRecord(workDate: date(2026, 7, 9), cashTipsCents: 5_000),
            ShiftRecord(workDate: date(2026, 7, 8), cashTipsCents: 5_000)
        ]
        let csv = CSVExporter.export(records: records, paycheckRecords: [], calculator: calculator)
        let rows = csv.split(separator: "\n")
        #expect(rows[1].hasPrefix("2026-07-08"))
        #expect(rows[2].hasPrefix("2026-07-09"))
    }
}

@Suite("PaycheckRecord stub details")
@MainActor
struct PaycheckRecordStubDetailsTests {
    @Test("all four detail fields persist and read back through SwiftData")
    func roundtripAllSet() throws {
        let context = try makeContext()
        let record = PaycheckRecord(
            periodStart: date(2026, 7, 1),
            periodEnd: date(2026, 7, 15),
            paidTipsCents: 10000,
            hourlyRateCents: 1250,
            owedTipsCents: 500,
            grossPayCents: 150000,
            netPayCents: 110000
        )
        context.insert(record)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PaycheckRecord>()).first
        #expect(fetched?.hourlyRateCents == 1250)
        #expect(fetched?.owedTipsCents == 500)
        #expect(fetched?.grossPayCents == 150000)
        #expect(fetched?.netPayCents == 110000)
    }

    @Test("all four detail fields stay nil when never entered")
    func roundtripAllNil() throws {
        let context = try makeContext()
        let record = PaycheckRecord(periodStart: date(2026, 7, 1), periodEnd: date(2026, 7, 15), paidTipsCents: 10000)
        context.insert(record)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PaycheckRecord>()).first
        #expect(fetched?.hourlyRateCents == nil)
        #expect(fetched?.owedTipsCents == nil)
        #expect(fetched?.grossPayCents == nil)
        #expect(fetched?.netPayCents == nil)
    }

    // Mirrors PaycheckEntrySheet.save()'s effective-cents conversion — the
    // same "value > 0 ? value : nil" rule LogTipSheet applies to tip-out.
    private func effectiveCents(_ value: Int) -> Int? { value > 0 ? value : nil }

    @Test("zero-valued entry fields save as nil")
    func zeroEntrySavesAsNil() {
        let record = PaycheckRecord(
            periodStart: date(2026, 7, 1),
            periodEnd: date(2026, 7, 15),
            paidTipsCents: 10000,
            hourlyRateCents: effectiveCents(0),
            owedTipsCents: effectiveCents(0),
            grossPayCents: effectiveCents(0),
            netPayCents: effectiveCents(0)
        )
        #expect(record.hourlyRateCents == nil)
        #expect(record.owedTipsCents == nil)
        #expect(record.grossPayCents == nil)
        #expect(record.netPayCents == nil)
    }

    @Test("non-zero entry fields save as exact cents")
    func nonZeroEntrySavesExactCents() {
        let record = PaycheckRecord(
            periodStart: date(2026, 7, 1),
            periodEnd: date(2026, 7, 15),
            paidTipsCents: 10000,
            hourlyRateCents: effectiveCents(1275),
            owedTipsCents: effectiveCents(2200),
            grossPayCents: effectiveCents(150000),
            netPayCents: effectiveCents(110000)
        )
        #expect(record.hourlyRateCents == 1275)
        #expect(record.owedTipsCents == 2200)
        #expect(record.grossPayCents == 150000)
        #expect(record.netPayCents == 110000)
    }
}

/// Fixture E1's CSV half, which had no assertion anywhere until now.
///
/// E1 was one of two golden fixtures the plan requires to pass "against the
/// real production engine, never a test helper", and its only referencing
/// test pinned cross-fixture invariants without running an engine. Its
/// adapter half (383 minutes out of the legacy Double) was covered by
/// `ShiftInputAdapterTests`; this is the exported row.
///
/// The wage here comes from `CompensationLedger` rather than a literal, so a
/// change to the ledger's rounding fails this test instead of quietly
/// disagreeing with it.
@Suite("CSV export: fixture E1")
@MainActor
struct CSVExporterE1Tests {
    private static let shiftID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PaydayTestZone.payroll
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 17))!
    }

    /// 283c/h, the rate E1 declares, on a Monday-start workweek.
    private static func policies() -> (rates: [PayRatePolicy], calendars: [PayrollCalendarPolicy]) {
        (
            [PayRatePolicy(
                id: PolicyMigration.deterministicID("e1/rate"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 283,
                provenance: .confirmed
            )],
            [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("e1/calendar"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: PaydayTestZone.payroll
            )]
        )
    }

    @Test("E1: the exported row carries 6.3833, 6:23 and the engine's components")
    func e1Row() throws {
        // Non-wage 11500 as E1 declares it: cash 5000 + credit 6500, no
        // gratuity, no tip-out.
        let hours = 6.383333333333334
        let records = [
            ShiftRecord(
                id: Self.shiftID,
                workDate: Self.date(2026, 9, 29),
                cashTipsCents: 5_000,
                creditTipsCents: 6_500,
                hoursWorked: hours
            )
        ]

        // The REAL ledger, not a literal wage.
        let policies = Self.policies()
        let valuation = try #require(CompensationLedger.value(
            [ShiftInput(
                id: Self.shiftID,
                workDay: CivilDay(year: 2026, month: 9, day: 29),
                voluntaryCashCents: 5_000,
                voluntaryCreditCents: 6_500,
                minutesWorked: HoursFormatting.minutes(fromHours: hours)
            )],
            rates: policies.rates,
            calendars: policies.calendars
        ).first)

        // E1 pins the pay period as 2026-09-21 to 2026-10-04, which is a
        // SCHEDULE fact rather than an engine one, so the schedule is stated
        // rather than left to `.fallback` (whose anchor is `.now` and would
        // make this assertion depend on the day the suite runs).
        let calculator = PayPeriodCalculator(
            payrollTimeZone: PaydayTestZone.payroll,
            schedule: PaySchedule(
                frequency: .biweekly,
                anchorPeriodEnd: Self.date(2026, 10, 4)
            )
        )
        let csv = CSVExporter.export(
            records: records,
            paycheckRecords: [],
            calculator: calculator,
            valuations: [Self.shiftID: valuation]
        )

        // Located by header name, never index, which is E1's own rule.
        #expect(CSVExporterTests.cell(csv, column: "Hours") == "6.3833")
        #expect(CSVExporterTests.cell(csv, column: "Hours-Clock") == "6:23")
        #expect(CSVExporterTests.cell(csv, column: "Non-Wage-Earnings") == "115.00")
        #expect(CSVExporterTests.cell(csv, column: "Regular-Wages") == "18.06")
        #expect(CSVExporterTests.cell(csv, column: "Overtime-Wages") == "0.00")
        #expect(CSVExporterTests.cell(csv, column: "Earned-Income") == "133.06")
        #expect(CSVExporterTests.cell(csv, column: "Completeness") == "complete")
        // No paycheck recorded for this period, so the cell is empty.
        #expect(CSVExporterTests.cell(csv, column: "Paycheck") == "")
        // E1 also pins the pay period this shift falls in, which depends on
        // the schedule rather than on the engine. Asserted so the fixture is
        // covered cell for cell rather than mostly.
        #expect(CSVExporterTests.cell(csv, column: "Period") == "2026-09-21 to 2026-10-04")
    }

    /// The three renderings E1 names as wrong, refused in the exported file
    /// itself rather than only in the formatter's unit test. The shipped
    /// exporter produced the first of them.
    @Test("E1: the exported hours are never the quarter-hour answer")
    func e1RefusesTheQuarterHour() {
        let records = [
            ShiftRecord(
                id: Self.shiftID,
                workDate: Self.date(2026, 9, 29),
                creditTipsCents: 6_500,
                hoursWorked: 6.383333333333334
            )
        ]
        let csv = CSVExporter.export(
            records: records, paycheckRecords: [],
            calculator: PayPeriodCalculator(
                payrollTimeZone: PaydayTestZone.payroll, schedule: .fallback))
        let hours = CSVExporterTests.cell(csv, column: "Hours")
        #expect(hours != "6.5", "what the shipped exporter wrote")
        #expect(hours != "6.4")
        #expect(hours != "6.38")
        #expect(hours == "6.3833")
    }

    /// A shift with no engine answer leaves the five engine columns EMPTY, not
    /// zero. In a file someone may take to a payroll dispute, a blank saying
    /// "not computed" and a zero saying "you earned nothing" are not
    /// interchangeable.
    @Test("a shift with no valuation exports blanks, never zeros")
    func noValuationExportsBlanks() {
        let records = [
            ShiftRecord(
                id: Self.shiftID,
                workDate: Self.date(2026, 9, 29),
                creditTipsCents: 6_500,
                hoursWorked: 6.0
            )
        ]
        let csv = CSVExporter.export(
            records: records, paycheckRecords: [],
            calculator: PayPeriodCalculator(
                payrollTimeZone: PaydayTestZone.payroll, schedule: .fallback))

        for column in ["Non-Wage-Earnings", "Regular-Wages", "Overtime-Wages",
                       "Earned-Income", "Completeness"] {
            #expect(CSVExporterTests.cell(csv, column: column) == "",
                    "\(column) must be blank, not 0.00")
        }
        // The hours still export, because those are a logged fact and not an
        // engine result.
        #expect(CSVExporterTests.cell(csv, column: "Hours") == "6.0000")
    }
}
