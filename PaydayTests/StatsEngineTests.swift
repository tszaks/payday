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

private func record(_ year: Int, _ month: Int, _ day: Int, cents: Int, kind: TipKind = .cash, isDouble: Bool = false, recordedHour: Int? = nil, hoursWorked: Double? = nil, tipOutCents: Int? = nil, salesCents: Int? = nil, shiftPeriod: ShiftPeriod? = nil, shiftID: UUID? = nil, clockInHour: Int? = nil, clockOutHour: Int? = nil, receiptMetrics: ShiftReceiptMetrics? = nil, note: String? = nil) -> TipRecord {
    let shiftDate = date(year, month, day)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let recordedAt = recordedHour.flatMap { hour in
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shiftDate)
    }
    let clockIn = clockInHour.flatMap { hour in
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shiftDate)
    }
    let clockOut = clockOutHour.flatMap { hour in
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shiftDate)
    }
    return TipRecord(date: shiftDate, amountCents: cents, kind: kind, isDouble: isDouble, recordedAt: recordedAt, hoursWorked: hoursWorked, tipOutCents: tipOutCents, salesCents: salesCents, shiftPeriod: shiftPeriod, shiftID: shiftID, clockIn: clockIn, clockOut: clockOut, receiptMetrics: receiptMetrics, note: note)
}

private func receiptFacts(guests: Int, checks: Int, tables: Int, tableSource: TableCountSource, netSalesCents: Int, categories: [ShiftReceiptMetrics.CategorySales] = []) -> ShiftReceiptMetrics {
    ShiftReceiptMetrics(
        guestCount: guests,
        creditCheckCount: checks,
        tableCount: tables,
        tableCountSource: tableSource,
        netSalesCents: netSalesCents,
        cashSalesCents: 0,
        categorySales: categories
    )
}

/// Two distinct shift ids for building emergent "double" days in tests — a
/// double is now two shifts on one calendar day, each with its own id.
private let lunchShift = UUID()
private let dinnerShift = UUID()

@Suite("Nightly totals")
struct NightlyTotalsTests {
    @Test("cash and credit on the same night sum into one shift")
    func sameNightSums() {
        let records = [
            record(2026, 7, 1, cents: 5000, kind: .cash),
            record(2026, 7, 1, cents: 3000, kind: .credit)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let nights = engine.nightlyTotals()
        #expect(nights.count == 1)
        #expect(nights[0].cents == 8000)
    }

    @Test("distinct days produce distinct nights")
    func distinctDays() {
        let records = [record(2026, 7, 1, cents: 5000), record(2026, 7, 2, cents: 6000)]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        #expect(engine.nightlyTotals().count == 2)
    }

    @Test("a night's total is net of any tip-out logged that night")
    func nightlyTotalIsNet() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit, tipOutCents: 1500),
            record(2026, 7, 1, cents: 3200, kind: .cash)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let nights = engine.nightlyTotals()
        #expect(nights.count == 1)
        // 8600 + 3200 - 1500 tip-out = 10300.
        #expect(nights[0].cents == 10300)
    }

    @Test("a night with no tip-out logged has its full gross as the total")
    func nightlyTotalWithoutTipOutIsGross() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 1, cents: 5000)])
        #expect(engine.nightlyTotals()[0].cents == 5000)
    }

    @Test("tip-out on the 'wrong' entry (cash, when a credit entry also exists) still nets correctly")
    func nightlyTotalReadsTipOutFromWrongEntry() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit),
            record(2026, 7, 1, cents: 3200, kind: .cash, tipOutCents: 1500)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        // 8600 + 3200 - 1500 = 10300, not 11800 (ignoring it) or double-subtracted.
        #expect(engine.nightlyTotals()[0].cents == 10300)
    }

    @Test("tip-out set on BOTH entries (corruption) is never double-subtracted")
    func nightlyTotalNeverDoubleSubtractsTipOut() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit, tipOutCents: 1500),
            record(2026, 7, 1, cents: 3200, kind: .cash, tipOutCents: 1000)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        // Credit's 1500 wins outright — never 1500+1000=2500 subtracted.
        #expect(engine.nightlyTotals()[0].cents == 8600 + 3200 - 1500)
    }
}

@Suite("Records")
struct RecordsTests {
    @Test("best night ever excludes the night passed as excluding")
    func bestNightExcludesTonight() {
        let records = [record(2026, 7, 1, cents: 9000), record(2026, 7, 8, cents: 5000)]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let best = engine.bestNightEver(excluding: date(2026, 7, 1))
        #expect(best?.cents == 5000)
    }

    @Test("best night ever is nil with no history")
    func noHistoryIsNil() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [])
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let best = engine.bestNight(in: period)
        #expect(best?.cents == 9000)
    }

    @Test("best night in a period is nil when nothing was logged in it")
    func bestNightInPeriodNilWhenEmpty() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 6, 30, cents: 20000)])
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let wednesday = Calendar.current.component(.weekday, from: date(2026, 7, 1))
        let best = engine.bestNight(forWeekday: wednesday)
        #expect(best?.cents == 9000)
    }

    @Test("average for a weekday averages only matching nights")
    func weekdayAverage() {
        let records = [record(2026, 7, 1, cents: 8000), record(2026, 7, 8, cents: 6000)]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let wednesday = Calendar.current.component(.weekday, from: date(2026, 7, 1))
        #expect(engine.averageForWeekday(wednesday) == 7000)
    }

    @Test("average for a weekday is nil with no matching nights")
    func weekdayAverageNil() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 1, cents: 8000)])
        // Thursday never occurred in the fixture.
        let thursday = Calendar.current.component(.weekday, from: date(2026, 7, 2))
        #expect(engine.averageForWeekday(thursday) == nil)
    }

    @Test("best night ever is per-shift: a double day's summed total can't crown a bigger single shift")
    func bestNightEverIsPerShift() {
        // A double day of two $60 closeouts ($120 combined) plus one honest
        // $90 single shift. Records are per-shift, so the record is $90 — the
        // day's $120 sum never becomes a single "best night."
        let records = [
            record(2026, 7, 1, cents: 6000, shiftID: UUID()),
            record(2026, 7, 1, cents: 6000, shiftID: UUID()),
            record(2026, 7, 8, cents: 9000, shiftID: UUID())
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        #expect(engine.bestNightEver()?.cents == 9000)
    }
}

@Suite("Pace")
struct PaceTests {
    @Test("period-to-date total only counts entries through the given date")
    func periodToDate() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let records = [record(2026, 7, 6, cents: 5000), record(2026, 7, 15, cents: 6000), record(2026, 7, 18, cents: 7000)]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        #expect(engine.periodToDateTotal(period: period, asOf: date(2026, 7, 15)) == 11000)
    }

    @Test("period-to-date total nets any logged tip-outs")
    func periodToDateIsNet() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let records = [record(2026, 7, 6, cents: 5000, tipOutCents: 1000), record(2026, 7, 15, cents: 6000)]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        // "asOf" is 2 days into the current period, so the comparable window
        // is priorPeriod.start through priorPeriod.start + 2 days.
        let total = engine.priorPeriodComparableTotal(currentPeriod: currentPeriod, priorPeriod: priorPeriod, asOf: date(2026, 7, 8))
        #expect(total == 11000)
    }

    @Test("pace delta is nil with no prior period")
    func paceDeltaNilWithoutPrior() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [])
        #expect(engine.paceDelta(currentPeriod: period, priorPeriod: nil, asOf: date(2026, 7, 8)) == nil)
    }

    @Test("pace delta is positive when ahead of the prior period")
    func paceDeltaAhead() {
        let currentPeriod = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let priorPeriod = PayPeriod(start: date(2026, 6, 22), end: date(2026, 7, 5))
        let records = [record(2026, 7, 6, cents: 10000), record(2026, 6, 22, cents: 4000)]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let delta = engine.paceDelta(currentPeriod: currentPeriod, priorPeriod: priorPeriod, asOf: date(2026, 7, 6))
        #expect(delta == 6000)
    }
}

