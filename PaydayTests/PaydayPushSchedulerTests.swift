import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

@Suite("Payday push scheduling")
struct PaydayPushSchedulerTests {
    // Weekly close on Sunday Jul 19, paid the following Friday (5-day lag) —
    // same shape as PaydayMoment's own weekly-lag fixture.
    private func weeklyPaidFriday() -> PayPeriodCalculator {
        PayPeriodCalculator(
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 7, 19), payDelayDays: 5, firstWeekday: nil)
        )
    }

    private func creditEntry(cents: Int, on day: Date) -> TipEntry {
        TipEntry(date: day, amountCents: cents, kind: .credit)
    }

    private func cashEntry(cents: Int, on day: Date) -> TipEntry {
        TipEntry(date: day, amountCents: cents, kind: .cash)
    }

    @Test("fires at 9AM on the period's payday")
    func firesOnPayday() {
        let entries = [creditEntry(cents: 15000, on: date(2026, 7, 15))]
        let decision = PaydayPushScheduler.decision(
            now: date(2026, 7, 19, hour: 20),
            calculator: weeklyPaidFriday(),
            allEntries: entries,
            paycheckRecords: [],
            isReminderEnabled: true
        )
        #expect(decision?.fireDate == date(2026, 7, 24, hour: 9))
    }

    @Test("nothing once the fire moment has already passed")
    func nothingAfterPayday() {
        // No payroll lag: payday is the last day of the period itself, at
        // 9AM — by 2PM that same day the moment is behind, not ahead.
        let sameDay = PayPeriodCalculator(
            schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 7, 19), payDelayDays: 0, firstWeekday: nil)
        )
        let decision = PaydayPushScheduler.decision(
            now: date(2026, 7, 19, hour: 14),
            calculator: sameDay,
            allEntries: [],
            paycheckRecords: [],
            isReminderEnabled: true
        )
        #expect(decision == nil)
    }

    @Test("nothing once the period's paycheck is already recorded")
    func nothingWhenAlreadyVerified() {
        let record = PaycheckRecord(periodStart: date(2026, 7, 13), periodEnd: date(2026, 7, 19), paidTipsCents: 15000)
        let decision = PaydayPushScheduler.decision(
            now: date(2026, 7, 19, hour: 20),
            calculator: weeklyPaidFriday(),
            allEntries: [creditEntry(cents: 15000, on: date(2026, 7, 15))],
            paycheckRecords: [record],
            isReminderEnabled: true
        )
        #expect(decision == nil)
    }

    @Test("body carries the exact predicted dollars from logged credit tips")
    func bodyCarriesPredictedDollars() {
        let entries = [
            creditEntry(cents: 15000, on: date(2026, 7, 15)),
            cashEntry(cents: 4000, on: date(2026, 7, 16))
        ]
        let decision = PaydayPushScheduler.decision(
            now: date(2026, 7, 19, hour: 20),
            calculator: weeklyPaidFriday(),
            allEntries: entries,
            paycheckRecords: [],
            isReminderEnabled: true
        )
        #expect(decision?.body == "Your check's tips line should read about $150.00.")
    }

    @Test("falls back to the plain body when no credit tips were logged")
    func fallbackBodyWithNoCreditTips() {
        let entries = [cashEntry(cents: 4000, on: date(2026, 7, 16))]
        let decision = PaydayPushScheduler.decision(
            now: date(2026, 7, 19, hour: 20),
            calculator: weeklyPaidFriday(),
            allEntries: entries,
            paycheckRecords: [],
            isReminderEnabled: true
        )
        #expect(decision?.body == "Your check lands today. Open Payday to check the period.")
    }

    @Test("disabled preference means nothing, regardless of everything else")
    func disabledPreferenceSchedulesNothing() {
        let entries = [creditEntry(cents: 15000, on: date(2026, 7, 15))]
        let decision = PaydayPushScheduler.decision(
            now: date(2026, 7, 19, hour: 20),
            calculator: weeklyPaidFriday(),
            allEntries: entries,
            paycheckRecords: [],
            isReminderEnabled: false
        )
        #expect(decision == nil)
    }
}
