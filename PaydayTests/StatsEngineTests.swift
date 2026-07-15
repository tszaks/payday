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

private func record(_ year: Int, _ month: Int, _ day: Int, cents: Int, kind: TipKind = .cash, isDouble: Bool = false, recordedHour: Int? = nil, hoursWorked: Double? = nil, tipOutCents: Int? = nil, salesCents: Int? = nil, shiftPeriod: ShiftPeriod? = nil) -> TipRecord {
    let shiftDate = date(year, month, day)
    let recordedAt = recordedHour.flatMap { hour in
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shiftDate)
    }
    return TipRecord(date: shiftDate, amountCents: cents, kind: kind, isDouble: isDouble, recordedAt: recordedAt, hoursWorked: hoursWorked, tipOutCents: tipOutCents, salesCents: salesCents, shiftPeriod: shiftPeriod)
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

    @Test("a night's total is net of any tip-out logged that night")
    func nightlyTotalIsNet() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit, tipOutCents: 1500),
            record(2026, 7, 1, cents: 3200, kind: .cash)
        ]
        let engine = StatsEngine(records: records)
        let nights = engine.nightlyTotals()
        #expect(nights.count == 1)
        // 8600 + 3200 - 1500 tip-out = 10300.
        #expect(nights[0].cents == 10300)
    }

    @Test("a night with no tip-out logged has its full gross as the total")
    func nightlyTotalWithoutTipOutIsGross() {
        let engine = StatsEngine(records: [record(2026, 7, 1, cents: 5000)])
        #expect(engine.nightlyTotals()[0].cents == 5000)
    }

    @Test("tip-out on the 'wrong' entry (cash, when a credit entry also exists) still nets correctly")
    func nightlyTotalReadsTipOutFromWrongEntry() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit),
            record(2026, 7, 1, cents: 3200, kind: .cash, tipOutCents: 1500)
        ]
        let engine = StatsEngine(records: records)
        // 8600 + 3200 - 1500 = 10300, not 11800 (ignoring it) or double-subtracted.
        #expect(engine.nightlyTotals()[0].cents == 10300)
    }

    @Test("tip-out set on BOTH entries (corruption) is never double-subtracted")
    func nightlyTotalNeverDoubleSubtractsTipOut() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit, tipOutCents: 1500),
            record(2026, 7, 1, cents: 3200, kind: .cash, tipOutCents: 1000)
        ]
        let engine = StatsEngine(records: records)
        // Credit's 1500 wins outright — never 1500+1000=2500 subtracted.
        #expect(engine.nightlyTotals()[0].cents == 8600 + 3200 - 1500)
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

    @Test("best night in a period only considers nights inside it")
    func bestNightInPeriod() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let records = [
            record(2026, 7, 8, cents: 5000),
            record(2026, 7, 12, cents: 9000),
            record(2026, 6, 30, cents: 20000) // outside the period, must not win
        ]
        let engine = StatsEngine(records: records)
        let best = engine.bestNight(in: period)
        #expect(best?.cents == 9000)
    }

    @Test("best night in a period is nil when nothing was logged in it")
    func bestNightInPeriodNilWhenEmpty() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [record(2026, 6, 30, cents: 20000)])
        #expect(engine.bestNight(in: period) == nil)
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

    @Test("period-to-date total nets any logged tip-outs")
    func periodToDateIsNet() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let records = [record(2026, 7, 6, cents: 5000, tipOutCents: 1000), record(2026, 7, 15, cents: 6000)]
        let engine = StatsEngine(records: records)
        #expect(engine.periodToDateTotal(period: period, asOf: date(2026, 7, 15)) == 10000)
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

@Suite("Rate ($/hr)")
struct RateTests {
    @Test("dollars per hour for a specific night divides that night's total by its hours")
    func dollarsPerHourForNight() {
        let engine = StatsEngine(records: [record(2026, 7, 1, cents: 20000, hoursWorked: 5)])
        #expect(engine.dollarsPerHour(forNightAt: date(2026, 7, 1)) == 40)
    }

    @Test("dollars per hour is nil for a night with no hours logged")
    func dollarsPerHourNilWithoutHours() {
        let engine = StatsEngine(records: [record(2026, 7, 1, cents: 20000)])
        #expect(engine.dollarsPerHour(forNightAt: date(2026, 7, 1)) == nil)
    }

    @Test("average dollars per hour blends total dollars over total hours, not an average of nightly rates")
    func averageDollarsPerHourIsBlended() {
        // One 10-hour night at $10/hr, one 2-hour night at $50/hr. A naive
        // average of the two rates would say $30/hr; blended by totals it's
        // $200 over 12 hours = $16.67/hr.
        let engine = StatsEngine(records: [
            record(2026, 7, 1, cents: 10000, hoursWorked: 10),
            record(2026, 7, 2, cents: 10000, hoursWorked: 2)
        ])
        let rate = engine.averageDollarsPerHour()
        #expect(rate != nil)
        #expect(abs(rate! - 16.666666) < 0.001)
    }

    @Test("average dollars per hour ignores nights with no hours logged")
    func averageDollarsPerHourIgnoresUnloggedNights() {
        let engine = StatsEngine(records: [
            record(2026, 7, 1, cents: 10000, hoursWorked: 5),
            record(2026, 7, 2, cents: 99999) // no hours — must not distort the rate
        ])
        #expect(engine.averageDollarsPerHour() == 20)
    }

    @Test("average dollars per hour is nil with no rate history at all")
    func averageDollarsPerHourNilWithoutHistory() {
        let engine = StatsEngine(records: [record(2026, 7, 1, cents: 10000)])
        #expect(engine.averageDollarsPerHour() == nil)
    }

