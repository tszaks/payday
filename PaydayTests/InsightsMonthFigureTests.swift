import Testing
import Foundation
@testable import Payday

/// THIS MONTH, the top of Insights: one number, and it is the chart's bar
/// for the same month on the same basis. Made-up round numbers throughout.
private func monthCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    return calendar
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    monthCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

/// One $8/hr rate, Sunday workweek.
private func policies() -> CompensationPolicies {
    CompensationPolicies(
        rates: [
            PayRatePolicy(id: PolicyMigration.deterministicID("month/all"), effectiveFrom: .distantPast,
                          hourlyRateCents: 800, provenance: .confirmed),
        ],
        calendars: [PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("month/calendar"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: 1,
            payrollTimeZone: PaydayTestZone.payroll
        )]
    )
}

/// A shift every third day from June 1 to November 6, 2026: more than 120
/// days, so the whole-history chart draws one bar per month. `hours` nil is
/// the tips-only person (no hours, so no wage can be priced).
private func history(hours: Double?) -> [ShiftRecord] {
    var records: [ShiftRecord] = []
    var date = day(2026, 6, 1)
    var index = 0
    while date <= day(2026, 11, 6) {
        records.append(ShiftRecord(workDate: date, cashTipsCents: 10_000 + (index % 5) * 1_000, hoursWorked: hours))
        date = monthCalendar().date(byAdding: .day, value: 3, to: date)!
        index += 1
    }
    return records
}

@Suite("Insights THIS MONTH")
@MainActor
struct InsightsMonthFigureTests {
    private func check(hours: Double?, expectWageInclusive: Bool) throws {
        let zone = PaydayTestZone.payroll
        let dataset = InsightsEarnings.build(records: history(hours: hours), policies: policies(), payrollTimeZone: zone)
        let snapshot = try #require(dataset.snapshot)
        let basis = InsightsEarnings.basis(for: snapshot)
        #expect(basis.isWageInclusive == expectWageInclusive)

        let chart = EarningsChartFacts(wholeOf: snapshot, timeZone: zone, metric: basis.chartMetric)
        #expect(chart.granularity == .month)
        let month = try #require(InsightsMonthFigure(
            snapshot: snapshot,
            today: CivilDay(year: 2026, month: 11, day: 8),
            timeZone: zone,
            metric: basis.chartMetric
        ))
        #expect(month.month == YearMonth(year: 2026, month: 11))
        #expect(month.label == "November so far")
        let bar = try #require(chart.points.first { YearMonth($0.range.start) == month.month })
        #expect(month.figure.cents == bar.cents)
        #expect((month.figure.cents ?? 0) > 0)
    }

    @Test("the month number equals the chart's bar for that month, wage-inclusive")
    func equalsChartBarWageInclusive() throws {
        try check(hours: 5, expectWageInclusive: true)
    }

    @Test("the month number equals the chart's bar for that month, tips only")
    func equalsChartBarTipsOnly() throws {
        try check(hours: nil, expectWageInclusive: false)
    }

    private func snapshotAndMetric(_ records: [ShiftRecord]) throws -> (EarningsSnapshot, EarningsChartMetric) {
        let dataset = InsightsEarnings.build(records: records, policies: policies(), payrollTimeZone: PaydayTestZone.payroll)
        let snapshot = try #require(dataset.snapshot)
        return (snapshot, InsightsEarnings.basis(for: snapshot).chartMetric)
    }

    @Test("with nothing logged yet this month it shows last month, by name")
    func fallsBackToLastMonth() throws {
        let zone = PaydayTestZone.payroll
        let (snapshot, metric) = try snapshotAndMetric(history(hours: nil))
        let month = try #require(InsightsMonthFigure(
            snapshot: snapshot,
            today: CivilDay(year: 2026, month: 12, day: 2),
            timeZone: zone,
            metric: metric
        ))
        #expect(month.month == YearMonth(year: 2026, month: 11))
        #expect(month.label == "November")
        #expect(month.figure.cents == metric.figure(snapshot.range(YearMonth(year: 2026, month: 11).range)).cents)
    }

    // Devin on #172: with last month empty too, the fallback led the page
    // with $0. The month shown is the latest one worked, with its year when
    // it is not this year's.
    @Test("after a break of several months it shows the last month worked, never $0")
    func skipsEmptyMonthsToTheLastWorked() throws {
        let zone = PaydayTestZone.payroll
        let (snapshot, metric) = try snapshotAndMetric(history(hours: nil))
        let month = try #require(InsightsMonthFigure(
            snapshot: snapshot,
            today: CivilDay(year: 2027, month: 2, day: 10),
            timeZone: zone,
            metric: metric
        ))
        #expect(month.month == YearMonth(year: 2026, month: 11))
        #expect(month.label == "November 2026")
        #expect((month.figure.cents ?? 0) > 0)
    }

    // Devin on #172: a shift saved ahead for a later day this month counted
    // under "so far". The open month is clamped to today.
    @Test("so far stops at today: a shift logged ahead does not count yet")
    func soFarStopsAtToday() throws {
        let zone = PaydayTestZone.payroll
        var records = history(hours: nil)
        records.append(ShiftRecord(workDate: day(2026, 11, 20), cashTipsCents: 50_000, hoursWorked: nil))
        let (snapshot, metric) = try snapshotAndMetric(records)
        let today = CivilDay(year: 2026, month: 11, day: 8)
        let month = try #require(InsightsMonthFigure(snapshot: snapshot, today: today, timeZone: zone, metric: metric))
        #expect(month.label == "November so far")
        let november = YearMonth(year: 2026, month: 11).range
        #expect(month.figure.cents == metric.figure(snapshot.range(november, asOf: today)).cents)
        let wholeMonth = metric.figure(snapshot.range(november)).cents ?? 0
        #expect((month.figure.cents ?? 0) == wholeMonth - 50_000)
    }

    @Test("nil when no shift is on or before today")
    func nilBeforeAnyShift() throws {
        let (snapshot, metric) = try snapshotAndMetric(history(hours: nil))
        #expect(InsightsMonthFigure(
            snapshot: snapshot,
            today: CivilDay(year: 2026, month: 5, day: 1),
            timeZone: PaydayTestZone.payroll,
            metric: metric
        ) == nil)
    }
}

@Suite("Insights NEXT WEEK headline")
struct PlanForwardCopyTests {
    /// The amount only: the NEXT WEEK kicker already names the week.
    @Test("the headline is the amount alone")
    func amountOnly() {
        let plan = PlanForward(nights: [], projectedTotalCents: 102_800, pickup: nil)
        #expect(PlanForwardCopy.headline(for: plan) == "About $1,028")
    }
}