/// Fourteen-day periods ending the Sunday before each listed start, built
/// back from a current period starting 2026-07-06 — the shape every
/// usual-pace test below shares.
private func biweeklyPeriods(count: Int, currentStart: Date) -> [PayPeriod] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return (1...count).map { step in
        let start = calendar.date(byAdding: .day, value: -14 * step, to: currentStart)!
        let end = calendar.date(byAdding: .day, value: 13, to: start)!
        return PayPeriod(start: start, end: end)
    }
}

@Suite("Usual pace baseline (median of recent periods)")
struct UsualPaceTests {
    private let current = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))

    /// Day 2 of each of the five prior periods, so the "at this point"
    /// cutoff lands on a day that actually has a record in every one.
    private func recordsAcrossPriorPeriods(_ centsPerPeriod: [Int]) -> [TipRecord] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let periods = biweeklyPeriods(count: centsPerPeriod.count, currentStart: date(2026, 7, 6))
        return zip(periods, centsPerPeriod).map { period, cents in
            let day = calendar.date(byAdding: .day, value: 1, to: period.start)!
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            return record(parts.year!, parts.month!, parts.day!, cents: cents)
        }
    }

    @Test("baseline is the median of the prior periods at the same point, not the most recent one")
    func baselineIsMedianNotLastPeriod() {
        // Most recent period is a $900 outlier; the median of the five is $300.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: recordsAcrossPriorPeriods([90000, 30000, 20000, 30000, 40000]))
        let priors = biweeklyPeriods(count: 5, currentStart: current.start)
        let baseline = engine.usualPaceBaseline(currentPeriod: current, priorPeriods: priors, asOf: date(2026, 7, 8))
        #expect(baseline?.cents == 30000)
        #expect(baseline?.periodCount == 5)
    }

    @Test("one huge period cannot drag the baseline the way a mean would")
    func outlierDoesNotMoveTheMedian() {
        let priors = biweeklyPeriods(count: 5, currentStart: current.start)
        let calm = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: recordsAcrossPriorPeriods([40000, 30000, 20000, 30000, 40000]))
        let spiked = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: recordsAcrossPriorPeriods([500000, 30000, 20000, 30000, 40000]))
        let calmBaseline = calm.usualPaceBaseline(currentPeriod: current, priorPeriods: priors, asOf: date(2026, 7, 8))
        let spikedBaseline = spiked.usualPaceBaseline(currentPeriod: current, priorPeriods: priors, asOf: date(2026, 7, 8))
        #expect(calmBaseline?.cents == spikedBaseline?.cents)
    }

    @Test("a period with nothing logged is skipped, never counted as a $0 period")
    func emptyPeriodsAreSkippedNotZeroed() {
        // Only three of the five prior periods hold anything.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: recordsAcrossPriorPeriods([30000, 20000, 40000]))
        let priors = biweeklyPeriods(count: 5, currentStart: current.start)
        let baseline = engine.usualPaceBaseline(currentPeriod: current, priorPeriods: priors, asOf: date(2026, 7, 8))
        // Median of [200, 300, 400], NOT of [0, 0, 200, 300, 400].
        #expect(baseline?.cents == 30000)
        #expect(baseline?.periodCount == 3)
    }

    @Test("an even number of periods averages the middle two")
    func evenCountAveragesMiddlePair() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: recordsAcrossPriorPeriods([10000, 20000, 30000, 50000]))
        let priors = biweeklyPeriods(count: 4, currentStart: current.start)
        let baseline = engine.usualPaceBaseline(currentPeriod: current, priorPeriods: priors, asOf: date(2026, 7, 8))
        #expect(baseline?.cents == 25000)
    }

    @Test("baseline is nil when no prior period holds a single record")
    func nilWithoutAnyPriorHistory() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 7, cents: 10000)])
        let priors = biweeklyPeriods(count: 6, currentStart: current.start)
        #expect(engine.usualPaceBaseline(currentPeriod: current, priorPeriods: priors, asOf: date(2026, 7, 8)) == nil)
    }

    @Test("with exactly one prior period the comparison matches the old single-period math")
    func singlePriorPeriodMatchesLegacyPaceDelta() {
        let prior = PayPeriod(start: date(2026, 6, 22), end: date(2026, 7, 5))
        let records = [record(2026, 7, 6, cents: 10000), record(2026, 6, 22, cents: 4000)]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let comparison = engine.paceComparison(currentPeriod: current, priorPeriods: [prior], asOf: date(2026, 7, 6))
        let legacy = engine.paceDelta(currentPeriod: current, priorPeriod: prior, asOf: date(2026, 7, 6))
        #expect(comparison?.deltaCents == legacy)
        #expect(comparison?.periodCount == 1)
    }

    @Test("the comparison subtracts the baseline from what's in the period so far")
    func comparisonSubtractsBaseline() {
        var records = recordsAcrossPriorPeriods([30000, 30000, 30000])
        records.append(record(2026, 7, 7, cents: 12000))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let priors = biweeklyPeriods(count: 3, currentStart: current.start)
        let comparison = engine.paceComparison(currentPeriod: current, priorPeriods: priors, asOf: date(2026, 7, 8))
        #expect(comparison?.baselineCents == 30000)
        #expect(comparison?.deltaCents == -18000)
    }
}

@Suite("Tip-out resolution in totals")
struct TipOutResolutionTests {
    /// The corruption shiftFacts exists to absorb: a shift whose tip-out
    /// ended up on BOTH its cash and credit rows. Summing raw records
    /// subtracts it twice; resolving through shiftFacts subtracts it once.
    @Test("a shift with tip-out on both rows subtracts it once, not twice")
    func tipOutOnBothRowsSubtractsOnce() {
        let shift = UUID()
        let records = [
            record(2026, 7, 6, cents: 10000, kind: .cash, tipOutCents: 2000, shiftID: shift),
            record(2026, 7, 6, cents: 10000, kind: .credit, tipOutCents: 2000, shiftID: shift)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        // $200 gross minus ONE $20 tip-out.
        #expect(engine.periodToDateTotal(period: period, asOf: date(2026, 7, 6)) == 18000)
    }

    @Test("the pace baseline resolves tip-out the same way the chart does")
    func baselineMatchesChartBasis() {
        let shift = UUID()
        let records = [
            record(2026, 6, 22, cents: 10000, kind: .cash, tipOutCents: 2000, shiftID: shift),
            record(2026, 6, 22, cents: 10000, kind: .credit, tipOutCents: 2000, shiftID: shift)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let current = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let prior = PayPeriod(start: date(2026, 6, 22), end: date(2026, 7, 5))
        let baseline = engine.usualPaceBaseline(currentPeriod: current, priorPeriods: [prior], asOf: date(2026, 7, 6))
        let chartTotal = engine.nightlyTotals().first?.cents
        #expect(baseline?.cents == 18000)
        #expect(baseline?.cents == chartTotal)
    }
}

@Suite("Typical range (what you can count on)")
struct TypicalRangeTests {
    /// Twelve Tuesdays at a known spread, all inside the 180-day window.
    private func tuesdays(_ values: [Int]) -> [TipRecord] {
        values.enumerated().map { index, cents in
            record(2026, 7, 7 + index * 7, cents: cents)
        }
    }

    @Test("p25 and p75 round outward, and the range carries its own sample size")
    func rangeRoundsOutward() {
        let values = [10000, 11000, 12000, 13000, 14000, 15000, 16000, 17000]
        let range = StatsEngine.typicalRange(values)
        #expect(range.shiftCount == 8)
        #expect(range.lowCents <= 11750)
        #expect(range.highCents >= 15250)
        #expect(range.lowCents % 500 == 0)
        #expect(range.highCents % 500 == 0)
    }

    @Test("one monster night cannot widen the range — the whole point of using quartiles")
    func outlierDoesNotWidenTheRange() {
        let calm = [10000, 11000, 12000, 13000, 14000, 15000, 16000, 17000]
        let spiked = [10000, 11000, 12000, 13000, 14000, 15000, 16000, 90000]
        #expect(StatsEngine.typicalRange(calm).lowCents == StatsEngine.typicalRange(spiked).lowCents)
    }

    @Test("a weekday under eight shifts gets no range at all — a range has no honest thin form")
    func thinWeekdayIsAbsent() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: tuesdays([10000, 12000, 14000, 16000, 18000]))
        let facts = engine.typicalRanges(referenceDate: date(2026, 9, 10))
        #expect(facts?.byWeekday.contains { $0.weekday == 3 } != true)
    }