    @Test("average dollars per hour for a weekday only blends that weekday's rate nights")
    func averageDollarsPerHourForWeekday() {
        // July 1 and July 8 2026 are both Wednesdays.
        let engine = StatsEngine(records: [
            record(2026, 7, 1, cents: 10000, hoursWorked: 5),  // $20/hr
            record(2026, 7, 8, cents: 6000, hoursWorked: 2),   // $30/hr
            record(2026, 7, 3, cents: 100, hoursWorked: 10)    // a Friday — must not count
        ])
        let wednesday = Calendar.current.component(.weekday, from: date(2026, 7, 1))
        // Blended: $160 over 7 hours.
        let rate = engine.averageDollarsPerHour(forWeekday: wednesday)
        #expect(rate != nil)
        #expect(abs(rate! - (160.0 / 7)) < 0.001)
    }

    @Test("best dollars-per-hour weekday requires at least two weekdays of rate history")
    func bestWeekdayNeedsTwoWeekdays() {
        let engine = StatsEngine(records: [
            record(2026, 7, 1, cents: 10000, hoursWorked: 5),
            record(2026, 7, 8, cents: 6000, hoursWorked: 2) // same weekday (Wednesday) as above
        ])
        #expect(engine.bestDollarsPerHourWeekday() == nil)
    }

    @Test("hours on the 'wrong' entry (cash, when a credit entry also exists) still resolve correctly")
    func dollarsPerHourReadsHoursFromWrongEntry() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit),
            record(2026, 7, 1, cents: 3200, kind: .cash, hoursWorked: 5)
        ]
        let engine = StatsEngine(records: records)
        // (8600 + 3200) / 100 / 5 = $23.60/hr, not nil.
        #expect(engine.dollarsPerHour(forNightAt: date(2026, 7, 1)) == 23.6)
    }

    @Test("hours set on BOTH entries (corruption) are never summed into double the real hours")
    func dollarsPerHourNeverSumsHours() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit, hoursWorked: 5),
            record(2026, 7, 1, cents: 3200, kind: .cash, hoursWorked: 5)
        ]
        let engine = StatsEngine(records: records)
        // If this summed to 10 hours the rate would be $11.80/hr instead.
        #expect(engine.dollarsPerHour(forNightAt: date(2026, 7, 1)) == 23.6)
    }

    @Test("best dollars-per-hour weekday picks the highest-blended-rate weekday")
    func bestWeekdayPicksHighestRate() {
        let engine = StatsEngine(records: [
            record(2026, 7, 1, cents: 10000, hoursWorked: 5),  // Wednesday, $20/hr
            record(2026, 7, 3, cents: 30000, hoursWorked: 5)   // Friday, $60/hr
        ])
        let friday = Calendar.current.component(.weekday, from: date(2026, 7, 3))
        let best = engine.bestDollarsPerHourWeekday()
        #expect(best?.weekday == friday)
        #expect(best?.rate == 60)
    }
}

@Suite("Tip percent")
struct TipPercentTests {
    @Test("tip percent for a night divides gross tips by sales, not net")
    func tipPercentForNightIsGross() {
        let engine = StatsEngine(records: [
            record(2026, 7, 1, cents: 10000, kind: .credit, tipOutCents: 1500, salesCents: 50000)
        ])
        // 10000 gross / 50000 sales = 20%, ignoring the tip-out entirely.
        #expect(engine.tipPercent(forNightAt: date(2026, 7, 1)) == 20)
    }

    @Test("tip percent is nil for a night with no sales logged")
    func tipPercentNilWithoutSales() {
        let engine = StatsEngine(records: [record(2026, 7, 1, cents: 10000)])
        #expect(engine.tipPercent(forNightAt: date(2026, 7, 1)) == nil)
    }

    @Test("average tip percent blends total gross tips over total sales")
    func averageTipPercentIsBlended() {
        let engine = StatsEngine(records: [
            record(2026, 7, 1, cents: 10000, salesCents: 50000), // 20%
            record(2026, 7, 2, cents: 3000, salesCents: 10000)   // 30%
        ])
        // Blended: 13000 / 60000 = 21.67%, not a naive 25% average.
        let percent = engine.averageTipPercent()
        #expect(percent != nil)
        #expect(abs(percent! - (13000.0 / 60000.0 * 100)) < 0.001)
    }

    @Test("sales on the 'wrong' entry (cash, when a credit entry also exists) still resolve correctly")
    func tipPercentReadsSalesFromWrongEntry() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit),
            record(2026, 7, 1, cents: 3200, kind: .cash, salesCents: 50000)
        ]
        let engine = StatsEngine(records: records)
        // (8600 + 3200) / 50000 * 100 = 23.6%, not nil.
        #expect(abs(engine.tipPercent(forNightAt: date(2026, 7, 1))! - 23.6) < 0.001)
    }

    @Test("sales set on BOTH entries (corruption) are never summed into double the real sales")
    func tipPercentNeverSumsSales() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit, salesCents: 50000),
            record(2026, 7, 1, cents: 3200, kind: .cash, salesCents: 20000)
        ]
        let engine = StatsEngine(records: records)
        // If this summed to $700 sales the percent would be ~16.9% instead.
        #expect(abs(engine.tipPercent(forNightAt: date(2026, 7, 1))! - 23.6) < 0.001)
    }

    @Test("average tip percent for a weekday only blends that weekday's sales nights")
    func averageTipPercentForWeekday() {
        // July 1 and July 8 2026 are both Wednesdays.
        let engine = StatsEngine(records: [
            record(2026, 7, 1, cents: 10000, salesCents: 50000), // Wednesday
            record(2026, 7, 8, cents: 3000, salesCents: 10000),  // Wednesday
            record(2026, 7, 3, cents: 999999, salesCents: 1)     // Friday, must not count
        ])
        let wednesday = Calendar.current.component(.weekday, from: date(2026, 7, 1))
        let percent = engine.averageTipPercent(forWeekday: wednesday)
        #expect(percent != nil)
        #expect(abs(percent! - (13000.0 / 60000.0 * 100)) < 0.001)
    }
}

