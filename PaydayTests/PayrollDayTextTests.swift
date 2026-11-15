import Testing
import Foundation
import PaydayCore
@testable import Payday

/// A payroll day is a midnight in the payroll zone, and it is shown by
/// reading it in that zone. Tokyo is the payroll zone here because the test
/// phone is west of it: Tokyo's midnight on a named day is the evening
/// before on the phone's own calendar, which is exactly the fault a person
/// from New York sees in Los Angeles. Each case names the day it expects, so
/// none of them depends on the zone the simulator happens to be in.
private let tokyo = PaydayTestZone.tokyo
private let phone = TimeZone.current

private func payrollMidnight(_ year: Int, _ month: Int, _ day: Int, in zone: TimeZone = tokyo) -> Date {
    CivilDay(year: year, month: month, day: day).date(in: zone)
}

@Suite("Payroll days read in the zone they were made in")
@MainActor
struct PayrollDayTextTests {

    // MARK: Calendar tiles

    @Test("a tile's number is its payroll day")
    func tileNumber() {
        #expect(DayCell.dayNumber(payrollMidnight(2026, 7, 19), in: tokyo) == 19)
    }

    @Test("a tile's number in the phone's own zone is what the phone's calendar said")
    func tileNumberInPhoneZone() {
        let day = payrollMidnight(2026, 7, 19, in: phone)
        #expect(DayCell.dayNumber(day, in: phone) == Calendar.current.component(.day, from: day))
    }

