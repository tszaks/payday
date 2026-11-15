import Foundation
import PaydayCore
import Testing
@testable import Payday

/// The Periods screen and period detail, through the same facts and views the
/// screens build. Synthetic values throughout; no real payroll figures.
private let zone = PaydayTestZone.payroll

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private let policies = CompensationPolicies(
    rates: [PayRatePolicy(
        id: PolicyMigration.deterministicID("periodsscreen/rate"),
        effectiveFrom: .distantPast, hourlyRateCents: 1_000, provenance: .confirmed)],
    calendars: [PayrollCalendarPolicy(
        id: PolicyMigration.deterministicID("periodsscreen/calendar"),
        effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: zone)]
)

/// Biweekly, ending Sunday Oct 11 2026, paid five days later.
private let schedule = PaySchedule(
    frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0), payDelayDays: 5, firstWeekday: nil)

@Suite("Periods: the year-to-date headline stops at today")
@MainActor
struct PeriodsYearToDateTests {
    private func facts(_ records: [ShiftRecord], now: Date) -> PeriodsPageFacts {
        let snapshot = HistoryEarnings.build(records: records, policies: policies, payrollTimeZone: zone).snapshot
        return PeriodsPageFacts(
            snapshot: snapshot, paycheckRecords: [], schedule: schedule, payrollTimeZone: zone, now: now)
    }

    @Test("a shift logged ahead for tomorrow is not in the figure; today's shift is")
    func futureShiftIsNotCounted() throws {
        let today = ShiftRecord(workDate: at(2026, 10, 6), creditTipsCents: 10_000, hoursWorked: 5,
                                recordedAt: at(2026, 10, 6))
        let tomorrow = ShiftRecord(workDate: at(2026, 10, 7), creditTipsCents: 20_000, hoursWorked: 6,
                                   recordedAt: at(2026, 10, 6))
        let now = at(2026, 10, 6)

        let both = facts([today, tomorrow], now: now)
        let todayOnly = facts([today], now: now)

        let cents = try #require(both.yearToDate.cents)
        #expect(cents == todayOnly.yearToDate.cents)
        #expect(cents > 0)
        #expect(both.yearToDateShiftCountText == CompletenessCopy.shiftCount(1))
        #expect(both.hasYearToDate)
    }

    /// The cutoff is the day the person sees as today on the phone. At 1 AM
    /// in New York it is still the evening before in Los Angeles, the payroll
    /// zone, but a shift the person logged for today is in the figure.
    @Test("to date means the phone's today, not that instant read in the payroll zone")
    func cutoffIsThePhonesToday() throws {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        var phone = Calendar(identifier: .gregorian)
        phone.timeZone = PaydayTestZone.newYork
        func midnight(_ day: Int, in zone: TimeZone) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: DateComponents(year: 2026, month: 10, day: day))!
        }
        let policies = CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("periodsscreen/phonetoday/rate"),
                effectiveFrom: .distantPast, hourlyRateCents: 1_000, provenance: .confirmed)],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("periodsscreen/phonetoday/calendar"),
                effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: losAngeles)]
        )
        let today = ShiftRecord(workDate: midnight(6, in: losAngeles), creditTipsCents: 10_000, hoursWorked: 5)
        let tomorrow = ShiftRecord(workDate: midnight(7, in: losAngeles), creditTipsCents: 20_000, hoursWorked: 6)
        let now = phone.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 1))!
        func facts(_ records: [ShiftRecord]) -> PeriodsPageFacts {
            let snapshot = HistoryEarnings.build(records: records, policies: policies, payrollTimeZone: losAngeles).snapshot
            return PeriodsPageFacts(
                snapshot: snapshot, paycheckRecords: [],
                schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: midnight(11, in: losAngeles), payDelayDays: 5, firstWeekday: nil),
                payrollTimeZone: losAngeles, now: now, calendar: phone)
        }

        let both = facts([today, tomorrow])
        let cents = try #require(both.yearToDate.cents)
        #expect(cents > 0)
        #expect(cents == facts([today]).yearToDate.cents)
        #expect(both.yearToDateShiftCountText == CompletenessCopy.shiftCount(1))
    }
}

@Suite("Period detail: the check comparison names what was logged")
@MainActor
struct PeriodCheckCaptionTests {
    private let period = PayPeriod(start: at(2026, 9, 28, hour: 0), end: at(2026, 10, 11, hour: 0))

    /// $300 of card tips and $20 of gratuity, against a stub that paid $20.
    private func caption(creditTipsCents: Int, cardTipsOnCheck: Bool) throws -> String {
        let record = ShiftRecord(
            workDate: at(2026, 10, 5), creditTipsCents: creditTipsCents, hoursWorked: 5,
            receiptMetrics: ShiftReceiptMetrics(earningsSchemaVersion: 2, gratuityFeesCents: 2_000),
            recordedAt: at(2026, 10, 5))
        let snapshot = HistoryEarnings.build(records: [record], policies: policies, payrollTimeZone: zone).snapshot
        let result = HistoryEarnings.earnings(snapshot, for: period, in: zone)
        let paycheck = PaycheckRecord(periodStart: period.start, periodEnd: period.end, paidTipsCents: 2_000)
        let checked = try #require(PeriodCheckComparison(
            result: result, paycheck: paycheck, cardTipsOnCheck: cardTipsOnCheck))
        return PaycheckComparisonView(checked: checked, paycheck: paycheck).comparisonCaption
    }

    @Test("card tips on the check: the logged figure is card tips and gratuity")
    func cardTipsOnCheck() throws {
        #expect(try caption(creditTipsCents: 30_000, cardTipsOnCheck: true)
            == "Logged \(Money.string(fromCents: 32_000)) in card tips and gratuity · check paid \(Money.string(fromCents: 2_000))")
    }

    @Test("card tips paid at close: the logged figure is gratuity only, and says so")
    func cardTipsPaidAtClose() throws {
        #expect(try caption(creditTipsCents: 30_000, cardTipsOnCheck: false)
            == "Logged \(Money.string(fromCents: 2_000)) in gratuity · check paid \(Money.string(fromCents: 2_000))")
    }

    @Test("no card tips logged: the caption names no line, under either setting")
    func noCardTips() throws {
        let expected = "Logged \(Money.string(fromCents: 2_000)) · check paid \(Money.string(fromCents: 2_000))"
        #expect(try caption(creditTipsCents: 0, cardTipsOnCheck: true) == expected)
        #expect(try caption(creditTipsCents: 0, cardTipsOnCheck: false) == expected)
    }
}