@Suite("Moves")
struct MovesTests {
    @Test("weekday swap fires when one weekday clearly out-earns another, both with enough history")
    func weekdaySwapFires() {
        var records: [TipRecord] = []
        // Fridays ($150 avg) vs Mondays ($50 avg), 3 nights each, 3 weeks apart.
        for week in 0..<3 {
            records.append(record(2026, 7, 3 + week * 7, cents: 15000)) // Friday
            records.append(record(2026, 6, 29 + week * 7, cents: 5000)) // Monday
        }
        let engine = StatsEngine(records: records)
        let moves = engine.moves(referenceDate: date(2026, 7, 24))
        let swap = moves.first { $0.id == "weekdaySwap" }
        #expect(swap != nil)
        #expect(swap?.title.contains("Friday") == true)
    }

    @Test("weekday swap stays silent without at least two qualifying weekdays")
    func weekdaySwapSilentWithoutHistory() {
        let engine = StatsEngine(records: [record(2026, 7, 1, cents: 5000)])
        #expect(engine.moves().first { $0.id == "weekdaySwap" } == nil)
    }

    @Test("lapsed winner fires for a strong weekday that hasn't shown up recently")
    func lapsedWinnerFires() {
        var records: [TipRecord] = []
        // Three strong Fridays, all more than 21 days before referenceDate.
        for week in 0..<3 {
            records.append(record(2026, 6, 5 + week * 7, cents: 30000)) // Friday
        }
        // Ordinary recent nights on other weekdays, well within the window
        // (needs >= 6 total nights of history before this move considers
        // firing at all).
        records.append(record(2026, 7, 20, cents: 5000)) // Monday
        records.append(record(2026, 7, 21, cents: 5000)) // Tuesday
        records.append(record(2026, 7, 22, cents: 5000)) // Wednesday
        let engine = StatsEngine(records: records)
        let moves = engine.moves(referenceDate: date(2026, 7, 24))
        let lapsed = moves.first { $0.id == "lapsedWinner" }
        #expect(lapsed != nil)
        #expect(lapsed?.title.contains("Friday") == true)
    }

    @Test("doubles verdict fires when doubles and solo nights differ meaningfully per hour")
    func doublesVerdictFires() {
        var records: [TipRecord] = []
        // Doubles: long hours, mediocre $/hr.
        for day in [1, 8, 15] {
            records.append(record(2026, 7, day, cents: 12000, isDouble: true, hoursWorked: 10))
        }
        // Solo: short hours, strong $/hr.
        for day in [2, 9, 16] {
            records.append(record(2026, 7, day, cents: 8000, hoursWorked: 4))
        }
        let engine = StatsEngine(records: records)
        let verdict = engine.moves(referenceDate: date(2026, 7, 24)).first { $0.id == "doublesVerdict" }
        #expect(verdict != nil)
        #expect(verdict?.title == "Doubles Cost You")
    }

    @Test("rate leader fires when one weekday clearly out-earns per hour")
    func rateLeaderFires() {
        var records: [TipRecord] = []
        for week in 0..<3 {
            records.append(record(2026, 7, 3 + week * 7, cents: 20000, hoursWorked: 4))  // Friday, $50/hr
            records.append(record(2026, 6, 29 + week * 7, cents: 10000, hoursWorked: 5)) // Monday, $20/hr
        }
        let engine = StatsEngine(records: records)
        let leader = engine.moves(referenceDate: date(2026, 7, 24)).first { $0.id == "rateLeader" }
        #expect(leader != nil)
        #expect(leader?.title.contains("Friday") == true)
    }

    @Test("tip percent signal fires when one weekday clearly tips a higher percent")
    func tipPercentSignalFires() {
        var records: [TipRecord] = []
        for week in 0..<3 {
            records.append(record(2026, 7, 3 + week * 7, cents: 15000, salesCents: 50000)) // Friday, 30%
            records.append(record(2026, 6, 29 + week * 7, cents: 5000, salesCents: 50000)) // Monday, 10%
        }
        let engine = StatsEngine(records: records)
        let signal = engine.moves(referenceDate: date(2026, 7, 24)).first { $0.id == "tipPercentSignal" }
        #expect(signal != nil)
        #expect(signal?.title.contains("Friday") == true)
    }

    @Test("moves caps at 3 and ranks by annualized impact, descending")
    func movesRankedAndCapped() {
        var records: [TipRecord] = []
        for week in 0..<3 {
            records.append(record(2026, 7, 3 + week * 7, cents: 20000, isDouble: false, hoursWorked: 4, salesCents: 50000)) // Friday
            records.append(record(2026, 6, 29 + week * 7, cents: 5000, hoursWorked: 5, salesCents: 50000))                  // Monday
        }
        for day in [1, 8, 15] {
            records.append(record(2026, 7, day, cents: 12000, isDouble: true, hoursWorked: 10))
        }
        for day in [2, 9, 16] {
            records.append(record(2026, 7, day, cents: 8000, hoursWorked: 4))
        }
        let engine = StatsEngine(records: records)
        let moves = engine.moves(referenceDate: date(2026, 7, 24))
        #expect(moves.count <= 3)
        #expect(moves == moves.sorted { $0.annualImpactCents > $1.annualImpactCents })
    }

    @Test("moves is empty with no history at all — silence, not weak advice")
    func movesEmptyWithoutHistory() {
        let engine = StatsEngine(records: [])
        #expect(engine.moves().isEmpty)
    }

