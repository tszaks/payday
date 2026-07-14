import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Suite("Weekly")
struct WeeklyPayPeriodTests {
    let schedule = PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 1, 2)) // a Friday
    var calculator: PayPeriodCalculator { PayPeriodCalculator(schedule: schedule) }

    @Test("period containing the anchor payday ends on the anchor")
    func periodContainingAnchor() {
        let period = calculator.period(containing: date(2026, 1, 2))
        #expect(period.start == date(2025, 12, 27))
        #expect(period.end == date(2026, 1, 2))
    }

    @Test("period containing the day after anchor starts the next period")
    func periodAfterAnchor() {
        let period = calculator.period(containing: date(2026, 1, 3))
        #expect(period.start == date(2026, 1, 3))
        #expect(period.end == date(2026, 1, 9))
    }

    @Test("period containing a mid-period date resolves to the enclosing week")
    func periodMidWeek() {
        let period = calculator.period(containing: date(2026, 1, 6))
        #expect(period.start == date(2026, 1, 3))
        #expect(period.end == date(2026, 1, 9))
    }

    @Test("next payday after a date strictly after that date")
    func nextPeriodEndStrict() {
        #expect(calculator.nextPeriodEnd(after: date(2026, 1, 2)) == date(2026, 1, 9))
        #expect(calculator.nextPeriodEnd(after: date(2026, 1, 1)) == date(2026, 1, 2))
    }

    @Test("days remaining counts down to zero on payday")
    func daysRemaining() {
        #expect(calculator.daysRemaining(from: date(2026, 1, 3)) == 6)
        #expect(calculator.daysRemaining(from: date(2026, 1, 9)) == 0)
        #expect(calculator.daysRemaining(from: date(2026, 1, 2)) == 0)
    }
}

@Suite("Biweekly")
struct BiweeklyPayPeriodTests {
    let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: date(2026, 1, 2))
    var calculator: PayPeriodCalculator { PayPeriodCalculator(schedule: schedule) }

    @Test("14-day cadence forward")
    func forwardCadence() {
        let period = calculator.period(containing: date(2026, 1, 16))
        #expect(period.start == date(2026, 1, 3))
        #expect(period.end == date(2026, 1, 16))
    }

    @Test("14-day cadence backward before the anchor")
    func backwardCadence() {
        let period = calculator.period(containing: date(2025, 12, 25))
        #expect(period.start == date(2025, 12, 20))
        #expect(period.end == date(2026, 1, 2))
    }

    @Test("days remaining across a full cycle")
    func daysRemaining() {
        #expect(calculator.daysRemaining(from: date(2026, 1, 3)) == 13)
    }
}

@Suite("Monthly")
struct MonthlyPayPeriodTests {
    @Test("day 31 anchor clamps to Feb 28 in a non-leap year")
    func clampToFebNonLeap() {
        let schedule = PaySchedule(frequency: .monthly, anchorPeriodEnd: date(2026, 1, 31))
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: date(2026, 2, 1))
        #expect(period.start == date(2026, 2, 1))
        #expect(period.end == date(2026, 2, 28))
    }

    @Test("day 31 anchor clamps to Feb 29 in a leap year")
    func clampToFebLeap() {
        let schedule = PaySchedule(frequency: .monthly, anchorPeriodEnd: date(2024, 1, 31))
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: date(2024, 2, 1))
        #expect(period.end == date(2024, 2, 29))
    }

    @Test("day 31 anchor returns to day 31 in a long month after a short one")
    func clampRecoversInLongMonth() {
        let schedule = PaySchedule(frequency: .monthly, anchorPeriodEnd: date(2026, 1, 31))
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: date(2026, 3, 1))
        #expect(period.start == date(2026, 3, 1))
        #expect(period.end == date(2026, 3, 31))
    }

    @Test("day 30 anchor clamps in February but not in 30-day months")
    func day30Anchor() {
        let schedule = PaySchedule(frequency: .monthly, anchorPeriodEnd: date(2026, 1, 30))
        let calculator = PayPeriodCalculator(schedule: schedule)
        #expect(calculator.period(containing: date(2026, 2, 1)).end == date(2026, 2, 28))
        #expect(calculator.period(containing: date(2026, 4, 15)).end == date(2026, 4, 30))
    }

    @Test("boundary date exactly on payday belongs to the ending period")
    func exactBoundary() {
        let schedule = PaySchedule(frequency: .monthly, anchorPeriodEnd: date(2026, 1, 15))
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: date(2026, 2, 15))
        #expect(period.start == date(2026, 1, 16))
        #expect(period.end == date(2026, 2, 15))
    }
}

@Suite("Twice monthly")
struct TwiceMonthlyPayPeriodTests {
    let schedule = PaySchedule(frequency: .twiceMonthly, anchorPeriodEnd: date(2026, 1, 15))
    var calculator: PayPeriodCalculator { PayPeriodCalculator(schedule: schedule) }

    @Test("first-half period runs 1st through 15th")
    func firstHalf() {
        let period = calculator.period(containing: date(2026, 2, 10))
        #expect(period.start == date(2026, 2, 1))
        #expect(period.end == date(2026, 2, 15))
    }