    @Test("a tile's spoken date is its payroll day")
    func tileSpokenDate() {
        #expect(
            DayCell.label(
                day: payrollMidnight(2026, 7, 19), tile: nil,
                isCurrentMonth: true, isFuture: false, zone: tokyo)
                == "July 19, no shifts"
        )
        #expect(
            DayCell.label(
                day: payrollMidnight(2026, 7, 19), tile: nil,
                isCurrentMonth: true, isFuture: true, zone: tokyo)
                == "July 19, upcoming"
        )
    }

    @Test("a tile's spoken date in the phone's own zone is what the phone's calendar said")
    func tileSpokenDateInPhoneZone() {
        let day = payrollMidnight(2026, 7, 19, in: phone)
        #expect(
            DayCell.label(day: day, tile: nil, isCurrentMonth: true, isFuture: false, zone: phone)
                == "\(day.formatted(.dateTime.month(.wide).day())), no shifts"
        )
    }

    // MARK: Day sheet

    @Test("the day sheet's title is the tapped payroll day")
    func daySheetTitle() {
        #expect(DayDetailSheet.titleText(for: payrollMidnight(2026, 7, 19), in: tokyo) == "Sun, Jul 19")
    }

    @Test("the day sheet's title in the phone's own zone is what the phone's calendar said")
    func daySheetTitleInPhoneZone() {
        let day = payrollMidnight(2026, 7, 19, in: phone)
        #expect(
            DayDetailSheet.titleText(for: day, in: phone)
                == day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        )
    }

    @Test("the log sheet opens on the tapped payroll day, as the phone's calendar names it")
    func logSheetDefaultDate() {
        let tapped = payrollMidnight(2026, 7, 19)
        let opened = DayDetailSheet.defaultLogDate(for: tapped, in: tokyo)
        #expect(CivilDay(opened, in: phone) == CivilDay(year: 2026, month: 7, day: 19))
        #expect(opened == Calendar.current.startOfDay(for: opened))
    }

    @Test("the log sheet's default date in the phone's own zone is the date it was handed")
    func logSheetDefaultDateInPhoneZone() {
        let tapped = payrollMidnight(2026, 7, 19, in: phone)
        #expect(DayDetailSheet.defaultLogDate(for: tapped, in: phone) == tapped)
    }

    // MARK: Pay periods

    @Test("a period's range is its first and last payroll day")
    func periodRange() {
        let period = PayPeriod(start: payrollMidnight(2026, 7, 13), end: payrollMidnight(2026, 7, 19))
        #expect(period.rangeText(in: tokyo) == "Jul 13 – Jul 19")
    }

    @Test("a period's range in the phone's own zone is what the phone's calendar said")
    func periodRangeInPhoneZone() {
        let period = PayPeriod(start: payrollMidnight(2026, 7, 13, in: phone), end: payrollMidnight(2026, 7, 19, in: phone))
        let old = "\(period.start.formatted(.dateTime.month(.abbreviated).day())) – \(period.end.formatted(.dateTime.month(.abbreviated).day()))"
        #expect(period.rangeText(in: phone) == old)
    }

    @Test("an upcoming payday names its payroll day")
    func upcomingPayday() {
        #expect(
            PaydayCopy.payDateText(
                payDate: payrollMidnight(2026, 7, 29),
                relativeTo: payrollMidnight(2026, 7, 20), timeZone: tokyo)
                == "Payday · Wed, Jul 29"
        )
    }

    @Test("a paid payday names its payroll day")
    func paidPayday() {
        #expect(
            PaydayCopy.payDateText(
                payDate: payrollMidnight(2026, 7, 10),
                relativeTo: payrollMidnight(2026, 7, 20), timeZone: tokyo)
                == "Paid Jul 10"
        )
    }

    @Test("a payday today is still upcoming at 3 PM on the payroll day")
    func paydayTodayInPayrollZone() {
        let afternoon = payrollMidnight(2026, 7, 20).addingTimeInterval(15 * 3_600)
        #expect(
            PaydayCopy.payDateText(
                payDate: payrollMidnight(2026, 7, 20), relativeTo: afternoon, timeZone: tokyo)
                == "Payday · Mon, Jul 20"
        )
    }

    @Test("a period's title is its payroll range, with no year inside the current year")
    func periodTitleWithinYear() {
        let period = PayPeriod(start: payrollMidnight(2026, 7, 13), end: payrollMidnight(2026, 7, 19))
        #expect(
            PeriodDetailView.periodTitle(period: period, now: payrollMidnight(2026, 7, 20), in: tokyo)
                == "Jul 13 – Jul 19"
        )
    }

    @Test("a period's title carries the year when it ends in another year")
    func periodTitleAcrossYears() {
        let period = PayPeriod(start: payrollMidnight(2026, 12, 28), end: payrollMidnight(2027, 1, 3))
        #expect(
            PeriodDetailView.periodTitle(period: period, now: payrollMidnight(2026, 12, 30), in: tokyo)
                == "Dec 28 – Jan 3, 2027"
        )
    }

    @Test("a period's title compares both years in the payroll zone")
    func periodTitleYearsShareAZone() {
        // 00:30 on Jan 1 in Tokyo is still Dec 31 on a phone in New York.
        let now = payrollMidnight(2027, 1, 1).addingTimeInterval(1_800)
        let period = PayPeriod(start: payrollMidnight(2026, 12, 28), end: payrollMidnight(2027, 1, 1))
        #expect(PeriodDetailView.periodTitle(period: period, now: now, in: tokyo) == "Dec 28 – Jan 1")
    }

    @Test("a period's title in the phone's own zone is what the phone's calendar said")
    func periodTitleInPhoneZone() {
        let period = PayPeriod(start: payrollMidnight(2026, 12, 28, in: phone), end: payrollMidnight(2027, 1, 3, in: phone))
        let now = payrollMidnight(2026, 12, 30, in: phone)
        #expect(
            PeriodDetailView.periodTitle(period: period, now: now, in: phone)
                == "\(period.start.formatted(.dateTime.month(.abbreviated).day())) – \(period.end.formatted(.dateTime.month(.abbreviated).day().year()))"
        )
    }

    @Test("the expected-pay-day caption names the payroll day")
    func expectedPayDayCaption() {
        let facts = PeriodDetailFacts(
            snapshot: nil,
            shiftRecordDays: [],
            paycheckRecords: [],
            period: PayPeriod(start: payrollMidnight(2026, 7, 13), end: payrollMidnight(2026, 7, 19)),
            schedule: nil,
            payrollTimeZone: tokyo
        )
        #expect(facts.noPaycheckCaption == "Expected on Jul 19")
    }

    // MARK: Month comparison

    @Test("the month a comparison names is the payroll month")
    func monthComparisonName() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let policies = CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("payroll-day-text/rate"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 1_000,
                provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("payroll-day-text/calendar"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: tokyo
            )]
        )
        let records = [
            ShiftRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                        workDate: payrollMidnight(2026, 8, 10), shiftPeriod: .dinner,
                        creditTipsCents: 10_000, hoursWorked: 5),
            ShiftRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                        workDate: payrollMidnight(2026, 9, 5), shiftPeriod: .dinner,
                        creditTipsCents: 20_000, hoursWorked: 5),
        ]
        let facts = CalendarMonthFacts(
            snapshot: CalendarEarnings.snapshot(records: records, policies: policies, payrollTimeZone: tokyo),
            displayedMonth: payrollMidnight(2026, 9, 1),
            calendar: calendar,
            now: payrollMidnight(2026, 10, 5)
        )
        #expect(try #require(facts.monthDelta).windowLabel == "August")
    }

    // MARK: Chart readout

    @Test("a scrubbed bar names its payroll day, week, month and year")
    func chartReadout() {
        let day = payrollMidnight(2026, 7, 19)
        #expect(NightlyEarningsChart.selectionPeriodText(for: day, granularity: .day, in: tokyo) == "on Sun, Jul 19")
        #expect(NightlyEarningsChart.selectionPeriodText(for: day, granularity: .week, in: tokyo) == "for the week of Jul 19")
        #expect(NightlyEarningsChart.selectionPeriodText(
            for: payrollMidnight(2026, 8, 1), granularity: .month, in: tokyo) == "in August 2026")
        #expect(NightlyEarningsChart.selectionPeriodText(
            for: payrollMidnight(2027, 1, 1), granularity: .year, in: tokyo) == "in 2027")
    }

    @Test("a scrubbed bar in the phone's own zone is what the phone's calendar said")
    func chartReadoutInPhoneZone() {
        let day = payrollMidnight(2026, 7, 19, in: phone)
        #expect(
            NightlyEarningsChart.selectionPeriodText(for: day, granularity: .day, in: phone)
                == "on \(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
        )
        #expect(
            NightlyEarningsChart.selectionPeriodText(for: day, granularity: .month, in: phone)
                == "in \(day.formatted(.dateTime.month(.wide).year()))"
        )
    }

    // MARK: Settings

    @Test("a pending policy's effective day is spoken in the payroll zone")
    func effectiveDayLongDate() {
        #expect(
            PayrollSettingsSection.longDate(CivilDay(year: 2026, month: 10, day: 5), in: tokyo)
                == "Monday, October 5"
        )
    }
}