    @Test("weekday swap stays silent when a real-looking delta sits inside noisy, high-variance history")
    func weekdaySwapSilencedByHighVariance() {
        let records = [
            // Fridays: $20, $100, $20 — wide spread, avg $46.67.
            record(2026, 7, 3, cents: 2000),
            record(2026, 7, 10, cents: 10000),
            record(2026, 7, 17, cents: 2000),
            // Mondays: $5, $70, $5 — also wide spread, avg $26.67.
            record(2026, 6, 29, cents: 500),
            record(2026, 7, 6, cents: 7000),
            record(2026, 7, 13, cents: 500)
        ]
        let engine = StatsEngine(records: records)
        // The $20 delta clears the flat $15 floor on its own, but the
        // pooled spread across both weekdays is wide enough that this
        // shouldn't read as a real signal.
        #expect(engine.moves(referenceDate: date(2026, 7, 24)).first { $0.id == "weekdaySwap" } == nil)
    }

    @Test("weekday swap still fires when a comparable delta sits inside consistent, low-variance history")
    func weekdaySwapFiresWithLowVariance() {
        let records = [
            record(2026, 7, 3, cents: 4000),
            record(2026, 7, 10, cents: 4200),
            record(2026, 7, 17, cents: 3800),
            record(2026, 6, 29, cents: 2000),
            record(2026, 7, 6, cents: 2200),
            record(2026, 7, 13, cents: 1800)
        ]
        let engine = StatsEngine(records: records)
        let swap = engine.moves(referenceDate: date(2026, 7, 24)).first { $0.id == "weekdaySwap" }
        #expect(swap != nil)
        #expect(swap?.body.contains("across 3 Fridays") == true)
        #expect(swap?.body.contains("across 3 Mondays") == true)
    }

    @Test("rate leader stays silent when a real-looking $/hr delta sits inside noisy history")
    func rateLeaderSilencedByHighVariance() {
        let records = [
            record(2026, 7, 3, cents: 2000, hoursWorked: 2),
            record(2026, 7, 10, cents: 14000, hoursWorked: 2),
            record(2026, 7, 17, cents: 2000, hoursWorked: 2),
            record(2026, 6, 29, cents: 1000, hoursWorked: 2),
            record(2026, 7, 6, cents: 7000, hoursWorked: 2),
            record(2026, 7, 13, cents: 1000, hoursWorked: 2)
        ]
        let engine = StatsEngine(records: records)
        #expect(engine.moves(referenceDate: date(2026, 7, 24)).first { $0.id == "rateLeader" } == nil)
    }

    @Test("rate leader still fires when a comparable $/hr delta sits inside consistent history")
    func rateLeaderFiresWithLowVariance() {
        let records = [
            record(2026, 7, 3, cents: 3000, hoursWorked: 2),
            record(2026, 7, 10, cents: 3100, hoursWorked: 2),
            record(2026, 7, 17, cents: 2900, hoursWorked: 2),
            record(2026, 6, 29, cents: 1200, hoursWorked: 2),
            record(2026, 7, 6, cents: 1300, hoursWorked: 2),
            record(2026, 7, 13, cents: 1100, hoursWorked: 2)
        ]
        let engine = StatsEngine(records: records)
        #expect(engine.moves(referenceDate: date(2026, 7, 24)).first { $0.id == "rateLeader" } != nil)
    }
}

@Suite("Follow-ups")
struct FollowUpTests {
    // Shared before-period fixture for the weekday-keyed tests below:
    // Friday every other week (4 of 8 weeks) at $150, Monday every week
    // (8) at $80 — establishes Friday as the clear best weekday as of
    // shownAt, with a real pace to compare the "after" period against.
    private static let beforeFridaysWide: [(Int, Int)] = [(6, 26), (6, 12), (5, 29), (5, 15)]
    private static let beforeMondays: [(Int, Int)] = [(6, 22), (6, 15), (6, 8), (6, 1), (5, 25), (5, 18), (5, 11), (5, 4)]

    @Test("weekday swap follow-up fires when Friday nights increased and paid off versus the old pace")
    func weekdaySwapFollowUpFires() {
        var records: [TipRecord] = []
        for (m, d) in Self.beforeFridaysWide { records.append(record(2026, m, d, cents: 15000)) }
        for (m, d) in Self.beforeMondays { records.append(record(2026, m, d, cents: 8000)) }
        // After: Friday every week (5), paying slightly more.
        for (m, d) in [(7, 3), (7, 10), (7, 17), (7, 24), (7, 31)] { records.append(record(2026, m, d, cents: 16000)) }

        let engine = StatsEngine(records: records)
        let shownAt = date(2026, 6, 30)
        let referenceDate = date(2026, 8, 1)
        let followUp = engine.followUps(ledger: ["weekdaySwap": shownAt], referenceDate: referenceDate).first
        #expect(followUp?.id == "weekdaySwap")
        #expect(followUp?.title.contains("Friday") == true)
        #expect((followUp?.dollarEffectCents ?? 0) > 0)
    }

    @Test("follow-up stays silent before the 28-day age gate")
    func followUpSilentBeforeAgeGate() {
        var records: [TipRecord] = []
        for (m, d) in Self.beforeFridaysWide { records.append(record(2026, m, d, cents: 15000)) }
        for (m, d) in Self.beforeMondays { records.append(record(2026, m, d, cents: 8000)) }
        for (m, d) in [(7, 3), (7, 10)] { records.append(record(2026, m, d, cents: 16000)) }

        let engine = StatsEngine(records: records)
        let shownAt = date(2026, 6, 30)
        let referenceDate = date(2026, 7, 10) // only 10 days after shownAt
        #expect(engine.followUps(ledger: ["weekdaySwap": shownAt], referenceDate: referenceDate).isEmpty)
    }