    @Test("a weekday with enough consistent shifts reports a range")
    func steadyWeekdayReportsRange() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: tuesdays([10000, 11000, 12000, 13000, 14000, 15000, 16000, 17000, 12500, 13500]))
        let facts = engine.typicalRanges(referenceDate: date(2026, 10, 1))
        let tuesday = facts?.byWeekday.first { $0.weekday == 3 }
        #expect(tuesday != nil)
        #expect(tuesday?.range.shiftCount == 10)
    }

    @Test("a two-clump weekday is WITHHELD, never averaged into a range containing no real shift")
    func bimodalWeekdayIsWithheld() {
        // Six ~$60 lunches and six ~$200 dinners, no shiftPeriod logged so
        // it cannot be split — the median sits where nothing ever landed.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: tuesdays([6000, 6100, 5900, 6050, 5950, 6000, 20000, 20100, 19900, 20050, 19950, 20000]))
        let facts = engine.typicalRanges(referenceDate: date(2026, 11, 1))
        #expect(facts?.mixedShapeWeekdays.contains(3) == true)
        #expect(facts?.byWeekday.contains { $0.weekday == 3 } != true)
        // Non-nil so the withholding survives, but nothing to draw.
        #expect(facts?.hasVisibleRanges == false)
    }

    @Test("a weekday that splits cleanly into lunch and dinner reports TWO ranges, never one")
    func splittableWeekdayReportsBothServices() {
        var records: [TipRecord] = []
        for index in 0..<8 {
            records.append(record(2026, 7, 7 + index * 7, cents: 6000 + index * 100, shiftPeriod: .lunch, shiftID: UUID()))
            records.append(record(2026, 7, 7 + index * 7, cents: 20000 + index * 100, shiftPeriod: .dinner, shiftID: UUID()))
        }
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let facts = engine.typicalRanges(referenceDate: date(2026, 10, 1))
        let tuesdayEntries = facts?.byWeekday.filter { $0.weekday == 3 } ?? []
        #expect(tuesdayEntries.count == 2)
        #expect(tuesdayEntries.contains { $0.shiftPeriod == .lunch })
        #expect(tuesdayEntries.contains { $0.shiftPeriod == .dinner })
    }

    @Test("the overall range needs at least two weekdays — otherwise it is one weekday wearing a general label")
    func overallNeedsSeveralWeekdays() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: tuesdays([10000, 11000, 12000, 13000, 14000, 15000, 16000, 17000]))
        #expect(engine.typicalRanges(referenceDate: date(2026, 10, 1))?.overall == nil)
    }

    @Test("nil when nothing clears the bar")
    func nilWithoutEnoughHistory() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 7, cents: 10000)])
        #expect(engine.typicalRanges(referenceDate: date(2026, 7, 20)) == nil)
    }
}

@Suite("Earning trend")
struct EarningTrendTests {
    /// Builds `weeks` weeks of history ending the day before `reference`,
    /// working the same three weekdays every week so the schedule is
    /// stable and only the LEVEL differs between halves.
    private func history(recentCents: Int, priorCents: Int, weeks: Int = 16, jitter: Int = 400) -> [TipRecord] {
        var records: [TipRecord] = []
        // Day 0 is 2026-07-07 (a Tuesday); +2 Thursday, +4 Saturday.
        for week in 0..<weeks {
            for offset in [0, 2, 4] {
                let isRecentHalf = week >= weeks / 2
                let base = isRecentHalf ? recentCents : priorCents
                let wobble = ((week + offset) % 3 - 1) * jitter
                records.append(record(2026, 7, 7 + week * 7 + offset, cents: base + wobble))
            }
        }
        return records
    }

    /// Chosen so the engine's own 56-day boundary lands EXACTLY on the
    /// fixture's half-way point: 2026-10-27 minus 56 days is 2026-09-01,
    /// the start of week 8, and minus 112 days is 2026-07-07, the first
    /// shift. Misaligning these by even a day leaks one recent-valued
    /// shift into the prior window and quietly manufactures variance.
    private var reference: Date { date(2026, 10, 27) }

    @Test("a clear, well-sampled rise in level is reported")
    func risingLevelReported() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: history(recentCents: 22000, priorCents: 14000))
        let trend = engine.earningTrend(referenceDate: reference)
        #expect(trend?.direction == .higher)
        #expect((trend?.deltaCents ?? 0) > 0)
        #expect((trend?.marginOfErrorCents ?? 0) > 0)
    }

    @Test("a flat level is silence, not a manufactured trend")
    func flatLevelIsSilent() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: history(recentCents: 15000, priorCents: 15000))
        #expect(engine.earningTrend(referenceDate: reference) == nil)
    }

    @Test("a tiny level change cannot clear the materiality gate")
    func immaterialChangeIsSilent() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: history(recentCents: 15050, priorCents: 15000))
        #expect(engine.earningTrend(referenceDate: reference) == nil)
    }

    @Test("silence when the prior window is not fully covered by logging history")
    func partialPriorWindowIsSilent() {
        // Only the recent half exists — adoption bias would otherwise read
        // as a rise from nothing.
        var records = history(recentCents: 22000, priorCents: 14000)
        let cutoff = date(2026, 9, 1)
        records = records.filter { $0.date >= cutoff }
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        #expect(engine.earningTrend(referenceDate: reference) == nil)
    }

    @Test("silence when too few shifts sit in a window")
    func thinWindowIsSilent() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: history(recentCents: 22000, priorCents: 14000, weeks: 4))
        #expect(engine.earningTrend(referenceDate: reference) == nil)
    }

    @Test("zero within-stratum spread does not produce a confident zero-width claim")
    func zeroVarianceIsSilent() {
        // Every shift in each half identical: the perfect-separation
        // sentinel would pass materiality while the standard error is zero,
        // so both gates would pass vacuously. Guarded explicitly.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: history(recentCents: 22000, priorCents: 14000, jitter: 0))
        #expect(engine.earningTrend(referenceDate: reference) == nil)
    }

    @Test("the schedule is reported separately from the level, never folded into it")
    func scheduleIsCarriedSeparately() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: history(recentCents: 22000, priorCents: 14000))
        let trend = engine.earningTrend(referenceDate: reference)
        // Same three weekdays every week, so the schedule held steady and
        // the per-shift level carries the entire finding.
        #expect(trend != nil)
        #expect(abs((trend?.recentShiftsPerWeek ?? 0) - (trend?.priorShiftsPerWeek ?? 0)) < 0.5)
        #expect(RevealCopy.trendScheduleLine(trend!) == nil)
    }

    @Test("the copy states an interval and never the word trending")
    func copyStatesAnInterval() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: history(recentCents: 22000, priorCents: 14000))
        let line = RevealCopy.trendLine(engine.earningTrend(referenceDate: reference)!)
        #expect(line.contains("somewhere between"))
        #expect(line.contains("higher"))
        #expect(line.lowercased().contains("trending") == false)
    }
}

