import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

@Suite("Period progress")
struct PeriodProgressTests {
    let calculator = PayPeriodCalculator(
        payrollTimeZone: PaydayTestZone.payroll,
        schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: date(2026, 7, 19))
    )

    @Test("first day of a 14-day period shows visible progress, never zero")
    func firstDay() {
        let period = calculator.period(containing: date(2026, 7, 6))
        let fraction = calculator.progress(through: date(2026, 7, 6), in: period)
        #expect(abs(fraction - 1.0 / 14.0) < 0.0001)
    }

    @Test("last day is exactly full")
    func lastDay() {
        let period = calculator.period(containing: date(2026, 7, 19))
        #expect(calculator.progress(through: date(2026, 7, 19), in: period) == 1)
    }

    @Test("midpoint is half")
    func midpoint() {
        let period = calculator.period(containing: date(2026, 7, 6))
        let fraction = calculator.progress(through: date(2026, 7, 12), in: period)
        #expect(abs(fraction - 7.0 / 14.0) < 0.0001)
    }

    @Test("dates outside the period clamp to 0...1")
    func clamps() {
        let period = calculator.period(containing: date(2026, 7, 6))
        #expect(calculator.progress(through: date(2026, 6, 1), in: period) == 0)
        #expect(calculator.progress(through: date(2026, 8, 1), in: period) == 1)
    }
}

@Suite("Payday moment timing")
struct PaydayMomentTests {
    // Weekly close on Sunday Jul 19, paid the following Friday (5-day lag).
    private func weeklyPaidFriday() -> PayPeriodCalculator {
        PayPeriodCalculator(
            payrollTimeZone: PaydayTestZone.payroll,
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 7, 19), payDelayDays: 5, firstWeekday: nil)
        )
    }

    @Test("does not show on the last work day of the period")
    func notOnLastDay() {
        // Sunday Jul 19 is the last shift day — still workable, so no card.
        let moment = PaydayMoment.moment(now: date(2026, 7, 19, hour: 20), calculator: weeklyPaidFriday())
        #expect(moment == nil)
    }

    @Test("shows the day after the period closes")
    func showsMonday() {
        let moment = PaydayMoment.moment(now: date(2026, 7, 20, hour: 9), calculator: weeklyPaidFriday())
        #expect(moment?.period.end == date(2026, 7, 19))
        #expect(moment?.phase == .periodClosed)
    }

    @Test("still shows two days after the close")
    func showsTuesday() {
        let moment = PaydayMoment.moment(now: date(2026, 7, 21, hour: 9), calculator: weeklyPaidFriday())
        #expect(moment?.period.end == date(2026, 7, 19))
        #expect(moment?.phase == .periodClosed)
    }

    @Test("clears after the linger window, before payday")
    func clearsWednesday() {
        // Paid Friday Jul 24, but the card is gone by Wednesday — it lingers a
        // day or two, it doesn't camp until the check lands.
        let moment = PaydayMoment.moment(now: date(2026, 7, 22, hour: 9), calculator: weeklyPaidFriday())
        #expect(moment == nil)
    }

    @Test("stays gone the day before payday")
    func clearsThursday() {
        let moment = PaydayMoment.moment(now: date(2026, 7, 23, hour: 9), calculator: weeklyPaidFriday())
        #expect(moment == nil)
    }

    @Test("comes back on payday itself, as the check-day moment")
    func returnsOnPayday() {
        // The whole point of the app: the money is here, verify it. This used to
        // be the one day the card was guaranteed to be gone.
        let moment = PaydayMoment.moment(now: date(2026, 7, 24, hour: 9), calculator: weeklyPaidFriday())
        #expect(moment?.period.end == date(2026, 7, 19))
        #expect(moment?.phase == .checkDay)
    }

    @Test("gone again the day after payday")
    func clearsSaturday() {
        let moment = PaydayMoment.moment(now: date(2026, 7, 25, hour: 9), calculator: weeklyPaidFriday())
        #expect(moment == nil)
    }

    @Test("dismissing the close summary keeps that card from returning")
    func dismissedClose() {
        let moment = PaydayMoment.moment(
            now: date(2026, 7, 20, hour: 9),
            calculator: weeklyPaidFriday(),
            dismissedClosedEnd: date(2026, 7, 19)
        )
        #expect(moment == nil)
    }

    @Test("dismissing the close summary does NOT cancel payday's card")
    func dismissedCloseStillPaysOut() {
        // Two independent decisions: closing Monday's summary says nothing about
        // whether you want the check prompt on Friday.
        let moment = PaydayMoment.moment(
            now: date(2026, 7, 24, hour: 9),
            calculator: weeklyPaidFriday(),
            dismissedClosedEnd: date(2026, 7, 19)
        )
        #expect(moment?.phase == .checkDay)
    }

    @Test("dismissing payday's card keeps it gone, and doesn't resurrect the close summary")
    func dismissedCheckDay() {
        let moment = PaydayMoment.moment(
            now: date(2026, 7, 24, hour: 9),
            calculator: weeklyPaidFriday(),
            dismissedCheckEnd: date(2026, 7, 19)
        )
        #expect(moment == nil)
    }

    @Test("with no payroll lag it shows on the last day itself, as check day")
    func noLagShowsLastDay() {
        let sameDay = PayPeriodCalculator(
            payrollTimeZone: PaydayTestZone.payroll,
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 7, 19), payDelayDays: 0, firstWeekday: nil)
        )
        // Close day and check day collapse onto one date; verifying the money
        // that just landed outranks announcing the close.
        let onLastDay = PaydayMoment.moment(now: date(2026, 7, 19, hour: 20), calculator: sameDay)
        #expect(onLastDay?.period.end == date(2026, 7, 19))
        #expect(onLastDay?.phase == .checkDay)
        // ...and it's gone the next day, since there's no gap to wait through.
        let nextDay = PaydayMoment.moment(now: date(2026, 7, 20, hour: 9), calculator: sameDay)
        #expect(nextDay == nil)
    }
}