    @Test("follow-up stays silent when Friday frequency didn't actually change")
    func followUpSilentWithoutBehaviorChange() {
        var records: [TipRecord] = []
        for (m, d) in Self.beforeFridaysWide { records.append(record(2026, m, d, cents: 15000)) }
        for (m, d) in Self.beforeMondays { records.append(record(2026, m, d, cents: 8000)) }
        // After: Friday every OTHER week too — same pace as before, just continued.
        for (m, d) in [(7, 10), (7, 24)] { records.append(record(2026, m, d, cents: 15000)) }

        let engine = StatsEngine(records: records)
        let shownAt = date(2026, 6, 30)
        let referenceDate = date(2026, 8, 1)
        #expect(engine.followUps(ledger: ["weekdaySwap": shownAt], referenceDate: referenceDate).isEmpty)
    }

    @Test("follow-up stays silent when behavior changed but the dollar effect doesn't clear materiality")
    func followUpSilentWithoutMaterialEffect() {
        var records: [TipRecord] = []
        // Before: only 3 Fridays (the minimum to qualify), low value.
        for (m, d) in [(6, 26), (5, 29), (5, 15)] { records.append(record(2026, m, d, cents: 1000)) }
        for (m, d) in Self.beforeMondays { records.append(record(2026, m, d, cents: 500)) }
        // After: Friday every week, but at the SAME low rate — frequency
        // rose, but there isn't enough real money behind it to matter.
        for (m, d) in [(7, 3), (7, 10), (7, 17), (7, 24), (7, 31)] { records.append(record(2026, m, d, cents: 1000)) }

        let engine = StatsEngine(records: records)
        let shownAt = date(2026, 6, 30)
        let referenceDate = date(2026, 8, 1)
        #expect(engine.followUps(ledger: ["weekdaySwap": shownAt], referenceDate: referenceDate).isEmpty)
    }

    @Test("doubles verdict follow-up uses isDouble, not a weekday, as its matching slice")
    func doublesVerdictFollowUpFires() {
        var records: [TipRecord] = []
        // Before: a double every other week (4 of 8), modest pay.
        for (m, d) in [(6, 26), (6, 12), (5, 29), (5, 15)] { records.append(record(2026, m, d, cents: 12000, isDouble: true)) }
        for (m, d) in [(6, 22), (6, 15), (6, 8), (6, 1)] { records.append(record(2026, m, d, cents: 6000)) }
        // After: a double every week, paying more.
        for (m, d) in [(7, 3), (7, 10), (7, 17), (7, 24), (7, 31)] { records.append(record(2026, m, d, cents: 13000, isDouble: true)) }

        let engine = StatsEngine(records: records)
        let shownAt = date(2026, 6, 30)
        let referenceDate = date(2026, 8, 1)
        let followUp = engine.followUps(ledger: ["doublesVerdict": shownAt], referenceDate: referenceDate).first
        #expect(followUp?.id == "doublesVerdict")
        #expect((followUp?.dollarEffectCents ?? 0) > 0)
    }

    @Test("followUps is empty for an id with no ledger entry old enough to judge")
    func followUpsEmptyWithoutQualifyingLedgerEntries() {
        let engine = StatsEngine(records: [record(2026, 7, 3, cents: 15000)])
        #expect(engine.followUps(ledger: [:], referenceDate: date(2026, 8, 1)).isEmpty)
    }
}

@Suite("Work rhythm")
struct WorkRhythmTests {
    @Test("a weekday worked most of its occurrences counts as usual")
    func routineWeekdayIsUsual() {
        // Same weekday every 7 days: worked day 3, 10, 17; referenceDate on
        // day 24 (a 4th occurrence never worked) - 3/4 occurrences, well
        // past both the count and frequency floors.
        let records = [
            record(2026, 7, 3, cents: 5000),
            record(2026, 7, 10, cents: 5000),
            record(2026, 7, 17, cents: 5000)
        ]
        let engine = StatsEngine(records: records)
        let rhythm = engine.workRhythm(referenceDate: date(2026, 7, 24))
        let workedWeekday = Calendar.current.component(.weekday, from: date(2026, 7, 3))
        #expect(rhythm.usualWeekdays.contains(workedWeekday))
    }

    @Test("a single one-off shift never counts as usual, no matter the frequency")
    func oneOffShiftIsNotUsual() {
        let records = [record(2026, 7, 3, cents: 5000)]
        let engine = StatsEngine(records: records)
        let rhythm = engine.workRhythm(referenceDate: date(2026, 7, 3))
        #expect(rhythm.usualWeekdays.isEmpty)
    }

    @Test("occasional pickup shifts on a weekday stay below the frequency floor")
    func occasionalPickupIsNotUsual() {
        // Worked 2 of 5 occurrences (40%) - clears the count floor but not
        // the 50% frequency floor.
        let records = [
            record(2026, 7, 3, cents: 5000),
            record(2026, 7, 24, cents: 5000)
        ]
        let engine = StatsEngine(records: records)
        let rhythm = engine.workRhythm(referenceDate: date(2026, 7, 31))
        let weekday = Calendar.current.component(.weekday, from: date(2026, 7, 3))
        #expect(!rhythm.usualWeekdays.contains(weekday))
    }

    @Test("typical log hour is the median of same-day-logged hours")
    func typicalLogHourIsMedian() {
        let records = [
            record(2026, 7, 1, cents: 5000, recordedHour: 17),
            record(2026, 7, 2, cents: 5000, recordedHour: 18),
            record(2026, 7, 3, cents: 5000, recordedHour: 19)
        ]
        let engine = StatsEngine(records: records)
        #expect(engine.workRhythm(referenceDate: date(2026, 7, 3)).typicalLogHour == 18)
    }

