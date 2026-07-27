import Testing
import Foundation
@testable import Payday

/// StatsEngine.CashWeekdayFacts — the one cash fact Insights is allowed to
/// surface: which weekday runs meaningfully more cash than the rest of the
/// week, and only when the data honestly supports it. Cash-vs-credit as a
/// general split is dead; a server already knows their own split.
/// Same per-file helper pattern as PlanForwardTests/StatsEngineTests.
private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func weekday(_ year: Int, _ month: Int, _ day: Int) -> Int {
    Calendar.current.component(.weekday, from: date(year, month, day))
}

private func record(_ year: Int, _ month: Int, _ day: Int, cents: Int, kind: TipKind) -> TipRecord {
    TipRecord(date: date(year, month, day), amountCents: cents, kind: kind, isDouble: false)
}

/// One shift's worth of cash + credit records on the same calendar day — no
/// explicit shiftID, so both fall back to the same deterministic legacy
/// shift id and merge into one shift, same as production's fallback rule.
/// Omits either record when its amount is 0, so a pure-cash or pure-credit
/// shift doesn't carry a spurious zero-amount row.
private func shift(_ year: Int, _ month: Int, _ day: Int, cashCents: Int, creditCents: Int) -> [TipRecord] {
    var records: [TipRecord] = []
    if cashCents > 0 { records.append(record(year, month, day, cents: cashCents, kind: .cash)) }
    if creditCents > 0 { records.append(record(year, month, day, cents: creditCents, kind: .credit)) }
    return records
}

@Suite("Cash weekday facts")
struct CashWeekdayFactsTests {
    @Test("qualifies when a weekday clearly runs hotter on cash than the rest of the week")
    func qualifiesWithClearDelta() {
        var records: [TipRecord] = []
        // Friday: 90% cash across 3 nights.
        for (y, m, d) in [(2026, 7, 10), (2026, 7, 17), (2026, 7, 24)] {
            records += shift(y, m, d, cashCents: 9000, creditCents: 1000)
        }
        // Rest of the week: 10% cash across 6 nights (Monday + Wednesday).
        for (y, m, d) in [(2026, 7, 6), (2026, 7, 13), (2026, 7, 20), (2026, 7, 8), (2026, 7, 15), (2026, 7, 22)] {
            records += shift(y, m, d, cashCents: 1000, creditCents: 9000)
        }
        let engine = StatsEngine(records: records)
        let cashWeekday = engine.insightsFacts(referenceDate: date(2026, 7, 26))?.cashWeekday
        #expect(cashWeekday?.weekday == weekday(2026, 7, 10))
        #expect(cashWeekday?.nightCount == 3)
        #expect(cashWeekday.map { abs($0.sharePercent - 90) < 0.0001 } == true)
        #expect(cashWeekday.map { abs($0.restSharePercent - 10) < 0.0001 } == true)
    }

