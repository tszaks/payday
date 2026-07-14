import Testing
import Foundation
@testable import Payday

/// Midnight, matching how TipEntry.date is always stored in production
/// (LogTipSheet normalizes every save via Calendar.startOfDay) — the engine
/// is entitled to assume that invariant, same as PayPeriodCalculator does.
private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func record(_ year: Int, _ month: Int, _ day: Int, cents: Int, kind: TipKind = .cash, isDouble: Bool = false, recordedHour: Int? = nil) -> TipRecord {
    let shiftDate = date(year, month, day)
    let recordedAt = recordedHour.flatMap { hour in
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shiftDate)
    }
    return TipRecord(date: shiftDate, amountCents: cents, kind: kind, isDouble: isDouble, recordedAt: recordedAt)
}

@Suite("Nightly totals")
struct NightlyTotalsTests {
    @Test("cash and credit on the same night sum into one shift")
    func sameNightSums() {
        let records = [
            record(2026, 7, 1, cents: 5000, kind: .cash),
            record(2026, 7, 1, cents: 3000, kind: .credit)
        ]
        let engine = StatsEngine(records: records)
        let nights = engine.nightlyTotals()
        #expect(nights.count == 1)
        #expect(nights[0].cents == 8000)
    }

    @Test("distinct days produce distinct nights")
    func distinctDays() {
        let records = [record(2026, 7, 1, cents: 5000), record(2026, 7, 2, cents: 6000)]
        let engine = StatsEngine(records: records)
        #expect(engine.nightlyTotals().count == 2)
    }
}

@Suite("Records")
struct RecordsTests {
    @Test("best night ever excludes the night passed as excluding")
    func bestNightExcludesTonight() {
        let records = [record(2026, 7, 1, cents: 9000), record(2026, 7, 8, cents: 5000)]
        let engine = StatsEngine(records: records)
        let best = engine.bestNightEver(excluding: date(2026, 7, 1))
        #expect(best?.cents == 5000)
    }

    @Test("best night ever is nil with no history")
    func noHistoryIsNil() {
        let engine = StatsEngine(records: [])
        #expect(engine.bestNightEver() == nil)
    }

    @Test("best night for a weekday only considers that weekday")
    func bestForWeekday() {
        // July 1 2026 is a Wednesday, July 8 is also a Wednesday, July 3 is a Friday.
        let records = [
            record(2026, 7, 1, cents: 9000),
            record(2026, 7, 8, cents: 5000),
            record(2026, 7, 3, cents: 20000)
        ]
        let engine = StatsEngine(records: records)
        let wednesday = Calendar.current.component(.weekday, from: date(2026, 7, 1))
        let best = engine.bestNight(forWeekday: wednesday)
        #expect(best?.cents == 9000)
    }

    @Test("average for a weekday averages only matching nights")
    func weekdayAverage() {
        let records = [record(2026, 7, 1, cents: 8000), record(2026, 7, 8, cents: 6000)]
        let engine = StatsEngine(records: records)
        let wednesday = Calendar.current.component(.weekday, from: date(2026, 7, 1))
        #expect(engine.averageForWeekday(wednesday) == 7000)
    }

    @Test("average for a weekday is nil with no matching nights")
    func weekdayAverageNil() {
        let engine = StatsEngine(records: [record(2026, 7, 1, cents: 8000)])
        // Thursday never occurred in the fixture.
        let thursday = Calendar.current.component(.weekday, from: date(2026, 7, 2))
        #expect(engine.averageForWeekday(thursday) == nil)
    }
}