@Suite("Forecast accuracy")
struct ForecastAccuracyTests {
    /// A steady three-shifts-a-week rhythm over `weeks` weeks, which is
    /// what planForward needs before it will project anything at all.
    private func steadyHistory(weeks: Int, cents: Int = 15000) -> [TipRecord] {
        var records: [TipRecord] = []
        for week in 0..<weeks {
            for offset in [0, 2, 4] {
                records.append(record(2026, 1, 6 + week * 7 + offset, cents: cents + (week % 3) * 200))
            }
        }
        return records
    }

    @Test("accuracy needs a real run of scored weeks behind it")
    func silentWithoutEnoughScoredWeeks() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: steadyHistory(weeks: 4))
        #expect(engine.forecastAccuracy(referenceDate: date(2026, 2, 3)) == nil)
    }

    @Test("a steady rhythm scores its weeks and reports a median error")
    func steadyRhythmScores() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: steadyHistory(weeks: 30))
        let accuracy = engine.forecastAccuracy(referenceDate: date(2026, 8, 1))
        #expect(accuracy != nil)
        #expect((accuracy?.scoredWeekCount ?? 0) >= 8)
        #expect((accuracy?.medianAbsoluteErrorCents ?? -1) >= 0)
    }

    @Test("price and schedule deltas sum EXACTLY to the total miss, despite integer division")
    func decompositionIsAnExactIdentity() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: steadyHistory(weeks: 30))
        let accuracy = engine.forecastAccuracy(referenceDate: date(2026, 8, 1))
        let week = accuracy?.lastWeek
        #expect(week != nil)
        #expect((week!.actualCents - week!.projectedCents) == week!.priceDeltaCents + week!.scheduleDeltaCents)
    }

    @Test("the copy frames the estimate against the week that happened, not a prediction")
    func copyAvoidsPredictionFraming() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: steadyHistory(weeks: 30))
        let line = RevealCopy.forecastAccuracyLine(engine.forecastAccuracy(referenceDate: date(2026, 8, 1))!)
        #expect(line.contains("the week you had"))
        #expect(line.lowercased().contains("predict") == false)
    }
}

@Suite("Pace copy")
struct PaceCopyTests {
    @Test("a single prior period still says 'last period' — there is no 'usual' yet")
    func singlePeriodKeepsLastPeriodWording() {
        #expect(RevealCopy.paceLine(deltaCents: -31240, periodCount: 1) == "$312.40 behind last period at this point.")
    }

    @Test("a thin multi-period baseline names its own sample size out loud")
    func thinBaselineDisclosesSampleSize() {
        #expect(RevealCopy.paceLine(deltaCents: -31240, periodCount: 3) == "$312.40 behind your usual pace (across three periods).")
    }

    @Test("a settled baseline drops the disclosure")
    func settledBaselineOmitsDisclosure() {
        #expect(RevealCopy.paceLine(deltaCents: 31240, periodCount: 6) == "$312.40 ahead of your usual pace.")
    }

    @Test("dead even reads as on pace, not as a $0.00 gap")
    func evenReadsAsOnPace() {
        #expect(RevealCopy.paceLine(deltaCents: 0, periodCount: 6) == "Right on your usual pace.")
    }
}

