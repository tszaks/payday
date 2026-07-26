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
    TipRecord(date: date(year, month, day), amountCents: cents, kind: .cash, isDouble: false)
}

private func weekday(_ year: Int, _ month: Int, _ day: Int) -> Int {
    Calendar.current.component(.weekday, from: date(year, month, day))
}

@Suite("Plan forward")
struct PlanForwardTests {
    @Test("plan forward is nil without any work rhythm yet")
    func nilWithoutRhythm() {
        let engine = StatsEngine(records: [])
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
        let engine = StatsEngine(records: records)
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
        let engine = StatsEngine(records: records)
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
        let engine = StatsEngine(records: records)
        let plan = engine.planForward(referenceDate: date(2026, 7, 26))
        #expect(plan?.projectedTotalCents == 30000)
        #expect(plan?.projectedTotalCents == plan?.nights.reduce(0) { $0 + $1.averageNetCents })
    }

    // MARK: Pickup

    /// Shared fixture for the pickup tests below: a usual Monday (3 nights,
    /// every week it occurred) against a non-usual Thursday candidate that
    /// occurred more often than it was worked - the earliest record is a
    /// Thursday, so Monday's occurrence window (6) comes up one short of
    /// Thursday's (7), landing Monday's 3-for-3 at exactly 50% (usual) and
    /// Thursday's 3-for-7 well under it (not usual).
    private func mondayVsThursdayFixture(mondayCents: [Int], thursdayCents: [Int]) -> StatsEngine {
        var records: [TipRecord] = []
        let mondayDates = [(2026, 7, 6), (2026, 7, 13), (2026, 7, 20)]
        let thursdayDates = [(2026, 7, 2), (2026, 7, 9), (2026, 7, 16), (2026, 7, 23)]
        for (i, cents) in mondayCents.enumerated() {
            let (y, m, d) = mondayDates[i]
            records.append(record(y, m, d, cents: cents))
        }
        for (i, cents) in thursdayCents.enumerated() {
            let (y, m, d) = thursdayDates[i]
            records.append(record(y, m, d, cents: cents))
        }
        return StatsEngine(records: records)
    }

    @Test("pickup fires when a non-usual weekday clearly beats the lowest-priced usual night")
    func pickupFires() {
        let engine = mondayVsThursdayFixture(mondayCents: [5000, 5000, 5000], thursdayCents: [9500, 9500, 9500])
        let plan = engine.planForward(referenceDate: date(2026, 8, 13))
        #expect(plan?.pickup == PlanForward.Pickup(weekday: weekday(2026, 7, 2), averageNetCents: 9500, nightCount: 3))
    }

    @Test("pickup stays silent when the delta doesn't clear the flat dollar floor")
    func pickupBlockedByFlatFloor() {
        let engine = mondayVsThursdayFixture(mondayCents: [5000, 5000, 5000], thursdayCents: [6000, 6000, 6000])
        let plan = engine.planForward(referenceDate: date(2026, 8, 13))
        // $10 delta clears no meaningful bar and sits under the $15 floor.
        #expect(plan?.pickup == nil)
    }

    @Test("pickup stays silent when a real-looking delta sits inside noisy, high-variance history")
    func pickupBlockedByVariance() {
        let engine = mondayVsThursdayFixture(mondayCents: [500, 7000, 500], thursdayCents: [2000, 10000, 2000])
        let plan = engine.planForward(referenceDate: date(2026, 8, 13))
        // ~$20 delta clears the flat floor on its own, but the pooled
        // spread across both weekdays is wide enough that this shouldn't
        // read as a real signal (same guard as weekdaySwapMove).
        #expect(plan?.pickup == nil)
    }

    @Test("pickup requires at least 3 nights on the candidate weekday, no matter how large the delta")
    func pickupRequiresThreeNights() {
        let engine = mondayVsThursdayFixture(mondayCents: [5000, 5000, 5000], thursdayCents: [9500, 9500])
        let plan = engine.planForward(referenceDate: date(2026, 8, 13))
        #expect(plan?.pickup == nil)
    }

    @Test("pickup picks the best-qualifying non-usual weekday when more than one clears the bar")
    func pickupChoosesBestQualifying() {
        var records: [TipRecord] = []
        // Monday: usual every week for 10 weeks - always the baseline.
        let mondayDates = [
            (2026, 7, 6), (2026, 7, 13), (2026, 7, 20), (2026, 7, 27), (2026, 8, 3),
            (2026, 8, 10), (2026, 8, 17), (2026, 8, 24), (2026, 8, 31), (2026, 9, 7)
        ]
        for (y, m, d) in mondayDates {
            records.append(record(y, m, d, cents: 5000))
        }
        // Tuesday and Thursday: each worked 3 of their 9 occurrences in the
        // same window (well under half) - both non-usual, both clear the
        // pickup bar, but Thursday pays more.
        for (y, m, d) in [(2026, 7, 7), (2026, 7, 14), (2026, 7, 21)] {
            records.append(record(y, m, d, cents: 7000))
        }
        for (y, m, d) in [(2026, 7, 9), (2026, 7, 16), (2026, 7, 23)] {
            records.append(record(y, m, d, cents: 9500))
        }
        let engine = StatsEngine(records: records)
        let plan = engine.planForward(referenceDate: date(2026, 9, 7))
        #expect(plan?.pickup == PlanForward.Pickup(weekday: weekday(2026, 7, 9), averageNetCents: 9500, nightCount: 3))
    }
}
