import Testing
import Foundation
@testable import Payday

@Suite("Earnings chart adaptive axis")
struct EarningsChartAdaptiveAxisTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func domain(days: Int) -> ClosedRange<Date> {
        start...(calendar.date(byAdding: .day, value: days, to: start) ?? start)
    }

    @Test("weekday initials remain for short pay-period charts")
    func dayScale() {
        #expect(EarningsChartAxisGranularity.forDomain(domain(days: 14), calendar: calendar) == .day)
        #expect(EarningsChartAxisGranularity.forDomain(domain(days: 21), calendar: calendar) == .day)
    }

    @Test("longer histories step through weeks, months, then years")
    func longerScales() {
        #expect(EarningsChartAxisGranularity.forDomain(domain(days: 22), calendar: calendar) == .week)
        #expect(EarningsChartAxisGranularity.forDomain(domain(days: 120), calendar: calendar) == .week)
        #expect(EarningsChartAxisGranularity.forDomain(domain(days: 121), calendar: calendar) == .month)
        #expect(EarningsChartAxisGranularity.forDomain(domain(days: 730), calendar: calendar) == .month)
        #expect(EarningsChartAxisGranularity.forDomain(domain(days: 731), calendar: calendar) == .year)
    }

    @Test("weekly and monthly bars combine their daily values")
    func combinesBars() {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3))!
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday)!
        let september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let nights = [
            (date: monday, cents: 10_000),
            (date: tuesday, cents: 20_000),
            (date: nextMonday, cents: 40_000),
            (date: september, cents: 80_000)
        ]

        let weeks = EarningsChartAxisGranularity.week.aggregate(nights, calendar: calendar)
        #expect(weeks.map(\.cents) == [30_000, 40_000, 80_000])

        let months = EarningsChartAxisGranularity.month.aggregate(nights, calendar: calendar)
        #expect(months.map(\.cents) == [70_000, 80_000])
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
    private func baseFacts(cashWeekday: CashWeekdayFacts? = nil, lunchDinner: LunchDinnerFacts? = nil, doublesSolo: DoublesSoloFacts? = nil) -> InsightsFacts {
        var facts = InsightsFacts(totalCents: 100_000, shiftCount: 5, averagePerShiftCents: 20_000, topDays: [], lunchDinner: lunchDinner, doublesSolo: doublesSolo)
        facts.cashWeekday = cashWeekday
        return facts
    }

    private var receiptPerformance: ReceiptPerformanceFacts {
        ReceiptPerformanceFacts(
            guestShiftCount: 5,
            totalGuests: 42,
            averageSpendPerGuestCents: 2_950,
            grossTipsPerGuestCents: 600,
            netTipsPerGuestCents: 520,
            tableShiftCount: 5,
            totalTables: 21,
            estimatedTableShiftCount: 4,
            averageSpendPerTableCents: 5_900,
            netTipsPerTableCents: 1_040,
            averageGuestsPerTable: 2,
            averageCheckCents: 5_900,
            guestsPerHour: 1.7,
            tipOutPercentOfGrossTips: 13.3,
            topCategories: []
        )
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

    @Test("receipt performance shows pre-tax spend per guest and estimated tips per table")
    func receiptPerformanceRow() {
        var facts = baseFacts()
        facts.receiptPerformance = receiptPerformance

        let rows = InsightsNumbersGrid.rows(for: facts)

        #expect(rows.count == 1)
        #expect(rows[0].map(\.id) == ["spendPerGuest", "tipsPerTable"])
        #expect(rows[0][0].value == "$29.50")
        #expect(rows[0][0].context == "pre-tax sales · 5 shifts")
        #expect(rows[0][1].value == "$10.40")
        #expect(rows[0][1].context == "net tips · tables estimated on 4 of 5 shifts")
    }

    @Test("confirmed table metrics disclose a thin shift count")
    func confirmedTableMetricDisclosesThinSample() {
        var facts = baseFacts()
        var confirmed = receiptPerformance
        confirmed = ReceiptPerformanceFacts(
            guestShiftCount: confirmed.guestShiftCount,
            totalGuests: confirmed.totalGuests,
            averageSpendPerGuestCents: confirmed.averageSpendPerGuestCents,
            grossTipsPerGuestCents: confirmed.grossTipsPerGuestCents,
            netTipsPerGuestCents: confirmed.netTipsPerGuestCents,
            tableShiftCount: 5,
            totalTables: confirmed.totalTables,
            estimatedTableShiftCount: 0,
            averageSpendPerTableCents: confirmed.averageSpendPerTableCents,
            netTipsPerTableCents: confirmed.netTipsPerTableCents,
            averageGuestsPerTable: confirmed.averageGuestsPerTable,
            averageCheckCents: confirmed.averageCheckCents,
            guestsPerHour: confirmed.guestsPerHour,
            tipOutPercentOfGrossTips: confirmed.tipOutPercentOfGrossTips,
            topCategories: confirmed.topCategories
        )
        facts.receiptPerformance = confirmed

        let tableTile = InsightsNumbersGrid.rows(for: facts)[0][1]

        #expect(tableTile.context == "net tips · confirmed tables · 5 shifts")
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

    @Test("doubles and solo always land in the same row")
    func doublesSoloRow() {
        let facts = baseFacts(doublesSolo: DoublesSoloFacts(doubleAverageCents: 51_800, doubleCount: 2, soloAverageCents: 23_800, soloCount: 3, doublePerShiftCents: 25_900))

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.map(\.id) == ["doubles", "solo"])
        #expect(row[0].value == "$259/shift")
        #expect(row[0].context == "2 double days · early read")
        #expect(row[1].label == "SOLO")
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

    @Test("a metric already explained by a recommendation can be excluded without disturbing the remaining rows")
    func excludesRedundantMetric() {
        var facts = baseFacts()
        facts.rate = RateFacts(overallDollarsPerHour: 42, nightsWithHours: 12, bestWeekday: nil, bestWeekdayDollarsPerHour: nil, bestWeekdayNightCount: nil, lunchDollarsPerHour: nil, dinnerDollarsPerHour: nil, doubleDollarsPerHour: nil, soloDollarsPerHour: nil)
        facts.startTime = StartTimeFacts(bestStartHour: 16, bestDollarsPerHour: 48, bestShiftCount: 17, worstStartHour: 10, worstDollarsPerHour: 22, worstShiftCount: 6)

        let rows = InsightsNumbersGrid.rows(for: facts, excluding: ["startTimes"])

        #expect(rows.map { $0.map(\.id) } == [["hourly"]])
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
        facts.receiptPerformance = receiptPerformance

        let rows = InsightsNumbersGrid.rows(for: facts)
        #expect(rows.map { $0.map(\.id) } == [
            ["hourly", "tipPercent"],
            ["spendPerGuest", "tipsPerTable"],
            ["lunch", "dinner"],
            ["doubles", "solo"],
            ["cashNights"],
            ["startTimes"],
        ])
    }
}