@Suite("Rate ($/hr)")
struct RateTests {
    @Test("dollars per hour for a specific night divides that night's total by its hours")
    func dollarsPerHourForNight() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 1, cents: 20000, hoursWorked: 5)])
        #expect(engine.dollarsPerHour(forNightAt: date(2026, 7, 1)) == 40)
    }

    @Test("dollars per hour is nil for a night with no hours logged")
    func dollarsPerHourNilWithoutHours() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 1, cents: 20000)])
        #expect(engine.dollarsPerHour(forNightAt: date(2026, 7, 1)) == nil)
    }

    @Test("average dollars per hour blends total dollars over total hours, not an average of nightly rates")
    func averageDollarsPerHourIsBlended() {
        // One 10-hour night at $10/hr, one 2-hour night at $50/hr. A naive
        // average of the two rates would say $30/hr; blended by totals it's
        // $200 over 12 hours = $16.67/hr.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
            record(2026, 7, 1, cents: 10000, hoursWorked: 10),
            record(2026, 7, 2, cents: 10000, hoursWorked: 2)
        ])
        let rate = engine.averageDollarsPerHour()
        #expect(rate != nil)
        #expect(abs(rate! - 16.666666) < 0.001)
    }

    @Test("average dollars per hour ignores nights with no hours logged")
    func averageDollarsPerHourIgnoresUnloggedNights() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
            record(2026, 7, 1, cents: 10000, hoursWorked: 5),
            record(2026, 7, 2, cents: 99999) // no hours — must not distort the rate
        ])
        #expect(engine.averageDollarsPerHour() == 20)
    }

    @Test("average dollars per hour is nil with no rate history at all")
    func averageDollarsPerHourNilWithoutHistory() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 1, cents: 10000)])
        #expect(engine.averageDollarsPerHour() == nil)
    }

    @Test("average dollars per hour for a weekday only blends that weekday's rate nights")
    func averageDollarsPerHourForWeekday() {
        // July 1 and July 8 2026 are both Wednesdays.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        // (8600 + 3200) / 100 / 5 = $23.60/hr, not nil.
        #expect(engine.dollarsPerHour(forNightAt: date(2026, 7, 1)) == 23.6)
    }

    @Test("hours set on BOTH entries (corruption) are never summed into double the real hours")
    func dollarsPerHourNeverSumsHours() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit, hoursWorked: 5),
            record(2026, 7, 1, cents: 3200, kind: .cash, hoursWorked: 5)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        // If this summed to 10 hours the rate would be $11.80/hr instead.
        #expect(engine.dollarsPerHour(forNightAt: date(2026, 7, 1)) == 23.6)
    }

    @Test("best dollars-per-hour weekday picks the highest-blended-rate weekday")
    func bestWeekdayPicksHighestRate() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
            record(2026, 7, 1, cents: 10000, kind: .credit, tipOutCents: 1500, salesCents: 50000)
        ])
        // 10000 gross / 50000 sales = 20%, ignoring the tip-out entirely.
        #expect(engine.tipPercent(forNightAt: date(2026, 7, 1)) == 20)
    }

    @Test("receipt total never replaces the pre-tip sales denominator")
    func receiptTotalIsNotSalesBasis() {
        let metrics = ShiftReceiptMetrics(totalAmountCents: 98_049)
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
            record(
                2026,
                8,
                23,
                cents: 12_136,
                kind: .credit,
                salesCents: 81_863,
                receiptMetrics: metrics
            )
        ])

        let percent = engine.tipPercent(forNightAt: date(2026, 8, 23))
        #expect(percent != nil)
        #expect(abs(percent! - (12_136.0 / 81_863.0 * 100)) < 0.001)
        #expect(abs(percent! - (12_136.0 / 98_049.0 * 100)) > 1)
    }

    @Test("Toast auto-grat counts as effective tip earnings without becoming sales")
    func gratuityCountsAsEffectiveTips() {
        let metrics = ShiftReceiptMetrics(
            earningsSchemaVersion: 2,
            gratuityFeesCents: 4_050,
            totalAmountCents: 98_049
        )
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
            record(
                2026,
                8,
                23,
                cents: 12_136,
                kind: .credit,
                tipOutCents: 2_243,
                salesCents: 81_863,
                receiptMetrics: metrics
            )
        ])

        #expect(engine.nightlyTotals().first?.cents == 13_943)
        let percent = engine.tipPercent(forNightAt: date(2026, 8, 23))
        #expect(percent != nil)
        #expect(abs(percent! - ((12_136.0 + 4_050.0) / 81_863.0 * 100)) < 0.001)
        #expect(abs(percent! - ((12_136.0 + 4_050.0) / 98_049.0 * 100)) > 1)
    }

    @Test("a discretionary 20% auto-grat and an optional extra tip combine")
    func autoGratAndExtraTipCombine() {
        let autoGratOnly = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
            record(
                2026,
                8,
                23,
                cents: 0,
                kind: .credit,
                salesCents: 40_000,
                receiptMetrics: ShiftReceiptMetrics(
                    earningsSchemaVersion: 2,
                    gratuityFeesCents: 8_000
                )
            )
        ])
        #expect(autoGratOnly.tipPercent(forNightAt: date(2026, 8, 23)) == 20)

        let withExtraTip = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
            record(
                2026,
                8,
                24,
                cents: 2_000,
                kind: .credit,
                salesCents: 40_000,
                receiptMetrics: ShiftReceiptMetrics(
                    earningsSchemaVersion: 2,
                    gratuityFeesCents: 8_000
                )
            )
        ])
        #expect(withExtraTip.tipPercent(forNightAt: date(2026, 8, 24)) == 25)
    }

    @Test("legacy combined receipt amounts do not double-count captured gratuity")
    func legacyGratuityRemainsNonAdditive() {
        let legacyMetrics = ShiftReceiptMetrics(
            earningsSchemaVersion: nil,
            gratuityFeesCents: 4_050
        )
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
            record(
                2026,
                8,
                23,
                cents: 16_186,
                kind: .credit,
                tipOutCents: 2_243,
                receiptMetrics: legacyMetrics
            )
        ])

        #expect(engine.nightlyTotals().first?.cents == 13_943)
    }

    @Test("tip percent is nil for a night with no sales logged")
    func tipPercentNilWithoutSales() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 1, cents: 10000)])
        #expect(engine.tipPercent(forNightAt: date(2026, 7, 1)) == nil)
    }

    @Test("average tip percent blends total gross tips over total sales")
    func averageTipPercentIsBlended() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        // (8600 + 3200) / 50000 * 100 = 23.6%, not nil.
        #expect(abs(engine.tipPercent(forNightAt: date(2026, 7, 1))! - 23.6) < 0.001)
    }

    @Test("sales set on BOTH entries (corruption) are never summed into double the real sales")
    func tipPercentNeverSumsSales() {
        let records = [
            record(2026, 7, 1, cents: 8600, kind: .credit, salesCents: 50000),
            record(2026, 7, 1, cents: 3200, kind: .cash, salesCents: 20000)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        // If this summed to $700 sales the percent would be ~16.9% instead.
        #expect(abs(engine.tipPercent(forNightAt: date(2026, 7, 1))! - 23.6) < 0.001)
    }

    @Test("average tip percent for a weekday only blends that weekday's sales nights")
    func averageTipPercentForWeekday() {
        // July 1 and July 8 2026 are both Wednesdays.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let rhythm = engine.workRhythm(referenceDate: date(2026, 7, 24))
        let workedWeekday = Calendar.current.component(.weekday, from: date(2026, 7, 3))
        #expect(rhythm.usualWeekdays.contains(workedWeekday))
    }

    @Test("a single one-off shift never counts as usual, no matter the frequency")
    func oneOffShiftIsNotUsual() {
        let records = [record(2026, 7, 3, cents: 5000)]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        // Only 2 genuine same-day-logged records - below the minimum of 3.
        #expect(engine.workRhythm(referenceDate: date(2026, 7, 5)).typicalLogHour == nil)
    }

    @Test("no history yet means no usual weekdays and no typical hour")
    func noHistoryYieldsEmptyRhythm() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [])
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 6, cents: 5000)])
        let rhythm = WorkRhythm(usualWeekdays: [Calendar.current.component(.weekday, from: date(2026, 7, 6))], typicalLogHour: nil)
        let projected = engine.projectedPeriodTotal(period: period, asOf: date(2026, 7, 19), rhythm: rhythm)
        #expect(projected == engine.periodToDateTotal(period: period, asOf: date(2026, 7, 19)))
    }

    @Test("projection is nil without any usual weekdays yet")
    func noRhythmProjectionIsNil() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [])
        let projected = engine.projectedPeriodTotal(period: period, asOf: date(2026, 7, 6), rhythm: WorkRhythm(usualWeekdays: [], typicalLogHour: nil))
        #expect(projected == nil)
    }
}

@Suite("Anomalies")
struct AnomalyTests {
    @Test("first shift of a period has no prior entries in that period")
    func firstShift() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [])
        #expect(engine.isFirstShiftOfPeriod(date: date(2026, 7, 6), period: period))
    }

    @Test("not the first shift once an earlier entry exists in the period")
    func notFirstShift() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 6, cents: 5000)])
        #expect(!engine.isFirstShiftOfPeriod(date: date(2026, 7, 8), period: period))
    }

    @Test("slowest recently requires enough history before it can fire")
    func slowestNeedsHistory() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 1, cents: 1000)])
        #expect(!engine.isSlowestRecently(date: date(2026, 7, 2), cents: 500, lookbackShifts: 8))
    }

    @Test("slowest recently fires when tonight is at or below the recent floor")
    func slowestFires() {
        let records = (1...5).map { record(2026, 7, $0, cents: 5000 + $0 * 1000) }
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        #expect(engine.isSlowestRecently(date: date(2026, 7, 6), cents: 4000, lookbackShifts: 8))
    }

    @Test("slowest recently does not fire for an ordinary night")
    func slowestDoesNotFireForOrdinaryNight() {
        let records = (1...5).map { record(2026, 7, $0, cents: 5000 + $0 * 1000) }
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        #expect(!engine.isSlowestRecently(date: date(2026, 7, 6), cents: 50000, lookbackShifts: 8))
    }
}