@Suite("Pace")
struct PaceTests {
    @Test("period-to-date total only counts entries through the given date")
    func periodToDate() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let records = [record(2026, 7, 6, cents: 5000), record(2026, 7, 15, cents: 6000), record(2026, 7, 18, cents: 7000)]
        let engine = StatsEngine(records: records)
        #expect(engine.periodToDateTotal(period: period, asOf: date(2026, 7, 15)) == 11000)
    }

    @Test("prior period comparable total matches the same elapsed-day offset")
    func priorPeriodComparable() {
        let currentPeriod = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let priorPeriod = PayPeriod(start: date(2026, 6, 22), end: date(2026, 7, 5))
        let records = [
            record(2026, 6, 22, cents: 5000), // day 0 of prior period
            record(2026, 6, 24, cents: 6000), // day 2 of prior period
            record(2026, 7, 1, cents: 9000)   // day 9, after the comparable cutoff
        ]
        let engine = StatsEngine(records: records)
        // "asOf" is 2 days into the current period, so the comparable window
        // is priorPeriod.start through priorPeriod.start + 2 days.
        let total = engine.priorPeriodComparableTotal(currentPeriod: currentPeriod, priorPeriod: priorPeriod, asOf: date(2026, 7, 8))
        #expect(total == 11000)
    }

    @Test("pace delta is nil with no prior period")
    func paceDeltaNilWithoutPrior() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [])
        #expect(engine.paceDelta(currentPeriod: period, priorPeriod: nil, asOf: date(2026, 7, 8)) == nil)
    }

    @Test("pace delta is positive when ahead of the prior period")
    func paceDeltaAhead() {
        let currentPeriod = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let priorPeriod = PayPeriod(start: date(2026, 6, 22), end: date(2026, 7, 5))
        let records = [record(2026, 7, 6, cents: 10000), record(2026, 6, 22, cents: 4000)]
        let engine = StatsEngine(records: records)
        let delta = engine.paceDelta(currentPeriod: currentPeriod, priorPeriod: priorPeriod, asOf: date(2026, 7, 6))
        #expect(delta == 6000)
    }
}

@Suite("Anomalies")
struct AnomalyTests {
    @Test("first shift of a period has no prior entries in that period")
    func firstShift() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [])
        #expect(engine.isFirstShiftOfPeriod(date: date(2026, 7, 6), period: period))
    }

    @Test("not the first shift once an earlier entry exists in the period")
    func notFirstShift() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [record(2026, 7, 6, cents: 5000)])
        #expect(!engine.isFirstShiftOfPeriod(date: date(2026, 7, 8), period: period))
    }

    @Test("slowest recently requires enough history before it can fire")
    func slowestNeedsHistory() {
        let engine = StatsEngine(records: [record(2026, 7, 1, cents: 1000)])
        #expect(!engine.isSlowestRecently(date: date(2026, 7, 2), cents: 500, lookbackShifts: 8))
    }

    @Test("slowest recently fires when tonight is at or below the recent floor")
    func slowestFires() {
        let records = (1...5).map { record(2026, 7, $0, cents: 5000 + $0 * 1000) }
        let engine = StatsEngine(records: records)
        #expect(engine.isSlowestRecently(date: date(2026, 7, 6), cents: 4000, lookbackShifts: 8))
    }

    @Test("slowest recently does not fire for an ordinary night")
    func slowestDoesNotFireForOrdinaryNight() {
        let records = (1...5).map { record(2026, 7, $0, cents: 5000 + $0 * 1000) }
        let engine = StatsEngine(records: records)
        #expect(!engine.isSlowestRecently(date: date(2026, 7, 6), cents: 50000, lookbackShifts: 8))
    }
}

@Suite("Reveal priority order")
struct RevealTests {
    @Test("no history at all reveals as the first logged night")
    func firstNightEver() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [])
        let result = engine.reveal(forNightAt: date(2026, 7, 6), cents: 5000, period: period)
        #expect(result.comparison == .firstNightLogged)
        #expect(!result.isRecord)
    }

    @Test("beating the all-time best is an all-time record, outranking a first-shift-of-period callout")
    func allTimeRecordOutranksFirstShift() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [record(2026, 6, 22, cents: 5000)])
        let result = engine.reveal(forNightAt: date(2026, 7, 6), cents: 9000, period: period)
        #expect(result.comparison == .allTimeRecord(previousBestCents: 5000))
        #expect(result.isRecord)
    }

    @Test("first shift of a period outranks a weekday record when not also an all-time record")
    func firstShiftOutranksWeekdayRecord() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        // June 22 2026 is a Monday, same weekday as July 6 2026 — but June 22
        // logs a HIGHER amount, so July 6 can't be an all-time OR weekday record;
        // it should read as "first shift of the period" instead.
        let engine = StatsEngine(records: [record(2026, 6, 22, cents: 9000)])
        let result = engine.reveal(forNightAt: date(2026, 7, 6), cents: 5000, period: period)
        #expect(result.comparison == .firstShiftOfPeriod)
        #expect(!result.isRecord)
    }

    @Test("weekday record fires when not the first shift of the period and not an all-time record")
    func weekdayRecordFires() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        // All-time best is a Friday (June 26) so it doesn't block a Monday
        // weekday record; June 22 is the Monday to beat; July 8 is an
        // earlier entry in the current period so July 13 isn't a first shift.
        let engine = StatsEngine(records: [
            record(2026, 6, 26, cents: 20000), // all-time best, a Friday
            record(2026, 6, 22, cents: 3000),  // best Monday so far
            record(2026, 7, 8, cents: 4000)    // earlier in the current period
        ])
        let result = engine.reveal(forNightAt: date(2026, 7, 13), cents: 5000, period: period)
        #expect(result.comparison == .weekdayRecord(weekday: Calendar.current.component(.weekday, from: date(2026, 7, 13)), previousBestCents: 3000))
        #expect(result.isRecord)
    }

    @Test("default case falls back to the weekday-average comparison with a period rank")
    func defaultWeekdayAverageWithRank() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let monday = Calendar.current.component(.weekday, from: date(2026, 7, 6))
        let engine = StatsEngine(records: [
            record(2026, 6, 22, cents: 6000),  // the only Monday in history — sets the average, and stays the all-time best (tonight won't beat it)
            record(2026, 7, 7, cents: 1000),   // earlier in the current period (rules out "first shift")
            record(2026, 7, 9, cents: 1200),   // earlier in the current period
            record(2026, 7, 11, cents: 1300)   // earlier in the current period — 3 in-period nights, all below tonight
        ])
        let result = engine.reveal(forNightAt: date(2026, 7, 13), cents: 5500, period: period)
        guard case .weekdayAverage(let weekday, let deltaCents, let periodRank, let periodNightCount) = result.comparison else {
            Issue.record("expected weekdayAverage case")
            return
        }
        #expect(weekday == monday)
        #expect(deltaCents == -500) // 5500 - 6000 (the only other Monday on record)
        #expect(periodRank == 1)    // tonight beats all 3 in-period nights logged so far
        #expect(periodNightCount == 3)
    }
}

