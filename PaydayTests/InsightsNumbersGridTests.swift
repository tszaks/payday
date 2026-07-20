import Testing
import Foundation
@testable import Payday

/// Insights' page-level replacement for the old content-dump prose — a
/// deterministic stat grid built straight off InsightsFacts. These tests
/// cover formatting, the sample-size hedge, and (most importantly) that
/// LUNCH/DINNER and DOUBLES/SOLO always land in the same row, since that's
/// the whole reason rows are computed explicitly rather than flowed from
/// one flat array (see InsightsNumbersGrid's own doc comment).
@Suite("Insights numbers grid")
struct InsightsNumbersGridTests {
    private func baseFacts(cashCents: Int = 0, creditCents: Int = 0, lunchDinner: LunchDinnerFacts? = nil, doublesSolo: DoublesSoloFacts? = nil) -> InsightsFacts {
        InsightsFacts(totalCents: 100_000, shiftCount: 5, averagePerShiftCents: 20_000, topDays: [], cashCents: cashCents, creditCents: creditCents, lunchDinner: lunchDinner, doublesSolo: doublesSolo)
    }

    @Test("empty facts produce no rows")
    func emptyFacts() {
        #expect(InsightsNumbersGrid.rows(for: baseFacts()).isEmpty)
    }

    @Test("hourly and tip percent share the same row, in order")
    func hourlyAndTipPercentRow() {
        var facts = baseFacts()
        facts.rate = RateFacts(overallDollarsPerHour: 42, nightsWithHours: 7, bestWeekday: nil, bestWeekdayDollarsPerHour: nil, bestWeekdayNightCount: nil, lunchDollarsPerHour: nil, dinnerDollarsPerHour: nil, doubleDollarsPerHour: nil, soloDollarsPerHour: nil)
        facts.sales = SalesFacts(overallTipPercent: 16.7, nightsWithSales: 5, bestWeekday: nil, bestWeekdayTipPercent: nil, bestWeekdayNightCount: nil)

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.id) == ["hourly", "tipPercent"])
        #expect(rows[0][0].value == "$42/hr")
        #expect(rows[0][0].context == "across 7 shifts")
        #expect(rows[0][1].value == "16.7%")
        #expect(rows[0][1].context == "of sales · 5 shifts")
    }

    @Test("hourly alone still renders, with no tip percent tile beside it")
    func hourlyAlone() {
        var facts = baseFacts()
        facts.rate = RateFacts(overallDollarsPerHour: 42, nightsWithHours: 7, bestWeekday: nil, bestWeekdayDollarsPerHour: nil, bestWeekdayNightCount: nil, lunchDollarsPerHour: nil, dinnerDollarsPerHour: nil, doubleDollarsPerHour: nil, soloDollarsPerHour: nil)

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.id) == ["hourly"])
    }

    @Test("lunch and dinner always land in the same row, per-shift averages")
    func lunchDinnerRow() {
        let facts = baseFacts(lunchDinner: LunchDinnerFacts(lunchCents: 31_800, lunchShiftCount: 2, dinnerCents: 167_500, dinnerShiftCount: 5))

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.map(\.id) == ["lunch", "dinner"])
        #expect(row[0].value == "$159/shift")
        #expect(row[0].context == "2 shifts · early read")
        #expect(row[1].value == "$335/shift")
        #expect(row[1].context == "5 shifts")
    }

    @Test("doubles and solo always land in the same row")
    func doublesSoloRow() {
        let facts = baseFacts(doublesSolo: DoublesSoloFacts(doubleAverageCents: 51_800, doubleCount: 2, soloAverageCents: 23_800, soloCount: 3, doublePerShiftCents: 25_900))

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.map(\.id) == ["doubles", "solo"])
        #expect(row[0].value == "$259/shift")
        #expect(row[0].context == "2 double days · early read")
        #expect(row[1].value == "$238/shift")
        #expect(row[1].context == "3 days")
    }

    @Test("cash share renders as a percent of gross, no early-read hedge")
    func cashShare() {
        let facts = baseFacts(cashCents: 4000, creditCents: 6000)

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.id) == ["cashShare"])
        #expect(rows[0][0].value == "40%")
        #expect(rows[0][0].context == "rest arrives on your paycheck")
    }

    @Test("cash share is omitted entirely when there's no cash or credit at all")
    func cashShareOmittedWhenNoGross() {
        let facts = baseFacts()
        #expect(InsightsNumbersGrid.rows(for: facts).isEmpty)
    }

    @Test("start times shows the best window against the worst, hedged when either side is thin")
    func startTimes() {
        var facts = baseFacts()
        facts.startTime = StartTimeFacts(bestStartHour: 11, bestDollarsPerHour: 17, bestShiftCount: 4, worstStartHour: 17, worstDollarsPerHour: 14, worstShiftCount: 2)

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        let tile = rows[0][0]
        #expect(tile.id == "startTimes")
        #expect(tile.value.contains("$17/hr"))
        #expect(tile.context.hasPrefix("vs $14/hr"))
        #expect(tile.context.hasSuffix("· early read"))
    }

    @Test("every populated fact produces its own row, in a stable order")
    func fullGridOrder() {
        var facts = baseFacts(
            cashCents: 4000, creditCents: 6000,
            lunchDinner: LunchDinnerFacts(lunchCents: 31_800, lunchShiftCount: 2, dinnerCents: 167_500, dinnerShiftCount: 5),
            doublesSolo: DoublesSoloFacts(doubleAverageCents: 51_800, doubleCount: 2, soloAverageCents: 23_800, soloCount: 3, doublePerShiftCents: 25_900)
        )
        facts.rate = RateFacts(overallDollarsPerHour: 42, nightsWithHours: 7, bestWeekday: nil, bestWeekdayDollarsPerHour: nil, bestWeekdayNightCount: nil, lunchDollarsPerHour: nil, dinnerDollarsPerHour: nil, doubleDollarsPerHour: nil, soloDollarsPerHour: nil)
        facts.sales = SalesFacts(overallTipPercent: 16.7, nightsWithSales: 5, bestWeekday: nil, bestWeekdayTipPercent: nil, bestWeekdayNightCount: nil)
        facts.startTime = StartTimeFacts(bestStartHour: 11, bestDollarsPerHour: 17, bestShiftCount: 4, worstStartHour: 17, worstDollarsPerHour: 14, worstShiftCount: 4)

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.map { $0.map(\.id) } == [
            ["hourly", "tipPercent"],
            ["lunch", "dinner"],
            ["doubles", "solo"],
            ["cashShare"],
            ["startTimes"],
        ])
    }
}
