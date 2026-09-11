import Foundation
import Testing
@testable import Payday

@Suite("Render facts performance")
struct RenderFactsPerformanceTests {
    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("calendar reduces a 10,000-row history once within an interactive budget")
    func calendarFactsStayFastForLargeHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let historyStart = date(2000, 1, 1, calendar: calendar)
        let displayedMonth = date(2026, 7, 1, calendar: calendar)
        let entries = (0..<10_000).map { index in
            TipEntry(
                date: calendar.date(byAdding: .day, value: index, to: historyStart)!,
                amountCents: 100,
                recordedAt: historyStart
            )
        }

        let startedAt = Date.timeIntervalSinceReferenceDate
        let facts = CalendarMonthFacts(
            allEntries: entries,
            displayedMonth: displayedMonth,
            calendar: calendar,
            wageCentsPerHour: nil,
            firstWeekday: nil
        )
        let elapsed = Date.timeIntervalSinceReferenceDate - startedAt

        #expect(facts.daysWorkedCount == 31)
        #expect(facts.monthTotalCents == 3_100)
        #expect(facts.gridDays.count == 35)
        #expect(elapsed < 0.5, "Calendar render facts took \(elapsed) seconds")
    }

    @Test("chart aggregates 20,000 rows once within an interactive budget")
    func chartFactsStayFastForLargeHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = date(2026, 7, 1, calendar: calendar)
        let end = date(2026, 7, 14, calendar: calendar)
        let nights = (0..<20_000).map { index in
            (
                date: calendar.date(byAdding: .day, value: index % 14, to: start)!,
                cents: 100
            )
        }

        let startedAt = Date.timeIntervalSinceReferenceDate
        let facts = EarningsChartFacts(
            nights: nights,
            period: PayPeriod(start: start, end: end),
            calendar: calendar
        )
        let elapsed = Date.timeIntervalSinceReferenceDate - startedAt

        #expect(facts.points.count == 14)
        #expect(facts.points.reduce(0) { $0 + $1.cents } == 2_000_000)
        #expect(elapsed < 0.5, "Chart render facts took \(elapsed) seconds")
    }

    @Test("History partitions a 10,000-row data set within an interactive budget")
    func historyFactsStayFastForLargeHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let historyStart = date(2000, 1, 1, calendar: calendar)
        let now = date(2026, 7, 14, calendar: calendar)
        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: date(2026, 7, 19, calendar: calendar)
        )
        let entries = (0..<10_000).map { index in
            TipEntry(
                date: calendar.date(byAdding: .day, value: index, to: historyStart)!,
                amountCents: 100,
                recordedAt: historyStart
            )
        }
        let period = PayPeriod(
            start: date(2026, 7, 6, calendar: calendar),
            end: date(2026, 7, 19, calendar: calendar)
        )

        let listStartedAt = Date.timeIntervalSinceReferenceDate
        let listFacts = PeriodsPageFacts(
            allEntries: entries,
            paycheckRecords: [],
            schedule: schedule,
            wageCentsPerHour: nil,
            now: now,
            calendar: calendar
        )
        let listElapsed = Date.timeIntervalSinceReferenceDate - listStartedAt

        let detailStartedAt = Date.timeIntervalSinceReferenceDate
        let detailFacts = PeriodDetailFacts(
            allEntries: entries,
            paycheckRecords: [],
            period: period,
            schedule: schedule,
            wageCentsPerHour: nil,
            calendar: calendar
        )
        let detailElapsed = Date.timeIntervalSinceReferenceDate - detailStartedAt

        #expect(listFacts.rows.count == 24)
        #expect(listFacts.rows.first?.breakdown.netTotalCents == 1_400)
        #expect(detailFacts.shiftDays.count == 14)
        #expect(detailFacts.heroTotalCents == 1_400)
        #expect(listElapsed < 0.5, "History list facts took \(listElapsed) seconds")
        #expect(detailElapsed < 0.5, "Period detail facts took \(detailElapsed) seconds")
    }
}
