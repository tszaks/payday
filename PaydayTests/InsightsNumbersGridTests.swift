import Testing
import Foundation
@testable import Payday

@Suite("Earnings chart adaptive axis")
struct EarningsChartAdaptiveAxisTests {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let start = CivilDay(year: 2023, month: 11, day: 14)

    /// A range holding exactly `days` civil days.
    ///
    /// PR 5 wave 0 moved the granularity choice from a `ClosedRange<Date>`
    /// to a `DayRange`, and a `DayRange`'s `count` is INCLUSIVE where
    /// `dateComponents([.day], from:to:)` was not. So the thresholds now
    /// mean what they say: at most 21 bars stay daily, and a 22-day range is
    /// the first weekly one. A real 14-day pay period is `.day` either way.
    private func range(days: Int) -> DayRange {
        DayRange(start: start, end: start.adding(days: days - 1))
    }

    @Test("weekday initials remain for short pay-period charts")
    func dayScale() {
        #expect(EarningsChartAxisGranularity.forRange(range(days: 14)) == .day)
        #expect(EarningsChartAxisGranularity.forRange(range(days: 21)) == .day)
    }

    @Test("longer histories step through weeks, months, then years")
    func longerScales() {
        #expect(EarningsChartAxisGranularity.forRange(range(days: 22)) == .week)
        #expect(EarningsChartAxisGranularity.forRange(range(days: 120)) == .week)
        #expect(EarningsChartAxisGranularity.forRange(range(days: 121)) == .month)
        #expect(EarningsChartAxisGranularity.forRange(range(days: 730)) == .month)
        #expect(EarningsChartAxisGranularity.forRange(range(days: 731)) == .year)
    }

    @Test("weekly and monthly buckets partition the range, covering every day exactly once")
    func bucketsPartitionTheRange() {
        // Mon 3 Aug 2026 through Wed 2 Sep 2026.
        let span = DayRange(
            start: CivilDay(year: 2026, month: 8, day: 3),
            end: CivilDay(year: 2026, month: 9, day: 2)
        )
        for granularity in [EarningsChartAxisGranularity.week, .month, .year] {
            let buckets = granularity.buckets(of: span, timeZone: zone)
            #expect(!buckets.isEmpty)
            // No gap and no overlap: the first bucket starts where the range
            // does, the last ends where it does, and each begins the day
            // after the previous one ended. This is what makes
            // `Σ bars == snapshot.range(span)` arithmetic instead of hope.
            #expect(buckets.first?.start == span.start)
            #expect(buckets.last?.end == span.end)
            #expect(buckets.reduce(0) { $0 + $1.count } == span.count)
            for (previous, next) in zip(buckets, buckets.dropFirst()) {
                #expect(previous.end.adding(days: 1) == next.start)
            }
        }
    }

    @Test("a daily chart makes one bucket per day, in order")
    func dailyBucketsAreOnePerDay() {
        let span = range(days: 14)
        let buckets = EarningsChartAxisGranularity.day.buckets(of: span, timeZone: zone)
        #expect(buckets.count == 14)
        #expect(buckets.allSatisfy { $0.count == 1 })
        #expect(buckets.map(\.start) == span.days)
    }

    @Test("weekly buckets break on the calendar week, so two days in one week are one bar")
    func weeklyBucketsCombineDaysOfTheSameWeek() {
        // Sun 2 Aug through Sat 15 Aug 2026: two whole Gregorian weeks
        // (Sunday-start, which is what the Gregorian calendar uses here).
        let span = DayRange(
            start: CivilDay(year: 2026, month: 8, day: 2),
            end: CivilDay(year: 2026, month: 8, day: 15)
        )
        let buckets = EarningsChartAxisGranularity.week.buckets(of: span, timeZone: zone)
        #expect(buckets.count == 2)
        #expect(buckets.map(\.count) == [7, 7])
    }
}

/// Insights' page-level replacement for the old content-dump prose — a
/// deterministic stat grid built straight off InsightsFacts. These tests
/// cover formatting, the sample-size hedge, and (most importantly) that
/// LUNCH/DINNER and DOUBLES/SOLO always land in the same row, since that's
/// the whole reason rows are computed explicitly rather than flowed from
/// one flat array (see InsightsNumbersGrid's own doc comment).
@Suite("Insights numbers grid")
struct InsightsNumbersGridTests {
    private func baseFacts(doublesSolo: DoublesSoloFacts? = nil) -> InsightsFacts {
        InsightsFacts(shiftCount: 5, doublesSolo: doublesSolo)
    }

    /// The PER HOUR tile's input, as `InsightsEarnings.hourlyRate(...)`
    /// returns it: the engine's own blended rate plus the coverage behind it.
    private func hourlyRate(cents: Int = 4_200, covered: Int = 7, total: Int = 7) -> InsightsEarnings.HourlyRate {
        InsightsEarnings.HourlyRate(rateCents: cents, coveredShiftCount: covered, totalShiftCount: total)
    }