    @Test("blocked when the weekday has fewer than 3 qualifying nights")
    func blockedByThinWeekdaySample() {
        var records: [TipRecord] = []
        // Friday: only 2 nights, heavily cash.
        for (y, m, d) in [(2026, 7, 10), (2026, 7, 17)] {
            records += shift(y, m, d, cashCents: 9000, creditCents: 1000)
        }
        // Rest of week: 6 nights, low cash.
        for (y, m, d) in [(2026, 7, 6), (2026, 7, 13), (2026, 7, 20), (2026, 7, 8), (2026, 7, 15), (2026, 7, 22)] {
            records += shift(y, m, d, cashCents: 1000, creditCents: 9000)
        }
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 26))?.cashWeekday == nil)
    }

    @Test("blocked when the rest-of-week pool has fewer than 6 nights")
    func blockedByThinRestOfWeekPool() {
        var records: [TipRecord] = []
        // Friday: 3 nights, heavily cash - qualifies on its own.
        for (y, m, d) in [(2026, 7, 10), (2026, 7, 17), (2026, 7, 24)] {
            records += shift(y, m, d, cashCents: 9000, creditCents: 1000)
        }
        // Rest of week: only 5 nights (Monday), low cash.
        for (y, m, d) in [(2026, 7, 6), (2026, 7, 13), (2026, 7, 20), (2026, 7, 27), (2026, 8, 3)] {
            records += shift(y, m, d, cashCents: 1000, creditCents: 9000)
        }
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 8, 10))?.cashWeekday == nil)
    }

    @Test("blocked when the weekday's total cash sits under the $50 materiality floor")
    func blockedByMaterialityFloor() {
        var records: [TipRecord] = []
        // Friday: 3 nights at 90% cash, but only $10 gross each - $27 total
        // cash across the weekday, under the $50 floor.
        for (y, m, d) in [(2026, 7, 10), (2026, 7, 17), (2026, 7, 24)] {
            records += shift(y, m, d, cashCents: 900, creditCents: 100)
        }
        // Rest of week: 6 nights, low cash, plenty of gross.
        for (y, m, d) in [(2026, 7, 6), (2026, 7, 13), (2026, 7, 20), (2026, 7, 8), (2026, 7, 15), (2026, 7, 22)] {
            records += shift(y, m, d, cashCents: 1000, creditCents: 9000)
        }
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 26))?.cashWeekday == nil)
    }

    @Test("blocked when the delta against the rest of the week is under 15 points")
    func blockedByThinDelta() {
        var records: [TipRecord] = []
        // Friday: 40% cash across 3 nights.
        for (y, m, d) in [(2026, 7, 10), (2026, 7, 17), (2026, 7, 24)] {
            records += shift(y, m, d, cashCents: 4000, creditCents: 6000)
        }
        // Rest of week: 30% cash across 6 nights - only a 10-point gap.
        for (y, m, d) in [(2026, 7, 6), (2026, 7, 13), (2026, 7, 20), (2026, 7, 8), (2026, 7, 15), (2026, 7, 22)] {
            records += shift(y, m, d, cashCents: 3000, creditCents: 7000)
        }
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 26))?.cashWeekday == nil)
    }

    @Test("weekday share is the blended total, never an average of nightly shares")
    func blendedNotAveraged() {
        var records: [TipRecord] = []
        // Friday: two all-cash $50 nights bookending one all-credit $450
        // night. The naive average of nightly shares is (100 + 0 + 100) / 3
        // = 66.7%, but the blended share (total cash over total gross) is
        // 100 / 550 = 18.2% - a very different number.
        records += shift(2026, 7, 10, cashCents: 5000, creditCents: 0)
        records += shift(2026, 7, 17, cashCents: 0, creditCents: 45000)
        records += shift(2026, 7, 24, cashCents: 5000, creditCents: 0)
        // Rest of week: 6 nights, all credit, so the weekday's blended
        // share still clears the delta bar against a 0% baseline.
        for (y, m, d) in [(2026, 7, 6), (2026, 7, 13), (2026, 7, 20), (2026, 7, 8), (2026, 7, 15), (2026, 7, 22)] {
            records += shift(y, m, d, cashCents: 0, creditCents: 10000)
        }
        let engine = StatsEngine(records: records)
        let cashWeekday = engine.insightsFacts(referenceDate: date(2026, 7, 26))?.cashWeekday
        #expect(cashWeekday?.weekday == weekday(2026, 7, 10))
        #expect(cashWeekday.map { abs($0.sharePercent - (10000.0 / 55000.0 * 100)) < 0.01 } == true)
        // Nowhere near the naive per-night average of 66.7%.
        #expect(cashWeekday.map { $0.sharePercent < 30 } == true)
    }

    @Test("when multiple weekdays qualify, the largest delta wins")
    func largestDeltaWins() {
        var records: [TipRecord] = []
        // Friday: 90% cash - the biggest gap against its own rest-of-week pool.
        for (y, m, d) in [(2026, 7, 10), (2026, 7, 17), (2026, 7, 24)] {
            records += shift(y, m, d, cashCents: 9000, creditCents: 1000)
        }
        // Tuesday: 50% cash - qualifies too, but by a smaller margin.
        for (y, m, d) in [(2026, 7, 7), (2026, 7, 14), (2026, 7, 21)] {
            records += shift(y, m, d, cashCents: 5000, creditCents: 5000)
        }
        // Monday and Wednesday: all-credit baseline for both comparisons.
        for (y, m, d) in [(2026, 7, 6), (2026, 7, 13), (2026, 7, 20), (2026, 7, 8), (2026, 7, 15), (2026, 7, 22)] {
            records += shift(y, m, d, cashCents: 0, creditCents: 10000)
        }
        let engine = StatsEngine(records: records)
        let cashWeekday = engine.insightsFacts(referenceDate: date(2026, 7, 26))?.cashWeekday
        #expect(cashWeekday?.weekday == weekday(2026, 7, 10))
        #expect(cashWeekday?.nightCount == 3)
    }

    @Test("nil when no weekday's cash share meaningfully beats the rest of the week")
    func nilWhenNothingQualifies() {
        var records: [TipRecord] = []
        // Every weekday runs the same 50/50 cash split - no gap to report.
        for (y, m, d) in [(2026, 7, 6), (2026, 7, 13), (2026, 7, 20), (2026, 7, 8), (2026, 7, 15), (2026, 7, 22)] {
            records += shift(y, m, d, cashCents: 5000, creditCents: 5000)
        }
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 26))?.cashWeekday == nil)
    }
}