@Suite("Reveal copy")
struct RevealCopyTests {
    @Test("headline formats the shift total")
    func headlineFormat() {
        #expect(RevealCopy.headline(cents: 18600) == "$186.00 tonight.")
    }

    @Test("all-time record copy names the previous best")
    func allTimeRecordCopy() {
        let text = RevealCopy.comparison(for: .allTimeRecord(previousBestCents: 5000))
        #expect(text.contains("Best night ever"))
        #expect(text.contains("$50.00"))
    }

    @Test("weekday average copy includes a period rank clincher only when it qualifies")
    func weekdayAverageWithRank() {
        let text = RevealCopy.comparison(for: .weekdayAverage(weekday: 2, deltaCents: 3400, periodRank: 3, periodNightCount: 5))
        #expect(text.contains("above your"))
        #expect(text.contains("Third-best night this period."))
    }

    @Test("weekday average copy omits the clincher when the rank doesn't qualify")
    func weekdayAverageWithoutRank() {
        let text = RevealCopy.comparison(for: .weekdayAverage(weekday: 2, deltaCents: -1200, periodRank: nil, periodNightCount: 5))
        #expect(text.contains("below your"))
        #expect(!text.contains("period."))
    }

    @Test("pace line reads ahead, behind, and even correctly")
    func paceLineWording() {
        #expect(RevealCopy.paceLine(deltaCents: 12000).contains("ahead of"))
        #expect(RevealCopy.paceLine(deltaCents: -5000).contains("behind"))
        #expect(RevealCopy.paceLine(deltaCents: 0) == "Even with last period at this point.")
    }
}

