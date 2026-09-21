import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 17))!
}

/// The day total both Calendar surfaces show, measured through the REAL
/// adapters rather than through a local re-implementation of their formula.
///
/// Until PR 5 wave 1 this suite mirrored `CalendarView.dailyTotals` and
/// `DayDetailSheet.totalCents` in its own helper ("tips net plus
/// `WageEstimate.centsSummedPerShift`"). Both screens now ask
/// `EarningsSnapshot` instead, so mirroring the old formula would have pinned
/// code nothing renders. The CLAIMS are unchanged and still the point: both
/// surfaces speak Total on a wage-inclusive basis (Tyler's money-language law,
/// 2026-07-27, so no day on the calendar screen reads tips-only next to a
/// wage-inclusive month header), and no wage is fabricated when no rate is on
/// file.
@Suite("Calendar/DayDetail day total — Total basis (tips net + wages)")
@MainActor
struct CalendarDayTotalTests {
    private func policies(rateCents: Int?) -> CompensationPolicies {
        let calendar = PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("daytotal/calendar"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: 2,
            payrollTimeZone: PaydayTestZone.payroll
        )
        guard let rateCents else { return CompensationPolicies(rates: [], calendars: [calendar]) }
        return CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("daytotal/rate/\(rateCents)"),
                effectiveFrom: .distantPast,
                hourlyRateCents: rateCents,
                provenance: .confirmed
            )],
            calendars: [calendar]
        )
    }

    /// The tile and the sheet, over one dataset, for the same day.
    private func surfaces(
        records: [ShiftRecord],
        on day: Date,
        rateCents: Int?
    ) -> (tile: CalendarDayTile?, sheet: DayDetailFacts) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PaydayTestZone.payroll
        calendar.firstWeekday = 2
        let resolved = policies(rateCents: rateCents)
        let month = CalendarMonthFacts(
            snapshot: CalendarEarnings.snapshot(
                records: records,
                policies: resolved,
                payrollTimeZone: PaydayTestZone.payroll
            ),
            displayedMonth: day,
            calendar: calendar
        )
        return (
            month.tile(on: day),
            DayDetailFacts(
                shiftRecords: records,
                date: day,
                policies: resolved,
                payrollTimeZone: PaydayTestZone.payroll
            )
        )
    }

    /// One lunch shift and one dinner shift on the same day: $60.00 cash and
    /// $40.00 credit, $10.00 tipped out, ten hours total. Tips net = 9000.
    private func twoShiftDay() -> [ShiftRecord] {
        [
            ShiftRecord(
                workDate: date(2026, 7, 15), shiftPeriod: .lunch,
                cashTipsCents: 6_000, tipOutCents: 1_000, hoursWorked: 5,
                recordedAt: date(2026, 7, 15)
            ),
            ShiftRecord(
                workDate: date(2026, 7, 15).addingTimeInterval(3600), shiftPeriod: .dinner,
                creditTipsCents: 4_000, hoursWorked: 5,
                recordedAt: date(2026, 7, 15).addingTimeInterval(3600)
            ),
        ]
    }

    @Test("with hours logged and a rate set, the day total is tips net PLUS wages, on both surfaces")
    func totalIsTipsNetPlusWagesWhenRateSet() throws {
        let day = date(2026, 7, 15)
        let records = twoShiftDay()
        // Tips net: (6000 + 4000) - 1000 = 9000. Wages: 10h at 283c/hr, one
        // week, under the threshold, so 2830c straight time.
        let (tile, sheet) = surfaces(records: records, on: day, rateCents: 283)
        let total = try #require(sheet.total.cents)
        #expect(total == 9_000 + 2_830)
        #expect(total != 9_000)
        // The tile that opens the sheet reads the same figure.
        #expect(tile?.figure.cents == total)
    }

    @Test("with no wage rate set, the day total is exactly tips net — no wages fabricated")
    func totalIsTipsNetOnlyWhenNoRate() throws {
        let day = date(2026, 7, 15)
        let records = twoShiftDay()
        let (tile, sheet) = surfaces(records: records, on: day, rateCents: nil)
        let total = try #require(sheet.total.cents)
        #expect(total == 9_000)
        #expect(tile?.figure.cents == total)
        // Wages off, so the figure IS non-wage earnings and takes a non-wage
        // label rather than naming a metric it is not.
        #expect(sheet.total.metric == .nonWageEarnings)
    }
}
