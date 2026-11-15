import Testing
import Foundation
@testable import Payday

/// Midnight, matching how TipEntry.date is always stored in production —
/// same helper as StatsEngineTests.
private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func record(_ year: Int, _ month: Int, _ day: Int, cents: Int) -> TipRecord {
    TipRecord(date: date(year, month, day), amountCents: cents, kind: .cash)
}

private func weekday(_ year: Int, _ month: Int, _ day: Int) -> Int {
    Calendar.current.component(.weekday, from: date(year, month, day))
}

@Suite("Plan forward")
struct PlanForwardTests {
    @Test("plan forward is nil without any work rhythm yet")
    func nilWithoutRhythm() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [])
        #expect(engine.planForward(referenceDate: date(2026, 7, 26)) == nil)
    }

    @Test("nights are ordered by date and each carries its own weekday average and count")
    func nightsOrderedByDate() {
        var records: [TipRecord] = []
        // Monday, Wednesday, Friday every week for 3 weeks - all usual,
        // each priced differently so date order can't be confused with
        // value order.
        for week in 0..<3 {
            records.append(record(2026, 7, 6 + week * 7, cents: 15000))  // Monday
            records.append(record(2026, 7, 8 + week * 7, cents: 5000))   // Wednesday
            records.append(record(2026, 7, 10 + week * 7, cents: 8000))  // Friday
        }
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let plan = engine.planForward(referenceDate: date(2026, 7, 26))
        #expect(plan?.nights.count == 3)
        #expect(plan?.nights[0] == PlanForward.Night(weekday: weekday(2026, 7, 6), averageNetCents: 15000, nightCount: 3))
        #expect(plan?.nights[1] == PlanForward.Night(weekday: weekday(2026, 7, 8), averageNetCents: 5000, nightCount: 3))
        #expect(plan?.nights[2] == PlanForward.Night(weekday: weekday(2026, 7, 10), averageNetCents: 8000, nightCount: 3))
    }

    @Test("a usual weekday too thin to trust its own average borrows the overall per-shift average instead")
    func thinUsualWeekdayFallsBackToOverallAverage() {
        var records: [TipRecord] = []
        // Monday: 3 nights at $100 - clears the 3-night bar, keeps its own average.
        for week in 0..<3 {
            records.append(record(2026, 7, 6 + week * 7, cents: 10000))
        }
        // Tuesday: only 2 nights ever, at $40 - usual (clears workRhythm's
        // own 2-night/50% floor) but too thin to trust its own average.
        records.append(record(2026, 7, 7, cents: 4000))
        records.append(record(2026, 7, 14, cents: 4000))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let plan = engine.planForward(referenceDate: date(2026, 7, 26))
        // Overall per-shift average: (3*10000 + 2*4000) / 5 = 7600.
        #expect(plan?.nights.count == 2)
        #expect(plan?.nights[0] == PlanForward.Night(weekday: weekday(2026, 7, 6), averageNetCents: 10000, nightCount: 3))
        #expect(plan?.nights[1] == PlanForward.Night(weekday: weekday(2026, 7, 7), averageNetCents: 7600, nightCount: 2))
    }

    @Test("projected total is the sum of every priced night")
    func projectedTotalSums() {
        var records: [TipRecord] = []
        for week in 0..<3 {
            records.append(record(2026, 7, 6 + week * 7, cents: 10000))  // Monday, $100
            records.append(record(2026, 7, 10 + week * 7, cents: 20000)) // Friday, $200
        }
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let plan = engine.planForward(referenceDate: date(2026, 7, 26))
        #expect(plan?.projectedTotalCents == 30000)
        #expect(plan?.projectedTotalCents == plan?.nights.reduce(0) { $0 + $1.averageNetCents })
    }
}