@Suite("Reveal priority order")
struct RevealTests {
    @Test("no history at all reveals as the first logged night")
    func firstNightEver() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [])
        let result = engine.reveal(forNightAt: date(2026, 7, 6), cents: 5000, period: period)
        #expect(result.comparison == .firstNightLogged)
        #expect(!result.isRecord)
    }

    @Test("beating the all-time best is an all-time record, outranking a first-shift-of-period callout")
    func allTimeRecordOutranksFirstShift() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 6, 22, cents: 5000)])
        let result = engine.reveal(forNightAt: date(2026, 7, 6), cents: 9000, period: period)
        #expect(result.comparison == .allTimeRecord(previousBestCents: 5000))
        #expect(result.isRecord)
    }

    @Test("the second shift of a double day is compared against the first shift, not the whole day")
    func secondShiftComparesAgainstFirstShift() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        let lunchID = UUID()
        let dinnerID = UUID()
        // A $50 lunch closeout is already logged for July 6. The dinner
        // closeout is being revealed now (its id excluded, since it's the
        // shift just logged), so the lunch stays visible as prior history.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 6, cents: 5000, shiftID: lunchID)])
        let result = engine.reveal(forNightAt: date(2026, 7, 6), cents: 9000, period: period, shiftID: dinnerID)
        #expect(result.comparison == .allTimeRecord(previousBestCents: 5000))
        #expect(result.isRecord)

        // Without a shiftID the whole day is excluded (the legacy path), so
        // the lunch is hidden and there's nothing left to beat.
        let dayScoped = engine.reveal(forNightAt: date(2026, 7, 6), cents: 9000, period: period)
        #expect(dayScoped.comparison == .firstNightLogged)
    }

    @Test("first shift of a period outranks a weekday record when not also an all-time record")
    func firstShiftOutranksWeekdayRecord() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        // June 22 2026 is a Monday, same weekday as July 6 2026 — but June 22
        // logs a HIGHER amount, so July 6 can't be an all-time OR weekday record;
        // it should read as "first shift of the period" instead.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 6, 22, cents: 9000)])
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
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

    // The three reveal rate-clause tests are gone with the clause itself.
    // `RevealResult.rateClause` (`docs/METRICS.md` [LS-17]) was computed on
    // every log and never rendered — `RevealCardView` ignored it — and it was
    // `Double(cents)/100/hours` for tonight compared against a TIPS-ONLY
    // field of every other shift in the period, a basis mismatch inside one
    // unrendered sentence. PR 5 group 2.6 deleted the whole path rather than
    // migrating it. The live $/hr figure is now
    // `EarningsResult.hourlyRateCents`, pinned by
    // `InsightsSnapshotParityTests.theHourlyTileIsTheEnginesOwnRate`.
}

/// Tyler's ruling (2026-07-27): a shift speaks ONE number. These fixtures
/// are built so tips-basis and income-basis DISAGREE about the same
/// night — proving revealComparison actually switches basis when a wage
/// is set, rather than happening to agree by coincidence.
@Suite("Reveal wage basis")
struct RevealWageBasisTests {
    @Test("an all-time record on tips-only history is no longer a record once a wage lifts a prior night above it")
    func allTimeRecordFlipsWithWage() {
        let period = PayPeriod(start: date(2026, 7, 1), end: date(2026, 7, 31))
        // Tips-basis all-time best is 9000 (no hours). Income-basis
        // all-time best is 12000, once the $5/hr wage lands on the 10-hour
        // shift below.
        let records = [
            record(2026, 7, 1, cents: 9000),
            record(2026, 7, 2, cents: 7000, hoursWorked: 10)
        ]
        // Tips-only: tonight's 9500 beats the 9000 tips-basis best.
        let tipsOnly = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let tipsResult = tipsOnly.reveal(forNightAt: date(2026, 7, 3), cents: 9500, period: period)
        #expect(tipsResult.comparison == .allTimeRecord(previousBestCents: 9000))
        #expect(tipsResult.isRecord)

        // Income-aware, same records, same tonight: 9500 no longer beats
        // the 12000 income-basis best (7000 tips + $50 wage on 10 hours).
        let incomeAware = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records, wageCentsPerHour: 500)
        let incomeResult = incomeAware.reveal(forNightAt: date(2026, 7, 3), cents: 9500, period: period)
        #expect(incomeResult.comparison != .allTimeRecord(previousBestCents: 9000))
        #expect(!incomeResult.isRecord)
    }

    @Test("a weekday record on tips-only history disappears once a wage lifts a prior Monday above it")
    func weekdayRecordFlipsWithWage() {
        let period = PayPeriod(start: date(2026, 6, 1), end: date(2026, 7, 31))
        let monday = Calendar.current.component(.weekday, from: date(2026, 7, 6))
        let records = [
            record(2026, 7, 3, cents: 50000),                    // dominant all-time best (a Friday), blocks allTimeRecord in both bases
            record(2026, 6, 22, cents: 9000),                     // best Monday, tips-basis: 9000
            record(2026, 6, 29, cents: 7000, hoursWorked: 10)     // tips 7000, income 7000 + $50 wage = 12000
        ]
        let tipsOnly = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let tipsResult = tipsOnly.reveal(forNightAt: date(2026, 7, 6), cents: 9500, period: period)
        #expect(tipsResult.comparison == .weekdayRecord(weekday: monday, previousBestCents: 9000))
        #expect(tipsResult.isRecord)

        let incomeAware = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records, wageCentsPerHour: 500)
        let incomeResult = incomeAware.reveal(forNightAt: date(2026, 7, 6), cents: 9500, period: period)
        #expect(incomeResult.comparison != .weekdayRecord(weekday: monday, previousBestCents: 9000))
        #expect(!incomeResult.isRecord)
    }

    @Test("the weekday-average delta flips sign once a wage lifts a prior Monday's income above tonight")
    func weekdayAverageDeltaFlipsWithWage() {
        let period = PayPeriod(start: date(2026, 6, 1), end: date(2026, 7, 31))
        let records = [
            record(2026, 7, 3, cents: 50000),                    // dominant all-time best (a Friday)
            record(2026, 6, 22, cents: 6000),                     // Monday, no hours
            record(2026, 6, 29, cents: 4000, hoursWorked: 10)     // Monday, tips 4000, income 4000 + $50 wage = 9000
        ]
        // Tips-basis Monday average: (6000 + 4000) / 2 = 5000. Tonight's
        // 5500 sits $500 ABOVE it.
        let tipsOnly = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let tipsResult = tipsOnly.reveal(forNightAt: date(2026, 7, 6), cents: 5500, period: period)
        guard case .weekdayAverage(_, let tipsDelta, _, _, _) = tipsResult.comparison else {
            Issue.record("expected weekdayAverage case, got \(tipsResult.comparison)")
            return
        }
        #expect(tipsDelta == 500)

        // Income-basis Monday average: (6000 + 9000) / 2 = 7500. The SAME
        // tonight now sits $2000 BELOW it — the sign flips.
        let incomeAware = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records, wageCentsPerHour: 500)
        let incomeResult = incomeAware.reveal(forNightAt: date(2026, 7, 6), cents: 5500, period: period)
        guard case .weekdayAverage(_, let incomeDelta, _, _, _) = incomeResult.comparison else {
            Issue.record("expected weekdayAverage case, got \(incomeResult.comparison)")
            return
        }
        #expect(incomeDelta == -2000)
    }

    @Test("slowest-recently uses income basis: a low-tip, high-wage night raises the recent floor enough to flip the verdict")
    func slowestRecentlyFlipsWithWage() {
        let period = PayPeriod(start: date(2026, 7, 1), end: date(2026, 7, 31))
        // Tips-basis floor is 2000 (this shift's own tips); income-basis
        // lifts that same shift to 7000 with a $50 wage, so the
        // income-basis floor becomes 6000 instead.
        let records = [
            record(2026, 7, 1, cents: 2000, hoursWorked: 10),
            record(2026, 7, 2, cents: 6000),
            record(2026, 7, 3, cents: 6000),
            record(2026, 7, 4, cents: 6000)
        ]
        let tipsOnly = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let tipsResult = tipsOnly.reveal(forNightAt: date(2026, 7, 6), cents: 5000, period: period)
        #expect(tipsResult.comparison != .slowestRecently)

        let incomeAware = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records, wageCentsPerHour: 500)
        let incomeResult = incomeAware.reveal(forNightAt: date(2026, 7, 6), cents: 5000, period: period)
        #expect(incomeResult.comparison == .slowestRecently)
    }

    @Test("nil wage (the default) reproduces tips-only reveal behavior exactly")
    func nilWageMatchesTipsOnlyReveal() {
        let period = PayPeriod(start: date(2026, 7, 6), end: date(2026, 7, 19))
        // Same fixture and expectations as weekdayRecordFires above,
        // constructed with an explicit wageCentsPerHour: nil.
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [
            record(2026, 6, 26, cents: 20000),
            record(2026, 6, 22, cents: 3000),
            record(2026, 7, 8, cents: 4000)
        ], wageCentsPerHour: nil)
        let result = engine.reveal(forNightAt: date(2026, 7, 13), cents: 5000, period: period)
        #expect(result.comparison == .weekdayRecord(weekday: Calendar.current.component(.weekday, from: date(2026, 7, 13)), previousBestCents: 3000))
        #expect(result.isRecord)
    }

    @Test("pace and charts never read wageCentsPerHour — the boundary that doesn't move")
    func paceAndChartsIgnoreWage() {
        let records = [
            record(2026, 7, 1, cents: 5000, hoursWorked: 8),
            record(2026, 7, 2, cents: 7000, hoursWorked: 6),
            record(2026, 7, 3, cents: 6000)
        ]
        let tipsOnly = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let wageAware = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records, wageCentsPerHour: 500)

        #expect(tipsOnly.nightlyTotals().map(\.cents) == wageAware.nightlyTotals().map(\.cents))

        let current = PayPeriod(start: date(2026, 7, 1), end: date(2026, 7, 14))
        let prior = PayPeriod(start: date(2026, 6, 17), end: date(2026, 6, 30))
        #expect(
            tipsOnly.paceDelta(currentPeriod: current, priorPeriod: prior, asOf: date(2026, 7, 3))
            == wageAware.paceDelta(currentPeriod: current, priorPeriod: prior, asOf: date(2026, 7, 3))
        )
        #expect(
            tipsOnly.projectedPeriodTotal(period: current, asOf: date(2026, 7, 3), rhythm: tipsOnly.workRhythm(referenceDate: date(2026, 7, 3)))
            == wageAware.projectedPeriodTotal(period: current, asOf: date(2026, 7, 3), rhythm: wageAware.workRhythm(referenceDate: date(2026, 7, 3)))
        )
    }
}