    @Test("second-half period runs 16th through the last day of a 28-day February")
    func secondHalfShortMonth() {
        let period = calculator.period(containing: date(2026, 2, 20))
        #expect(period.start == date(2026, 2, 16))
        #expect(period.end == date(2026, 2, 28))
    }

    @Test("second-half period spans a 31-day month correctly")
    func secondHalfLongMonth() {
        let period = calculator.period(containing: date(2026, 1, 31))
        #expect(period.start == date(2026, 1, 16))
        #expect(period.end == date(2026, 1, 31))
    }

    @Test("leap year February last day is the 29th")
    func leapFebruary() {
        let period = calculator.period(containing: date(2024, 2, 29))
        #expect(period.start == date(2024, 2, 16))
        #expect(period.end == date(2024, 2, 29))
    }

    @Test("month rollover from last day into next month's 1st through 15th")
    func rolloverIntoNextMonth() {
        let period = calculator.period(containing: date(2026, 3, 1))
        #expect(period.start == date(2026, 3, 1))
        #expect(period.end == date(2026, 3, 15))
    }

    @Test("days remaining lands on zero on the 15th and on month end")
    func daysRemaining() {
        #expect(calculator.daysRemaining(from: date(2026, 2, 15)) == 0)
        #expect(calculator.daysRemaining(from: date(2026, 2, 28)) == 0)
        #expect(calculator.daysRemaining(from: date(2026, 2, 1)) == 14)
    }
}

@Suite("Schedule changes regroup entries without mutating them")
struct RegroupingTests {
    @Test("switching frequency changes which period a fixed date falls into")
    func regroupsOnFrequencyChange() {
        let weekly = PayPeriodCalculator(schedule: PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 1, 2)))
        let monthly = PayPeriodCalculator(schedule: PaySchedule(frequency: .monthly, anchorPeriodEnd: date(2026, 1, 2)))

        let fixedDate = date(2026, 1, 20)
        let weeklyPeriod = weekly.period(containing: fixedDate)
        let monthlyPeriod = monthly.period(containing: fixedDate)

        #expect(weeklyPeriod != monthlyPeriod)
        #expect(monthlyPeriod.start == date(2026, 1, 3))
        #expect(monthlyPeriod.end == date(2026, 2, 2))
    }
}

@Suite("Week start setting")
struct WeekStartTests {
    @Test("explicit first weekday is used")
    func explicit() {
        let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: date(2026, 1, 4), firstWeekday: 2)
        #expect(schedule.resolvedFirstWeekday == 2) // Monday
    }

    @Test("missing first weekday falls back to the locale default")
    func fallback() {
        let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: date(2026, 1, 4))
        #expect(schedule.resolvedFirstWeekday == Calendar.current.firstWeekday)
    }

    @Test("a Sunday biweekly anchor yields a Monday-to-Sunday period")
    func mondayToSundayPeriod() {
        // Jul 12 2026 is a Sunday.
        let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: date(2026, 7, 12))
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: date(2026, 7, 14)) // a Tuesday
        #expect(period.start == date(2026, 7, 13)) // Monday
        #expect(period.end == date(2026, 7, 26))   // Sunday, 14 days
    }
}

@Suite("Pay delay — period end vs. actual payday")
struct PayDelayTests {
    @Test("zero delay: payDate equals the period end (old, lag-unaware behavior)")
    func zeroDelayDefaultsToPeriodEnd() {
        let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: date(2026, 1, 2))
        let calculator = PayPeriodCalculator(schedule: schedule)
        let period = calculator.period(containing: date(2026, 1, 2))
        #expect(calculator.payDate(for: period) == period.end)
    }

    @Test("real-world case: paid on the 10th for a period ending the 5th, next paid the 24th for the 6th-19th")
    func realWorldLag() {
        // Tyler's actual schedule: biweekly periods ending the 5th/19th/etc.,
        // paycheck lands 5 days after the period ends.
        let schedule = PaySchedule(frequency: .biweekly, anchorPeriodEnd: date(2026, 7, 5), payDelayDays: 5)
        let calculator = PayPeriodCalculator(schedule: schedule)

        let currentPeriod = calculator.period(containing: date(2026, 7, 14))
        #expect(currentPeriod.start == date(2026, 7, 6))
        #expect(currentPeriod.end == date(2026, 7, 19))
        #expect(calculator.payDate(for: currentPeriod) == date(2026, 7, 24))

        let priorPeriod = calculator.period(containing: date(2026, 7, 1))
        #expect(priorPeriod.end == date(2026, 7, 5))
        #expect(calculator.payDate(for: priorPeriod) == date(2026, 7, 10))
    }

    @Test("missing payDelayDays resolves to 0")
    func missingDelayResolvesToZero() {
        let schedule = PaySchedule(frequency: .weekly, anchorPeriodEnd: date(2026, 1, 2))
        #expect(schedule.resolvedPayDelayDays == 0)
    }
}