@Suite("Insights presentation")
struct InsightsPresentationTests {
    @Test("supporting observations keep the comparison but omit the consistency clause")
    func compactSupportingMove() {
        let move = Move(
            id: "doublesVerdict",
            title: "Doubles, Hour For Hour",
            body: "Doubles average $38/hr against $42/hr solo across twenty solo shifts. That's held across eleven doubles and twenty solo shifts.",
            effectSize: 1.4,
            supportingShiftCount: 11
        )

        #expect(InsightsPresentation.compactBody(for: move) == "Doubles average $38/hr against $42/hr solo across twenty solo shifts.")
    }

    @Test("supporting observations preserve a thin-sample warning")
    func compactSupportingMoveKeepsHedge() {
        let move = Move(
            id: "startTimeLeader",
            title: "4 PM Starts Lead Per Hour",
            body: "Shifts starting around 4 PM average $48/hr against $22/hr around 10 AM. Only six 10 AM starts to compare against so far.",
            effectSize: 0.9,
            supportingShiftCount: 6
        )

        #expect(InsightsPresentation.compactBody(for: move).contains("Only six 10 AM starts"))
    }

    @Test("narration keeps data caveats and drops anything that reads as advice")
    func dataNoteFilter() {
        let sections = [
            InsightSection(title: "Shift Selection", body: "Prioritize shifts starting around 4 PM."),
            InsightSection(title: "Aug 23 Estimate", body: "Cash was not confirmed, so treat this shift as approximate."),
            InsightSection(title: "POS Outage", body: "Your own note says the outage interrupted the closeout.")
        ]

        #expect(InsightsPresentation.dataNotes(from: sections).map(\.title) == ["Aug 23 Estimate", "POS Outage"])
    }

    @Test("a start-time observation suppresses the duplicate start-time tile")
    func redundantMetricMapping() {
        let moves = [Move(id: "startTimeLeader", title: "", body: "", effectSize: 0, supportingShiftCount: 0)]
        #expect(InsightsPresentation.redundantMetricIDs(for: moves) == ["startTimes"])
    }
}