/// The payday card when the phone is not in the payroll zone: payday is the
/// payroll zone's civil day, and "today" is the day it is where the phone is.
@Suite("Payday moment across two zones")
struct PaydayMomentTwoZoneTests {
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    /// (payroll, phone): payroll east of the phone, then west of it.
    private static let payrollZones = [PaydayTestZone.newYork, losAngeles]
    private static let phoneZones = [losAngeles, PaydayTestZone.tokyo]

    private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Weekly, last day Sunday Jul 19 in the payroll zone, paid Friday Jul 24 there.
    private func moment(payroll: TimeZone, phone: TimeZone, phoneDay day: Int, hour: Int) -> PaydayMoment.Moment? {
        var phoneCalendar = Calendar(identifier: .gregorian)
        phoneCalendar.timeZone = phone
        let calculator = PayPeriodCalculator(
            payrollTimeZone: payroll,
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: at(2026, 7, 19, in: payroll), payDelayDays: 5, firstWeekday: nil)
        )
        return PaydayMoment.moment(now: at(2026, 7, day, hour: hour, in: phone), calculator: calculator, calendar: phoneCalendar)
    }

    @Test("check day is the payroll payday on the phone's calendar, morning and night",
          arguments: zip(payrollZones, phoneZones))
    func checkDayIsThePayrollPayday(payroll: TimeZone, phone: TimeZone) {
        for hour in [1, 9, 23] {
            let onPayday = moment(payroll: payroll, phone: phone, phoneDay: 24, hour: hour)
            #expect(onPayday?.phase == .checkDay, "hour \(hour)")
            #expect(onPayday?.period.end == at(2026, 7, 19, in: payroll), "hour \(hour)")
            #expect(moment(payroll: payroll, phone: phone, phoneDay: 23, hour: hour)?.phase != .checkDay, "hour \(hour)")
            #expect(moment(payroll: payroll, phone: phone, phoneDay: 25, hour: hour)?.phase != .checkDay, "hour \(hour)")
        }
    }

    @Test("the close summary shows the two payroll days after the last shift",
          arguments: zip(payrollZones, phoneZones))
    func closeWindowIsPayrollDays(payroll: TimeZone, phone: TimeZone) {
        #expect(moment(payroll: payroll, phone: phone, phoneDay: 19, hour: 12) == nil)
        #expect(moment(payroll: payroll, phone: phone, phoneDay: 20, hour: 12)?.phase == .periodClosed)
        #expect(moment(payroll: payroll, phone: phone, phoneDay: 21, hour: 12)?.phase == .periodClosed)
        #expect(moment(payroll: payroll, phone: phone, phoneDay: 22, hour: 12) == nil)
    }
}

@Suite("Tonight line")
struct TonightLineTests {
    @Test("payday moment silences the line entirely")
    func paydaySilence() {
        let line = TonightLine.compose(tonightRevealText: "$100.00 today.", isPaydayMoment: true)
        #expect(line == nil)
    }

    @Test("logged today echoes the reveal verdict verbatim")
    func revealEcho() {
        let line = TonightLine.compose(tonightRevealText: "$118.00 today. $34.00 above your Tuesday average.", isPaydayMoment: false)
        #expect(line == "$118.00 today. $34.00 above your Tuesday average.")
    }

    @Test("nothing logged: no line — the app never recites your schedule")
    func nothingLoggedSilence() {
        let line = TonightLine.compose(tonightRevealText: nil, isPaydayMoment: false)
        #expect(line == nil)
    }
}