@Suite("Reveal copy")
struct RevealCopyTests {
    @Test("headline formats the shift total, naming tips rather than the day")
    func headlineFormat() {
        #expect(RevealCopy.headline(cents: 18600, includesNonTipIncome: false) == "$186.00 in tips this shift.")
    }

    @Test("headline drops 'tips' when the total already includes wages — it's income, not tips")
    func headlineFormatWithWages() {
        #expect(RevealCopy.headline(cents: 20132, includesNonTipIncome: true) == "$201.32 this shift.")
    }

    @Test("all-time record copy names the previous best, falling back to 'shift' when the period is unknown")
    func allTimeRecordCopy() {
        let text = RevealCopy.comparison(for: .allTimeRecord(previousBestCents: 5000))
        #expect(text.contains("Best shift ever"))
        #expect(text.contains("$50.00"))
    }

    @Test("all-time record copy names lunch or dinner when the shift's period is known")
    func allTimeRecordCopyNamesKnownPeriod() {
        let lunch = RevealCopy.comparison(for: .allTimeRecord(previousBestCents: 5000), period: .lunch)
        #expect(lunch.contains("Best lunch ever"))
        let dinner = RevealCopy.comparison(for: .allTimeRecord(previousBestCents: 5000), period: .dinner)
        #expect(dinner.contains("Best dinner ever"))
    }

    @Test("quietest-recently copy names the shift's period when known, else falls back to 'shift'")
    func slowestRecentlyCopy() {
        #expect(RevealCopy.comparison(for: .slowestRecently) == "Your quietest shift in a while.")
        #expect(RevealCopy.comparison(for: .slowestRecently, period: .lunch) == "Your quietest lunch in a while.")
        #expect(RevealCopy.comparison(for: .slowestRecently, period: .dinner) == "Your quietest dinner in a while.")
    }

    @Test("first logged copy never says 'night'")
    func firstNightLoggedCopyNamesShift() {
        #expect(RevealCopy.comparison(for: .firstNightLogged) == "Your first logged shift. Nice start.")
        #expect(RevealCopy.comparison(for: .firstNightLogged, period: .lunch) == "Your first logged lunch. Nice start.")
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
        #expect(text.contains("Third-best shift this period."))
    }