@Suite("Insights facts")
struct InsightsFactsTests {
    @Test("nil without enough shifts")
    func notEnoughShifts() {
        let engine = StatsEngine(records: [record(2026, 7, 1, cents: 1000)])
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 10)) == nil)
    }

    @Test("computes totals, average, top days, and the cash/credit split")
    func basicFacts() {
        let records = [
            record(2026, 7, 1, cents: 1000, kind: .cash),
            record(2026, 7, 2, cents: 2000, kind: .credit),
            record(2026, 7, 3, cents: 5000, kind: .cash),
            record(2026, 7, 4, cents: 3000, kind: .credit),
            record(2026, 7, 5, cents: 4000, kind: .cash)
        ]
        let engine = StatsEngine(records: records)
        guard let facts = engine.insightsFacts(referenceDate: date(2026, 7, 10)) else {
            Issue.record("expected facts")
            return
        }
        #expect(facts.totalCents == 15000)
        #expect(facts.shiftCount == 5)
        #expect(facts.averagePerShiftCents == 3000)
        #expect(facts.topDays.count == 3)
        #expect(facts.topDays[0].cents == 5000)
        #expect(facts.cashCents == 10000)
        #expect(facts.creditCents == 5000)
        #expect(facts.lunchDinner == nil)
        #expect(facts.doublesSolo == nil)
    }

    @Test("only considers the recent window")
    func recentWindowOnly() {
        var records = (1...5).map { record(2026, 7, $0, cents: 1000) }
        records.append(record(2025, 1, 1, cents: 99999))
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 10))?.shiftCount == 5)
    }

    @Test("lunch vs dinner splits at 4pm and excludes backfilled entries recorded on a different day")
    func lunchDinnerHonestyRule() {
        // 5 same-day-recorded shifts (meets the minimum before making a
        // lunch/dinner claim) plus 1 backfilled shift recorded days later,
        // which must be excluded from the lunch/dinner totals entirely.
        let backfilled = TipRecord(date: date(2026, 7, 1), amountCents: 9999, kind: .cash, isDouble: false, recordedAt: date(2026, 7, 8))
        let records = [backfilled] + [
            record(2026, 7, 2, cents: 1000, recordedHour: 12),
            record(2026, 7, 3, cents: 2000, recordedHour: 13),
            record(2026, 7, 4, cents: 3000, recordedHour: 19),
            record(2026, 7, 5, cents: 4000, recordedHour: 20),
            record(2026, 7, 6, cents: 5000, recordedHour: 21)
        ]
        let engine = StatsEngine(records: records)
        let facts = engine.insightsFacts(referenceDate: date(2026, 7, 10))
        #expect(facts?.shiftCount == 6)
        #expect(facts?.lunchDinner?.lunchShiftCount == 2)
        #expect(facts?.lunchDinner?.lunchCents == 3000)
        #expect(facts?.lunchDinner?.dinnerShiftCount == 3)
        #expect(facts?.lunchDinner?.dinnerCents == 12000)
    }

    @Test("doubles vs solo compares average per double against average per solo shift")
    func doublesSoloSplit() {
        let records = [
            record(2026, 7, 1, cents: 10000, isDouble: true),
            record(2026, 7, 2, cents: 14000, isDouble: true),
            record(2026, 7, 3, cents: 3000, isDouble: false),
            record(2026, 7, 4, cents: 5000, isDouble: false),
            record(2026, 7, 5, cents: 4000, isDouble: false)
        ]
        let engine = StatsEngine(records: records)
        let facts = engine.insightsFacts(referenceDate: date(2026, 7, 10))
        #expect(facts?.doublesSolo?.doubleAverageCents == 12000)
        #expect(facts?.doublesSolo?.doubleCount == 2)
        #expect(facts?.doublesSolo?.soloAverageCents == 4000)
        #expect(facts?.doublesSolo?.soloCount == 3)
    }

    @Test("doubles vs solo is nil when there are no doubles at all")
    func doublesSoloNilWithoutDoubles() {
        let records = (1...5).map { record(2026, 7, $0, cents: 1000) }
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 10))?.doublesSolo == nil)
    }
}

@Suite("Insights facts copy (no-AI fallback)")
struct InsightsFactsCopyTests {
    @Test("always includes overall, top days, and cash vs credit, in order")
    func alwaysIncludedSections() {
        let facts = InsightsFacts(totalCents: 10000, shiftCount: 5, averagePerShiftCents: 2000, topDays: [], cashCents: 4000, creditCents: 6000, lunchDinner: nil, doublesSolo: nil)
        let titles = InsightsFactsCopy.sections(for: facts).map(\.title)
        #expect(titles == ["Overall Snapshot", "Top Earning Days", "Cash vs Credit"])
    }

    @Test("lunch vs dinner and doubles vs solo sections only appear when their facts exist")
    func conditionalSections() {
        let facts = InsightsFacts(
            totalCents: 10000, shiftCount: 5, averagePerShiftCents: 2000,
            topDays: [], cashCents: 4000, creditCents: 6000,
            lunchDinner: LunchDinnerFacts(lunchCents: 1000, lunchShiftCount: 1, dinnerCents: 2000, dinnerShiftCount: 1),
            doublesSolo: DoublesSoloFacts(doubleAverageCents: 5000, doubleCount: 1, soloAverageCents: 3000, soloCount: 2)
        )
        let titles = InsightsFactsCopy.sections(for: facts).map(\.title)
        #expect(titles.contains("Lunch vs Dinner"))
        #expect(titles.contains("Doubles vs Solo"))
    }

    @Test("copy never uses technical jargon like entries")
    func noJargonInCopy() {
        let facts = InsightsFacts(totalCents: 10000, shiftCount: 5, averagePerShiftCents: 2000, topDays: [], cashCents: 4000, creditCents: 6000, lunchDinner: nil, doublesSolo: nil)
        for section in InsightsFactsCopy.sections(for: facts) {
            #expect(!section.body.lowercased().contains("entries"))
        }
    }
}
