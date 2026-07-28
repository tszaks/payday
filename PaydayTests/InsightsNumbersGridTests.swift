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
    private func baseFacts(cashWeekday: CashWeekdayFacts? = nil, lunchDinner: LunchDinnerFacts? = nil, doublesSolo: DoublesSoloFacts? = nil) -> InsightsFacts {
        var facts = InsightsFacts(totalCents: 100_000, shiftCount: 5, averagePerShiftCents: 20_000, topDays: [], lunchDinner: lunchDinner, doublesSolo: doublesSolo)
        facts.cashWeekday = cashWeekday
        return facts
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

    @Test("hourly and tip percent drop their trailing shift count once the sample clears 8 shifts, keeping non-count context")
    func hourlyAndTipPercentLargeSample() {
        var facts = baseFacts()
        facts.rate = RateFacts(overallDollarsPerHour: 42, nightsWithHours: 160, bestWeekday: nil, bestWeekdayDollarsPerHour: nil, bestWeekdayNightCount: nil, lunchDollarsPerHour: nil, dinnerDollarsPerHour: nil, doubleDollarsPerHour: nil, soloDollarsPerHour: nil)
        facts.sales = SalesFacts(overallTipPercent: 16.7, nightsWithSales: 160, bestWeekday: nil, bestWeekdayTipPercent: nil, bestWeekdayNightCount: nil)

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        // HOURLY has no non-count context to fall back on - dropping the
        // count leaves it empty, same reasoning as the lunch/dinner tiles.
        #expect(rows[0][0].context == "")
        // TIP PERCENT keeps "of sales" - the non-count half of its caption.
        #expect(rows[0][1].context == "of sales")
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

    @Test("lunch and dinner drop their trailing shift count once the sample clears 8 shifts")
    func lunchDinnerLargeSample() {
        let facts = baseFacts(lunchDinner: LunchDinnerFacts(lunchCents: 318_000, lunchShiftCount: 20, dinnerCents: 1_675_000, dinnerShiftCount: 50))

        let rows = InsightsNumbersGrid.rows(for: facts)
        let row = rows[0]
        // The count was the only content in these captions - dropping it
        // leaves nothing else to say, and that's the point: repeating
        // "across 160 shifts" on every tile said nothing new.
        #expect(row[0].context == "")
        #expect(row[1].context == "")
    }

    @Test("doubles and solo always land in the same row, and solo reads ONE SHIFT")
    func doublesSoloRow() {
        let facts = baseFacts(doublesSolo: DoublesSoloFacts(doubleAverageCents: 51_800, doubleCount: 2, soloAverageCents: 23_800, soloCount: 3, doublePerShiftCents: 25_900))

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.map(\.id) == ["doubles", "solo"])
        #expect(row[0].value == "$259/shift")
        #expect(row[0].context == "2 double days · early read")
        #expect(row[1].label == "ONE SHIFT")
        #expect(row[1].value == "$238/shift")
        #expect(row[1].context == "3 days")
    }

    @Test("doubles and solo drop their trailing count once the sample clears 8")
    func doublesSoloLargeSample() {
        let facts = baseFacts(doublesSolo: DoublesSoloFacts(doubleAverageCents: 51_800, doubleCount: 10, soloAverageCents: 23_800, soloCount: 30, doublePerShiftCents: 25_900))

        let rows = InsightsNumbersGrid.rows(for: facts)
        let row = rows[0]
        #expect(row[0].context == "")
        #expect(row[1].context == "")
    }

    @Test("cash nights renders the weekday's blended share, weekday name, and count")
    func cashNights() {
        let facts = baseFacts(cashWeekday: CashWeekdayFacts(weekday: 6, sharePercent: 58, restSharePercent: 31, nightCount: 8))

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.id) == ["cashNights"])
        #expect(rows[0][0].label == "CASH NIGHTS")
        #expect(rows[0][0].value == "58%")
        #expect(rows[0][0].context == "of Friday tips are cash · 8 Fridays")
    }

    @Test("cash nights is omitted entirely when no weekday qualifies")
    func cashNightsOmittedWhenAbsent() {
        let facts = baseFacts()
        #expect(InsightsNumbersGrid.rows(for: facts).isEmpty)
    }

    @Test("start times shows the best window against the worst, counted and hedged when either side is thin")
    func startTimes() {
        var facts = baseFacts()
        facts.startTime = StartTimeFacts(bestStartHour: 11, bestDollarsPerHour: 17, bestShiftCount: 4, worstStartHour: 17, worstDollarsPerHour: 14, worstShiftCount: 2)

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        let tile = rows[0][0]
        #expect(tile.id == "startTimes")
        #expect(tile.value.contains("$17/hr"))
        // Computed the same way production's hourLabel does, so this stays
        // correct regardless of the test runner's locale/region.
        let worstHourLabel = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: .now)!.formatted(.dateTime.hour())
        // The thinner side (2 shifts) is the honesty signal and must survive
        // in the caption, on top of the existing early-read flag below 3.
        #expect(tile.context == "vs $14/hr at \(worstHourLabel) · 2 shifts · early read")
    }

    @Test("start times drops the trailing count once both sides clear 8 shifts")
    func startTimesLargeSample() {
        var facts = baseFacts()
        facts.startTime = StartTimeFacts(bestStartHour: 11, bestDollarsPerHour: 17, bestShiftCount: 40, worstStartHour: 17, worstDollarsPerHour: 14, worstShiftCount: 12)

        let rows = InsightsNumbersGrid.rows(for: facts)
        let tile = rows[0][0]
        let worstHourLabel = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: .now)!.formatted(.dateTime.hour())
        #expect(tile.context == "vs $14/hr at \(worstHourLabel)")
    }

    @Test("every populated fact produces its own row, in a stable order")
    func fullGridOrder() {
        var facts = baseFacts(
            cashWeekday: CashWeekdayFacts(weekday: 6, sharePercent: 58, restSharePercent: 31, nightCount: 8),
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
            ["cashNights"],
            ["startTimes"],
        ])
    }
}