    @Test("weekday average copy names lunch or dinner in the period rank clincher when known")
    func weekdayAverageRankNamesKnownPeriod() {
        let text = RevealCopy.comparison(for: .weekdayAverage(weekday: 2, deltaCents: 3400, periodRank: 1, periodNightCount: 5, sampleCount: 8), period: .dinner)
        #expect(text.contains("Best dinner this period."))
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
        #expect(text.contains("(across two Mondays)"))
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

    // Three deleted formatters, three deleted tests (`docs/METRICS.md`
    // [ID-28], [ID-29], [ID-30]):
    //
    // - `compactPaceLine` was a SECOND formatter for the pace delta. The
    //   widget caption it was written for ([WG-07]) uses
    //   `Money.directionalDeltaString` instead, so nothing called this and
    //   one figure had two spellings.
    // - `projectionLine` had no caller anywhere in the repo, app, widget or
    //   tests, and no `MetricID` — a future caller could have revived a
    //   period projection with no registry row and no completeness caption.
    // - `rateClause` formatted [LS-17]'s never-rendered value.
}

@Suite("Insights facts")
struct InsightsFactsTests {
    @Test("nil without enough shifts")
    func notEnoughShifts() {
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: [record(2026, 7, 1, cents: 1000)])
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 10)) == nil)
    }

    /// `totalCents`, `averagePerShiftCents` (`totalCents / count`, arithmetic
    /// in a facts struct) and `topDays` were deleted with the only two things
    /// that read them, `InsightsFactsCopy` and the narration prompt
    /// (`docs/METRICS.md` [ID-02] through [ID-04]). What the page actually
    /// renders from a whole-history money total is the CHART, which is
    /// `EarningsChartFacts` over the snapshot and carries its own
    /// completeness. The gate this test still guards is the one that
    /// survived: how many shifts the facts rest on.
    @Test("counts the shifts in the window and reports no split without one")
    func basicFacts() {
        let records = [
            record(2026, 7, 1, cents: 1000, kind: .cash),
            record(2026, 7, 2, cents: 2000, kind: .credit),
            record(2026, 7, 3, cents: 5000, kind: .cash),
            record(2026, 7, 4, cents: 3000, kind: .credit),
            record(2026, 7, 5, cents: 4000, kind: .cash)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        guard let facts = engine.insightsFacts(referenceDate: date(2026, 7, 10)) else {
            Issue.record("expected facts")
            return
        }
        #expect(facts.shiftCount == 5)
        #expect(facts.doublesSolo == nil)
    }

    @Test("only considers the recent window")
    func recentWindowOnly() {
        var records = (1...5).map { record(2026, 7, $0, cents: 1000) }
        records.append(record(2025, 1, 1, cents: 99999))
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 10))?.shiftCount == 5)
    }

    // The notes-pass-through test went with `InsightsFacts.notes`. Its only
    // two readers were `InsightsFactsCopy` and `InsightsService`'s prompt
    // ([ID-12] onward), and a shift note has never been rendered on a Payday
    // screen. Nothing sends a note off-device any more.

    @Test("a single hot night never crowns a best-paying weekday")
    func weekdayBestNeedsRealSample() {
        // Jun 29 + Jul 6/13/20 2026 are Mondays, Jul 7 is a Tuesday.
        // Four ordinary Mondays vs one spectacular Tuesday: with the >= 3
        // nights floor, Tuesday (n=1) may not win — and with only one
        // qualifying weekday there is no runner-up, so no claim at all.
        let records = [
            record(2026, 6, 29, cents: 9500, hoursWorked: 5),
            record(2026, 7, 6, cents: 10000, hoursWorked: 5),
            record(2026, 7, 13, cents: 11000, hoursWorked: 5),
            record(2026, 7, 20, cents: 10500, hoursWorked: 5),
            record(2026, 7, 7, cents: 25000, hoursWorked: 5)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let rate = engine.insightsFacts(referenceDate: date(2026, 7, 21))?.rate
        #expect(rate != nil)
        #expect(rate?.bestWeekday == nil)
    }

    @Test("doubles facts include the per-shift number that makes the comparison fair")
    func doublesPerShift() {
        let records = [
            // One double day: two shifts totaling $500.
            record(2026, 7, 1, cents: 20000, shiftID: lunchShift),
            record(2026, 7, 1, cents: 30000, shiftID: dinnerShift),
            // Two single-shift days at $200 each.
            record(2026, 7, 2, cents: 20000, shiftID: UUID()),
            record(2026, 7, 3, cents: 20000, shiftID: UUID()),
            record(2026, 7, 4, cents: 20000, shiftID: UUID())
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let doubles = engine.insightsFacts(referenceDate: date(2026, 7, 10))?.doublesSolo
        #expect(doubles?.doubleAverageCents == 50000)
        #expect(doubles?.doublePerShiftCents == 25000)
        #expect(doubles?.soloAverageCents == 20000)
    }

    @Test("doubles vs solo compares average per double against average per solo shift")
    func doublesSoloSplit() {
        let records = [
            // Two double days (two closeouts each): $100 and $140 total.
            record(2026, 7, 1, cents: 5000, shiftID: UUID()),
            record(2026, 7, 1, cents: 5000, shiftID: UUID()),
            record(2026, 7, 2, cents: 7000, shiftID: UUID()),
            record(2026, 7, 2, cents: 7000, shiftID: UUID()),
            // Three solo days.
            record(2026, 7, 3, cents: 3000),
            record(2026, 7, 4, cents: 5000),
            record(2026, 7, 5, cents: 4000)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let facts = engine.insightsFacts(referenceDate: date(2026, 7, 10))
        #expect(facts?.doublesSolo?.doubleAverageCents == 12000)
        #expect(facts?.doublesSolo?.doubleCount == 2)
        #expect(facts?.doublesSolo?.soloAverageCents == 4000)
        #expect(facts?.doublesSolo?.soloCount == 3)
    }

    @Test("doubles vs solo is nil when there are no doubles at all")
    func doublesSoloNilWithoutDoubles() {
        let records = (1...5).map { record(2026, 7, $0, cents: 1000) }
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        #expect(engine.insightsFacts(referenceDate: date(2026, 7, 10))?.doublesSolo == nil)
    }

    /// Retargeted, not deleted. `InsightsFacts.totalCents` and
    /// `.totalTipOutCents` went with `InsightsFactsCopy`'s "Overall Snapshot"
    /// and its tip-out clause (`docs/METRICS.md` [ID-02], [ID-03]), which were
    /// the only two readers. The BEHAVIOUR they pinned — every figure on this
    /// page is net of the tip-out, taken once per shift and never once per
    /// record — is a property of `cents(of:)`, so it is pinned on a figure
    /// the page actually renders: the day totals the chart, pace, rhythm and
    /// weekday Moves all read.
    @Test("day totals are net of tip-outs, counted once per shift")
    func dayTotalsAreNetOfTipOut() {
        let records = [
            record(2026, 7, 1, cents: 10000, tipOutCents: 1000),
            record(2026, 7, 2, cents: 10000, tipOutCents: 500),
            record(2026, 7, 3, cents: 10000),
            record(2026, 7, 4, cents: 10000),
            record(2026, 7, 5, cents: 10000)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        // 50000 gross - 1500 tipped out.
        #expect(engine.nightlyTotals().reduce(0) { $0 + $1.cents } == 48500)

        let untouched = StatsEngine(
            payrollTimeZone: PaydayTestZone.payroll,
            records: (1...5).map { record(2026, 7, $0, cents: 1000) }
        )
        #expect(untouched.nightlyTotals().reduce(0) { $0 + $1.cents } == 5000)
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
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
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let rate = engine.insightsFacts(referenceDate: date(2026, 7, 10))?.rate
        #expect(rate?.nightsWithHours == 3)
        // $200 over 9 hours.
        #expect(rate.map { abs($0.overallDollarsPerHour - (200.0 / 9)) < 0.001 } == true)
    }

    @Test("rate facts split lunch vs dinner and doubles vs solo only over rate nights")
    func rateFactsSplits() {
        let records = [
            // Day 1 is a double: two dinner closeouts, $100 over 9 hours total ($11.11/hr).
            record(2026, 7, 1, cents: 5000, recordedHour: 20, hoursWorked: 4.5, shiftID: UUID()),
            record(2026, 7, 1, cents: 5000, recordedHour: 20, hoursWorked: 4.5, shiftID: UUID()),
            record(2026, 7, 2, cents: 4000, recordedHour: 13, hoursWorked: 4),                  // lunch, solo: $10/hr
            record(2026, 7, 3, cents: 5000, recordedHour: 19, hoursWorked: 5),                  // dinner, solo: $10/hr
            record(2026, 7, 4, cents: 1000),
            record(2026, 7, 5, cents: 1000)
        ]
        let engine = StatsEngine(payrollTimeZone: PaydayTestZone.payroll, records: records)
        let rate = engine.insightsFacts(referenceDate: date(2026, 7, 10))?.rate
        #expect(rate?.doubleDollarsPerHour != nil)
        #expect(rate?.soloDollarsPerHour != nil)
        #expect(rate?.lunchDollarsPerHour == 10)
        #expect(rate.map { abs($0.dinnerDollarsPerHour! - (150.0 / 14)) < 0.001 } == true)
    }

}

// `InsightsFactsCopyTests` is gone with `InsightsFactsCopy` itself.
//
// PR 5 group 2.7, rows [ID-02] through [ID-11]. The type turned
// `InsightsFacts` into ten prose sections as "the fallback for hardware that
// can't run Foundation Models" — and it had no live caller: the page renders
// the deterministic tile grid, has never rendered a prose section since it
// stopped narrating, and the narration whose absence it covered for is
// deleted too. Every section restated a figure a tile already shows, each
// with its own division (`lunchCents / lunchShiftCount`, twice), so it was a
// second money formula for a figure that already had one. Deleting it now is
// cheaper than migrating it onto the snapshot only for PR 8 to delete it.
