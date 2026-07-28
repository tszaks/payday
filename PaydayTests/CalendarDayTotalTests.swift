import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Mirrors the exact formula CalendarView.dailyTotals (day tiles) and
/// DayDetailSheet.totalCents share: a day's tips net (TipBreakdown) plus
/// that day's shifts' wages (WageEstimate.centsSummedPerShift, summed per
/// shift then combined — see that function's own rounding note). Both
/// surfaces speak Total now (Tyler's money-language law, 2026-07-27): no
/// day on the calendar screen should read tips-only next to a wage-inclusive
/// month header.
@Suite("Calendar/DayDetail day total — Total basis (tips net + wages)")
struct CalendarDayTotalTests {
    private func dayTotalCents(entries: [TipEntry], wageCentsPerHour: Int?) -> Int {
        let tipsNet = TipBreakdown.total(of: entries).netTotalCents
        let shifts = ShiftDays.groupedByShift(entries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
        let wageCents = WageEstimate.centsSummedPerShift(shiftGroups: shifts.map(\.items), wageCentsPerHour: wageCentsPerHour)
        return tipsNet + wageCents
    }

    @Test("with hours logged and a rate set, the day total is tips net PLUS wages")
    func totalIsTipsNetPlusWagesWhenRateSet() {
        let day = date(2026, 7, 15)
        let entries = [
            TipEntry(date: day, amountCents: 6000, kind: .cash, hoursWorked: 5, tipOutCents: 1000),
            TipEntry(date: day, amountCents: 4000, kind: .credit, hoursWorked: 5)
        ]
        // Tips net: (6000 + 4000) - 1000 = 9000. Wages: 5h * 283¢/hr = 1415¢.
        let total = dayTotalCents(entries: entries, wageCentsPerHour: 283)
        #expect(total == 9000 + 1415)
        #expect(total != TipBreakdown.total(of: entries).netTotalCents)
    }

    @Test("with no wage rate set, the day total is exactly tips net — no wages fabricated")
    func totalIsTipsNetOnlyWhenNoRate() {
        let day = date(2026, 7, 15)
        let entries = [
            TipEntry(date: day, amountCents: 6000, kind: .cash, hoursWorked: 5, tipOutCents: 1000),
            TipEntry(date: day, amountCents: 4000, kind: .credit, hoursWorked: 5)
        ]
        let total = dayTotalCents(entries: entries, wageCentsPerHour: nil)
        #expect(total == TipBreakdown.total(of: entries).netTotalCents)
        #expect(total == 9000)
    }
}