    @Test("empty facts produce no rows")
    func emptyFacts() {
        #expect(InsightsNumbersGrid.rows(for: baseFacts(), hourly: nil).isEmpty)
    }

    @Test("per hour and tip percent share the same row, in order")
    func hourlyAndTipPercentRow() {
        var facts = baseFacts()
        facts.sales = SalesFacts(overallTipPercent: 16.7, nightsWithSales: 5, bestWeekday: nil, bestWeekdayTipPercent: nil, bestWeekdayNightCount: nil)

        let rows = InsightsNumbersGrid.rows(for: facts, hourly: hourlyRate())
        #expect(rows.count == 1)
        #expect(rows[0].map(\.id) == ["hourly", "tipPercent"])
        #expect(rows[0][0].label == "PER HOUR")
        #expect(rows[0][0].value == "$42/hr")
        #expect(rows[0][0].context == nil)
        #expect(rows[0][1].value == "16.7%")
        #expect(rows[0][1].context == "of sales")
    }

    /// Re-pinned 2026-11-08 (Insights for anyone who gets tips): a tile
    /// keeps a context line only when it names a basis different from the
    /// page's. Counts, coverage fractions and "early read" notes go, at any
    /// sample size (docs/DESIGN.md rule 13). TIP PERCENT keeps "of sales"
    /// because a wage is not a tip.
    @Test("no tile carries a count, at a thin or a large sample; tip percent keeps its basis")
    func noCountsOnAnyTile() {
        for (covered, total, nights) in [(141, 160, 160), (7, 7, 5), (2, 2, 2)] {
            var facts = baseFacts(doublesSolo: DoublesSoloFacts(doubleAverageCents: 51_800, doubleCount: 2, soloAverageCents: 23_800, soloCount: total, doublePerShiftCents: 25_900))
            facts.sales = SalesFacts(overallTipPercent: 16.7, nightsWithSales: nights, bestWeekday: nil, bestWeekdayTipPercent: nil, bestWeekdayNightCount: nil)
            let rows = InsightsNumbersGrid.rows(for: facts, hourly: hourlyRate(cents: 4_200, covered: covered, total: total))
            #expect(rows.flatMap { $0 }.compactMap(\.context) == ["of sales"])
        }
    }

    @Test("per hour alone still renders, with no tip percent tile beside it")
    func hourlyAlone() {
        let rows = InsightsNumbersGrid.rows(for: baseFacts(), hourly: hourlyRate())
        #expect(rows.count == 1)
        #expect(rows[0].map(\.id) == ["hourly"])
    }

    /// The tile is ABSENT when the engine cannot answer, never a fabricated
    /// `$0/hr`. `EarningsResult.hourlyRateCents` is nil without covered
    /// minutes, which is the registry's "nil without coverage".
    @Test("no per hour tile at all when the engine has no rate to give")
    func noHourlyTileWithoutAnEngineAnswer() {
        var facts = baseFacts()
        facts.sales = SalesFacts(overallTipPercent: 16.7, nightsWithSales: 5, bestWeekday: nil, bestWeekdayTipPercent: nil, bestWeekdayNightCount: nil)

        let rows = InsightsNumbersGrid.rows(for: facts, hourly: nil)
        #expect(rows.map { $0.map(\.id) } == [["tipPercent"]])
    }

    @Test("double day and solo day always land in the same row")
    func doublesSoloRow() {
        let facts = baseFacts(doublesSolo: DoublesSoloFacts(doubleAverageCents: 51_800, doubleCount: 2, soloAverageCents: 23_800, soloCount: 3, doublePerShiftCents: 25_900))

        let rows = InsightsNumbersGrid.rows(for: facts, hourly: nil)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.map(\.id) == ["doubles", "solo"])
        #expect(row[0].label == "DOUBLE DAY")
        #expect(row[0].value == "$259/shift")
        #expect(row[1].label == "SOLO DAY")
        #expect(row[1].value == "$238/shift")
    }

    /// The tips-only page (no sales, no hours): the doubles pair is the
    /// whole grid, and nothing is there to read as missing.
    @Test("a tips-only person gets the doubles pair and nothing else")
    func tipsOnlyGrid() {
        let facts = baseFacts(doublesSolo: DoublesSoloFacts(doubleAverageCents: 51_800, doubleCount: 10, soloAverageCents: 23_800, soloCount: 30, doublePerShiftCents: 25_900))
        let rows = InsightsNumbersGrid.rows(for: facts, hourly: nil)
        #expect(rows.map { $0.map(\.id) } == [["doubles", "solo"]])
    }
}