    @Test("backfilled entries never contribute to typical log hour, even with enough of them")
    func backfilledEntriesExcludedFromTypicalHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let backfilled = TipRecord(
            date: date(2026, 7, 1),
            amountCents: 5000,
            kind: .cash,
            isDouble: false,
            recordedAt: calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date(2026, 7, 5))
        )
        let records = [
            backfilled, backfilled, backfilled, backfilled,
            record(2026, 7, 2, cents: 5000, recordedHour: 18),
            record(2026, 7, 3, cents: 5000, recordedHour: 18)
        ]
        let engine = StatsEngine(records: records)
        // Only 2 genuine same-day-logged records - below the minimum of 3.
        #expect(engine.workRhythm(referenceDate: date(2026, 7, 5)).typicalLogHour == nil)
    }

    @Test("no history yet means no usual weekdays and no typical hour")
    func noHistoryYieldsEmptyRhythm() {
        let engine = StatsEngine(records: [])
        let rhythm = engine.workRhythm(referenceDate: date(2026, 7, 3))
        #expect(rhythm.usualWeekdays.isEmpty)
        #expect(rhythm.typicalLogHour == nil)
    }
}

@Suite("Projection")
struct ProjectionTests {
    @Test("projection adds one estimated night per remaining usual weekday, at that weekday's average")
    func midPeriodProjection() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        // Monday average $50, Wednesday average $80. Both usual.
        let engine = StatsEngine(records: [
            record(2026, 7, 6, cents: 5000),  // Monday, inside the period
            record(2026, 6, 22, cents: 5000), // Monday, prior history
            record(2026, 7, 1, cents: 8000),  // Wednesday, prior history
        ])
        let rhythm = WorkRhythm(usualWeekdays: [
            Calendar.current.component(.weekday, from: date(2026, 7, 6)),
            Calendar.current.component(.weekday, from: date(2026, 7, 1))
        ], typicalLogHour: nil)
        // As of July 6 (day 1), remaining usual nights through July 19:
        // Wednesdays July 8 & 15 ($80 each) and Mondays July 13 ($50).
        let projected = engine.projectedPeriodTotal(period: period, asOf: date(2026, 7, 6), rhythm: rhythm)
        #expect(projected == 5000 + 8000 + 8000 + 5000)
    }

    @Test("projection on the last day of the period adds nothing further")
    func lastDayProjection() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [record(2026, 7, 6, cents: 5000)])
        let rhythm = WorkRhythm(usualWeekdays: [Calendar.current.component(.weekday, from: date(2026, 7, 6))], typicalLogHour: nil)
        let projected = engine.projectedPeriodTotal(period: period, asOf: date(2026, 7, 19), rhythm: rhythm)
        #expect(projected == engine.periodToDateTotal(period: period, asOf: date(2026, 7, 19)))
    }

    @Test("projection is nil without any usual weekdays yet")
    func noRhythmProjectionIsNil() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [])
        let projected = engine.projectedPeriodTotal(period: period, asOf: date(2026, 7, 6), rhythm: WorkRhythm(usualWeekdays: [], typicalLogHour: nil))
        #expect(projected == nil)
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

    @Test("a weekday with no prior history reveals as a first-weekday callout, never a self-compared $0.00 average")
    func firstWeekdayLoggedNeverSelfCompares() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let tuesday = date(2026, 7, 7)
        // June 20 (a Saturday, outside the period) sets an all-time best
        // higher than tonight, so tonight isn't a record. July 6 (a Monday,
        // inside the period, before tonight) rules out "first shift of the
        // period." Neither is a Tuesday, so tonight is the first Tuesday
        // ever logged - averageForWeekday(tuesday) is nil. The old code's
        // `?? Double(cents)` fallback compared tonight against itself,
        // always producing a nonsense "$0.00 above your Tuesday average."
        let engine = StatsEngine(records: [
            record(2026, 6, 20, cents: 8000),
            record(2026, 7, 6, cents: 1000)
        ])
        let result = engine.reveal(forNightAt: tuesday, cents: 5000, period: period)
        #expect(result.comparison == .firstWeekdayLogged(weekday: Calendar.current.component(.weekday, from: tuesday)))
        #expect(!result.isRecord)
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
        guard case .weekdayAverage(let weekday, let deltaCents, let periodRank, let periodNightCount, let sampleCount) = result.comparison else {
            Issue.record("expected weekdayAverage case")
            return
        }
        #expect(weekday == monday)
        #expect(deltaCents == -500) // 5500 - 6000 (the only other Monday on record)
        #expect(periodRank == 1)    // tonight beats all 3 in-period nights logged so far
        #expect(periodNightCount == 3)
        #expect(sampleCount == 1)   // only one other Monday to average against
    }

    @Test("reveal has no rate clause when tonight has no hours logged")
    func revealNoRateClauseWithoutHours() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [])
        let result = engine.reveal(forNightAt: date(2026, 7, 6), cents: 5000, period: period)
        #expect(result.rateClause == nil)
    }

    @Test("reveal's rate clause marks the best rate this period when nothing else beats it")
    func revealRateClauseBestThisPeriod() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [
            record(2026, 7, 6, cents: 10000, hoursWorked: 5) // $20/hr, earlier this period
        ])
        // Tonight: $30/hr, beats the $20/hr night earlier this period.
        let result = engine.reveal(forNightAt: date(2026, 7, 8), cents: 15000, period: period, hoursWorked: 5)
        #expect(result.rateClause == .rate(dollarsPerHour: 30, isBestThisPeriod: true))
    }

    @Test("reveal's rate clause is not the best when another rate night this period beats it")
    func revealRateClauseNotBest() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(records: [
            record(2026, 7, 6, cents: 20000, hoursWorked: 5) // $40/hr, earlier this period
        ])
        let result = engine.reveal(forNightAt: date(2026, 7, 8), cents: 15000, period: period, hoursWorked: 5)
        #expect(result.rateClause == .rate(dollarsPerHour: 30, isBestThisPeriod: false))
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

    @Test("first weekday logged copy never claims a $0.00 average")
    func firstWeekdayLoggedCopy() {
        let text = RevealCopy.comparison(for: .firstWeekdayLogged(weekday: 3))
        #expect(text.contains("first logged"))
        #expect(!text.contains("$0.00"))
        #expect(!text.contains("average"))
    }

    @Test("weekday average copy includes a period rank clincher only when it qualifies")
    func weekdayAverageWithRank() {
        let text = RevealCopy.comparison(for: .weekdayAverage(weekday: 2, deltaCents: 3400, periodRank: 3, periodNightCount: 5, sampleCount: 8))
        #expect(text.contains("above your"))
        #expect(text.contains("Third-best night this period."))
    }

    @Test("weekday average copy omits the clincher when the rank doesn't qualify")
    func weekdayAverageWithoutRank() {
        let text = RevealCopy.comparison(for: .weekdayAverage(weekday: 2, deltaCents: -1200, periodRank: nil, periodNightCount: 5, sampleCount: 8))
        #expect(text.contains("below your"))
        #expect(!text.contains("period."))
    }

    @Test("weekday average copy self-discloses a thin sample below 5 nights")
    func weekdayAverageDisclosesThinSample() {
        let text = RevealCopy.comparison(for: .weekdayAverage(weekday: 2, deltaCents: 3400, periodRank: nil, periodNightCount: 1, sampleCount: 2))
        #expect(text.contains("(across 2 Mondays)"))
    }

    @Test("weekday average copy stays clean at 5 nights or more")
    func weekdayAverageStaysCleanAtFiveOrMore() {
        let text = RevealCopy.comparison(for: .weekdayAverage(weekday: 2, deltaCents: 3400, periodRank: nil, periodNightCount: 5, sampleCount: 5))
        #expect(!text.contains("across"))
    }

    @Test("pace line reads ahead, behind, and even correctly")
    func paceLineWording() {
        #expect(RevealCopy.paceLine(deltaCents: 12000).contains("ahead of"))
        #expect(RevealCopy.paceLine(deltaCents: -5000).contains("behind"))
        #expect(RevealCopy.paceLine(deltaCents: 0) == "Even with last period at this point.")
    }

    @Test("compact pace line fits a widget caption: signed amount, no sentence")
    func compactPaceLineWording() {
        #expect(RevealCopy.compactPaceLine(deltaCents: 12000) == "+$120.00 vs last period")
        #expect(RevealCopy.compactPaceLine(deltaCents: -5000) == "-$50.00 vs last period")
        #expect(RevealCopy.compactPaceLine(deltaCents: 0) == "Even vs last period")
    }

    @Test("rate clause names the best-this-period rate as a whole dollar amount")
    func rateClauseBestThisPeriod() {
        let text = RevealCopy.rateClause(for: .rate(dollarsPerHour: 41.2, isBestThisPeriod: true))
        #expect(text == "$41/hr, your best rate this period.")
    }

    @Test("rate clause without the best-rate flag stays a plain shift fact")
    func rateClauseOrdinary() {
        let text = RevealCopy.rateClause(for: .rate(dollarsPerHour: 18, isBestThisPeriod: false))
        #expect(text == "$18/hr this shift.")
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

    @Test("an explicit shift period wins over the recordedAt proxy, even when they disagree")
    func explicitShiftPeriodBeatsProxy() {
        // Logged at 8pm (would proxy to dinner) but explicitly tagged lunch.
        let records = [
            record(2026, 7, 1, cents: 1000, recordedHour: 20, shiftPeriod: .lunch),
            record(2026, 7, 2, cents: 2000, recordedHour: 13, shiftPeriod: .lunch),
            record(2026, 7, 3, cents: 3000, recordedHour: 19),
            record(2026, 7, 4, cents: 4000, recordedHour: 20),
            record(2026, 7, 5, cents: 5000, recordedHour: 21)
        ]
        let engine = StatsEngine(records: records)
        let facts = engine.insightsFacts(referenceDate: date(2026, 7, 10))
        // July 1 counts as lunch (explicit), not dinner (what the 8pm
        // proxy would have said) — 1000 + 2000 = 3000 lunch, across 2 nights.
        #expect(facts?.lunchDinner?.lunchShiftCount == 2)
        #expect(facts?.lunchDinner?.lunchCents == 3000)
        #expect(facts?.lunchDinner?.dinnerShiftCount == 3)
    }

    @Test("the recordedAt proxy still classifies legacy nights with no explicit shift period")
    func proxyStillWorksForLegacyNights() {
        let records = [
            record(2026, 7, 1, cents: 1000, recordedHour: 12),
            record(2026, 7, 2, cents: 2000, recordedHour: 13),
            record(2026, 7, 3, cents: 3000, recordedHour: 19),
            record(2026, 7, 4, cents: 4000, recordedHour: 20),
            record(2026, 7, 5, cents: 5000, recordedHour: 21)
        ]
        let engine = StatsEngine(records: records)
        let facts = engine.insightsFacts(referenceDate: date(2026, 7, 10))
        #expect(facts?.lunchDinner?.lunchShiftCount == 2)
        #expect(facts?.lunchDinner?.dinnerShiftCount == 3)
    }

    @Test("a backfilled night with no explicit shift period is excluded, never guessed at")
    func backfillWithoutExplicitValueStillExcluded() {
        // Backfilled (recordedAt days later) and never tagged explicitly.
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
        #expect(facts?.lunchDinner?.lunchShiftCount == 2)
        #expect(facts?.lunchDinner?.dinnerShiftCount == 3)
    }

    @Test("a night counts once for lunch/dinner even with both a cash and credit record")
    func lunchDinnerCountsNightsNotRecords() {
        var records = [
            record(2026, 7, 1, cents: 1000, kind: .credit, recordedHour: 12),
            record(2026, 7, 1, cents: 500, kind: .cash, recordedHour: 12)
        ]
        records += (2...5).map { record(2026, 7, $0, cents: 1000, recordedHour: 19) }
        let engine = StatsEngine(records: records)
        let facts = engine.insightsFacts(referenceDate: date(2026, 7, 10))
        // Two records, one night — must count once, gross summed across kind.
        #expect(facts?.lunchDinner?.lunchShiftCount == 1)
        #expect(facts?.lunchDinner?.lunchCents == 1500)
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

    @Test("overall total is net of tip-outs, and tip-out fact reports the total tipped out")
    func totalIsNetAndTipOutFactPopulates() {
        let records = [
            record(2026, 7, 1, cents: 10000, tipOutCents: 1000),
            record(2026, 7, 2, cents: 10000, tipOutCents: 500),
            record(2026, 7, 3, cents: 10000),
            record(2026, 7, 4, cents: 10000),
            record(2026, 7, 5, cents: 10000)
        ]
        let engine = StatsEngine(records: records)
        let facts = engine.insightsFacts(referenceDate: date(2026, 7, 10))
        #expect(facts?.totalCents == 48500) // 50000 gross - 1500 total tip-out
        #expect(facts?.totalTipOutCents == 1500)
    }

    @Test("tip-out fact is zero when nothing was tipped out")
    func tipOutFactZeroWithoutAny() {
        let records = (1...5).map { record(2026, 7, $0, cents: 1000) }
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 10))?.totalTipOutCents == 0)
    }

    @Test("sales facts are nil below the minimum nights with sales logged")
    func salesFactsNilBelowMinimum() {
        let records = [
            record(2026, 7, 1, cents: 10000, salesCents: 50000),
            record(2026, 7, 2, cents: 10000, salesCents: 50000),
            record(2026, 7, 3, cents: 10000),
            record(2026, 7, 4, cents: 10000),
            record(2026, 7, 5, cents: 10000)
        ]
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 10))?.sales == nil)
    }

    @Test("sales facts compute the blended overall tip percent once enough nights have sales")
    func salesFactsOverall() {
        let records = [
            record(2026, 7, 1, cents: 10000, salesCents: 50000), // 20%
            record(2026, 7, 2, cents: 3000, salesCents: 10000),  // 30%
            record(2026, 7, 3, cents: 5000, salesCents: 25000),  // 20%
            record(2026, 7, 4, cents: 1000),
            record(2026, 7, 5, cents: 1000)
        ]
        let engine = StatsEngine(records: records)
        let sales = engine.insightsFacts(referenceDate: date(2026, 7, 10))?.sales
        #expect(sales?.nightsWithSales == 3)
        // 18000 gross / 85000 sales.
        #expect(sales.map { abs($0.overallTipPercent - (18000.0 / 85000.0 * 100)) < 0.001 } == true)
    }

    @Test("rate facts are nil below the minimum nights with hours logged")
    func rateFactsNilBelowMinimum() {
        let records = [
            record(2026, 7, 1, cents: 1000, hoursWorked: 5),
            record(2026, 7, 2, cents: 1000, hoursWorked: 5),
            record(2026, 7, 3, cents: 1000), // no hours
            record(2026, 7, 4, cents: 1000),
            record(2026, 7, 5, cents: 1000)
        ]
        let engine = StatsEngine(records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 10))?.rate == nil)
    }

    @Test("rate facts compute the blended overall rate once enough nights have hours")
    func rateFactsOverall() {
        let records = [
            record(2026, 7, 1, cents: 10000, hoursWorked: 5), // $20/hr
            record(2026, 7, 2, cents: 6000, hoursWorked: 2),  // $30/hr
            record(2026, 7, 3, cents: 4000, hoursWorked: 2),  // $20/hr
            record(2026, 7, 4, cents: 1000),
            record(2026, 7, 5, cents: 1000)
        ]
        let engine = StatsEngine(records: records)
        let rate = engine.insightsFacts(referenceDate: date(2026, 7, 10))?.rate
        #expect(rate?.nightsWithHours == 3)
        // $200 over 9 hours.
        #expect(rate.map { abs($0.overallDollarsPerHour - (200.0 / 9)) < 0.001 } == true)
    }

    @Test("rate facts split lunch vs dinner and doubles vs solo only over rate nights")
    func rateFactsSplits() {
        let records = [
            record(2026, 7, 1, cents: 10000, isDouble: true, recordedHour: 20, hoursWorked: 9), // dinner, double: $11.11/hr
            record(2026, 7, 2, cents: 4000, recordedHour: 13, hoursWorked: 4),                  // lunch, solo: $10/hr
            record(2026, 7, 3, cents: 5000, recordedHour: 19, hoursWorked: 5),                  // dinner, solo: $10/hr
            record(2026, 7, 4, cents: 1000),
            record(2026, 7, 5, cents: 1000)
        ]
        let engine = StatsEngine(records: records)
        let rate = engine.insightsFacts(referenceDate: date(2026, 7, 10))?.rate
        #expect(rate?.doubleDollarsPerHour != nil)
        #expect(rate?.soloDollarsPerHour != nil)
        #expect(rate?.lunchDollarsPerHour == 10)
        #expect(rate.map { abs($0.dinnerDollarsPerHour! - (150.0 / 14)) < 0.001 } == true)
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
