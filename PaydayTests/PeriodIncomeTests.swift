import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func shift(_ day: Date, hours: Double) -> TipEntry {
    TipEntry(date: day, amountCents: 5000, kind: .credit, hoursWorked: hours)
}

@Suite("PeriodIncome wages")
struct PeriodIncomeWagesTests {
    @Test("nil when the wage rate isn't set")
    func nilWhenRateUnset() {
        let entries = [shift(date(2026, 1, 5), hours: 20)]
        #expect(PeriodIncome.wages(entries: entries, wageCentsPerHour: nil, firstWeekday: nil) == nil)
    }

    @Test("nil when no hours were logged — never fabricated from a fallback")
    func nilWhenNoHours() {
        let entries = [TipEntry(date: date(2026, 1, 5), amountCents: 5000, kind: .credit)]
        #expect(PeriodIncome.wages(entries: entries, wageCentsPerHour: 2000, firstWeekday: nil) == nil)
    }

    @Test("exactly 40 logged hours in a week is all regular, zero overtime")
    func exactly40HoursIsAllRegular() {
        let entries = [shift(date(2026, 1, 5), hours: 40)]
        let wages = PeriodIncome.wages(entries: entries, wageCentsPerHour: 2000, firstWeekday: 2)
        #expect(wages?.hours == 40)
        #expect(wages?.overtimeHours == 0)
        #expect(wages?.regularCents == 80_000)
        #expect(wages?.overtimeCents == 0)
    }

    @Test("hours over 40 in a week pay 1.5x, rounded to the nearest cent")
    func overtimeAbove40() {
        let entries = [shift(date(2026, 1, 5), hours: 45)]
        let wages = PeriodIncome.wages(entries: entries, wageCentsPerHour: 2000, firstWeekday: 2)
        #expect(wages?.overtimeHours == 5)
        #expect(wages?.regularCents == 80_000)
        #expect(wages?.overtimeCents == 15_000)
    }

    @Test("cents round to the nearest whole cent, not truncated")
    func roundsFractionalCents() {
        // 2.83 * 7.75 = 21.9325 -> 2193 cents rounded, matching WageEstimate.
        let entries = [shift(date(2026, 1, 5), hours: 7.75)]
        let wages = PeriodIncome.wages(entries: entries, wageCentsPerHour: 283, firstWeekday: 2)
        #expect(wages?.regularCents == 2193)
        #expect(wages?.overtimeCents == 0)
    }

    @Test("hours spanning two workweeks bucket independently — 45h + 35h yields exactly 5 overtime hours")
    func twoWorkweeksBucketIndependently() {
        // firstWeekday 2 (Monday): Jan 5–11 is one workweek, Jan 12–18 the next.
        let weekOne = shift(date(2026, 1, 7), hours: 45)   // Wednesday, week of Jan 5
        let weekTwo = shift(date(2026, 1, 14), hours: 35)  // Wednesday, week of Jan 12
        let wages = PeriodIncome.wages(entries: [weekOne, weekTwo], wageCentsPerHour: 2000, firstWeekday: 2)
        #expect(wages?.hours == 80)
        // Only week one's 5 hours over 40 count as overtime — the second
        // week's 35 hours never combine with the first's to manufacture OT.
        #expect(wages?.overtimeHours == 5)
        #expect(wages?.regularCents == 150_000) // (40 + 35) * $20
        #expect(wages?.overtimeCents == 15_000) // 5 * $20 * 1.5
    }

    @Test("a single 12h shift day still buckets by week, not by day")
    func singleLongShiftDayBucketsByWeek() {
        let entries = [shift(date(2026, 1, 7), hours: 12)]
        let wages = PeriodIncome.wages(entries: entries, wageCentsPerHour: 2000, firstWeekday: 2)
        #expect(wages?.hours == 12)
        #expect(wages?.overtimeHours == 0)
    }

    @Test("week boundary respects the schedule's firstWeekday override")
    func weekBoundaryRespectsFirstWeekday() {
        // Jan 10, 2026 is a Saturday; Jan 11 is a Sunday.
        let saturday = shift(date(2026, 1, 10), hours: 25)
        let sunday = shift(date(2026, 1, 11), hours: 25)

        // Monday-start week: Jan 5–11 is ONE workweek, so the two 25h shifts
        // combine to 50h and trip 10h of overtime.
        let mondayStart = PeriodIncome.wages(entries: [saturday, sunday], wageCentsPerHour: 2000, firstWeekday: 2)
        #expect(mondayStart?.hours == 50)
        #expect(mondayStart?.overtimeHours == 10)

        // Sunday-start week: Jan 10 falls in the Jan 4–10 week and Jan 11
        // starts a new one, so neither week crosses 40h alone.
        let sundayStart = PeriodIncome.wages(entries: [saturday, sunday], wageCentsPerHour: 2000, firstWeekday: 1)
        #expect(sundayStart?.hours == 50)
        #expect(sundayStart?.overtimeHours == 0)
    }
}
