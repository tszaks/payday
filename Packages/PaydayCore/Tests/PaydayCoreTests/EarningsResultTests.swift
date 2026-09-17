import Foundation
import Testing
@testable import PaydayCore

@Suite("EarningsResult")
struct EarningsResultTests {
    func result(earnedCents: Int, minutes: Int) -> EarningsResult {
        var r = EarningsResult.empty(metric: .hourlyRate)
        r.coveredComponents = EarningsComponents(voluntaryCreditCents: earnedCents)
        r.knownComponents = r.coveredComponents
        r.minutes = minutes
        return r
    }

    @Test("hourly rate is nil with no covered minutes")
    func nilAtZeroMinutes() {
        #expect(result(earnedCents: 20000, minutes: 0).hourlyRateCents == nil)
        #expect(EarningsResult.empty(metric: .hourlyRate).hourlyRateCents == nil)
    }

    /// Operands deliberately unlike H1's: `20000c over 300 minutes -> 4000`
    /// is exactly H1's `wrongAnswers.allIncomeOverCoveredMinutes`, so naming
    /// that pair here read as an assertion that H1's forbidden answer is
    /// right. `uncoveredExcluded` below is the pin of H1's real case.
    @Test("Fully covered rate: 15000c over 360 minutes is 2500c per hour")
    func simpleRate() {
        #expect(result(earnedCents: 15000, minutes: 360).hourlyRateCents == 2500)
    }

    @Test("H1: the uncovered shift is excluded from both sides of the rate")
    func uncoveredExcluded() {
        var r = result(earnedCents: 10000, minutes: 300)
        r.knownComponents = EarningsComponents(voluntaryCreditCents: 20000)
        r.completeness = Completeness(totalShifts: 2, shiftsWithHours: 1, shiftsWageValued: 0, shiftsWageAssumed: 0, wageFeatureEnabled: true)
        #expect(r.hourlyRateCents == 2000)
        #expect(r.coveredShiftCount == 1)
    }

    @Test("Rate rounds half-up", arguments: [
        (25, 120, 13),     // 12.5 -> 13
        (7, 240, 2),       // 1.75 -> 2
        (5, 240, 1),       // 1.25 -> 1
        (1000, 480, 125),  // exact
        (283, 60, 283),    // one hour at 283c
        (1, 60, 1),
        (1, 120, 1),       // 0.5 -> 1
        (1, 180, 0),       // 0.333 -> 0
    ])
    func halfUp(earned: Int, minutes: Int, expected: Int) {
        #expect(result(earnedCents: earned, minutes: minutes).hourlyRateCents == expected)
    }

    @Test("Negative earned income (tip-out exceeds tips) still rounds half-up toward +infinity")
    func negativeHalfUp() {
        #expect(result(earnedCents: -25, minutes: 120).hourlyRateCents == -12)  // -12.5 -> -12
        #expect(result(earnedCents: -7, minutes: 240).hourlyRateCents == -2)    // -1.75 -> -2
        #expect(result(earnedCents: -5, minutes: 240).hourlyRateCents == -1)    // -1.25 -> -1
    }

    @Test("IntegerRounding.divideHalfUp matches the (2n + d) / 2d form for non-negative n")
    func matchesSpecForm() {
        for n in 0...500 {
            for d in [1, 3, 7, 60, 300] {
                #expect(IntegerRounding.divideHalfUp(n, by: d) == (2 * n + d) / (2 * d))
            }
        }
    }

    @Test("empty(metric:) carries the metric and nothing else")
    func empty() {
        let r = EarningsResult.empty(metric: .earnedIncome)
        #expect(r.metric == .earnedIncome)
        #expect(r.range == nil)
        #expect(r.asOf == nil)
        #expect(r.knownComponents == .zero)
        #expect(r.coveredComponents == .zero)
        #expect(r.minutes == 0)
        #expect(r.regularMinutes == 0)
        #expect(r.overtimeMinutes == 0)
        #expect(r.completeness.state == .noShifts)
        #expect(r.shiftIDs.isEmpty)
        // PR 4 fills these from the snapshot; the shell carries the current engine and no digest.
        #expect(r.engineVersion == InputManifest.currentEngineVersion)
        #expect(r.engineVersion == 1)
        #expect(r.manifestDigest == nil)
    }

    @Test("Codable round trip preserves every field")
    func codable() throws {
        var r = result(earnedCents: 20000, minutes: 300)
        r.range = DayRange(start: CivilDay(year: 2026, month: 9, day: 28), end: CivilDay(year: 2026, month: 10, day: 4))
        r.asOf = CivilDay(year: 2026, month: 10, day: 2)
        r.regularMinutes = 240
        r.overtimeMinutes = 60
        r.shiftIDs = [UUID(), UUID()]
        r.engineVersion = 2
        r.manifestDigest = String(repeating: "ab", count: 32)
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(EarningsResult.self, from: data) == r)
    }
}
