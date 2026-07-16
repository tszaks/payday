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

@Suite("Shift day grouping")
struct ShiftDayGroupingTests {
    struct Item: Equatable {
        let date: Date
        let cents: Int
    }

    @Test("same-day items merge into one group, newest day first")
    func merges() {
        let items = [
            Item(date: date(2026, 7, 14), cents: 3200),
            Item(date: date(2026, 7, 14), cents: 8600),
            Item(date: date(2026, 7, 13), cents: 11200),
        ]
        let groups = ShiftDays.groupedByDay(items, date: \.date)
        #expect(groups.count == 2)
        #expect(groups[0].day == date(2026, 7, 14))
        #expect(groups[0].items.count == 2)
        #expect(groups[1].items.count == 1)
    }

    @Test("times within a day still group to that day")
    func groupsAcrossTimes() {
        let items = [
            Item(date: date(2026, 7, 14, hour: 1), cents: 100),
            Item(date: date(2026, 7, 14, hour: 23), cents: 200),
        ]
        let groups = ShiftDays.groupedByDay(items, date: \.date)
        #expect(groups.count == 1)
    }

    @Test("human labels: today, yesterday, weekday, then dated")
    func labels() {
        let now = date(2026, 7, 14, hour: 20) // a Tuesday
        // "Today", not "Tonight" — a shift is a whole day; a lunch logged
        // at 2pm and read back at 8pm must not read "Tonight."
        #expect(ShiftDays.humanLabel(for: date(2026, 7, 14), relativeTo: now) == "Today")
        // A 2pm shift is still "Today", never "Tonight".
        #expect(ShiftDays.humanLabel(for: date(2026, 7, 14, hour: 14), relativeTo: now) == "Today")
        #expect(ShiftDays.humanLabel(for: date(2026, 7, 13), relativeTo: now) == "Yesterday")
        #expect(ShiftDays.humanLabel(for: date(2026, 7, 10), relativeTo: now) == "Friday")
        let older = ShiftDays.humanLabel(for: date(2026, 7, 3), relativeTo: now)
        #expect(older.contains("Friday") && older.contains("3"))
        #expect(!older.contains("2026"))
    }
}

@Suite("Tonight line")
struct TonightLineTests {
    // date(2026, 7, 14) is a Tuesday → Gregorian weekday 3.
    let tuesdayNight = date(2026, 7, 14, hour: 19)

    @Test("payday moment silences the line entirely")
    func paydaySilence() {
        let rhythm = WorkRhythm(usualWeekdays: [3], typicalLogHour: 22)
        let line = TonightLine.compose(rhythm: rhythm, tonightRevealText: "$100.00 today.", isPaydayMoment: true, now: tuesdayNight)
        #expect(line == nil)
    }

    @Test("logged today echoes the reveal verdict verbatim")
    func revealEcho() {
        let rhythm = WorkRhythm(usualWeekdays: [3], typicalLogHour: 22)
        let line = TonightLine.compose(rhythm: rhythm, tonightRevealText: "$118.00 today. $34.00 above your Tuesday average.", isPaydayMoment: false, now: tuesdayNight)
        #expect(line == "$118.00 today. $34.00 above your Tuesday average.")
    }

    @Test("usual work day with a typical hour prompts with the time, no time-of-day word")
    func workNightPrompt() {
        let rhythm = WorkRhythm(usualWeekdays: [3], typicalLogHour: 22)
        let line = TonightLine.compose(rhythm: rhythm, tonightRevealText: nil, isPaydayMoment: false, now: tuesdayNight)
        #expect(line == "You usually work Tuesdays around 10\u{202F}PM.")
    }

    @Test("usual work day without a typical hour still prompts")
    func workNightPromptNoHour() {
        let rhythm = WorkRhythm(usualWeekdays: [3], typicalLogHour: nil)
        let line = TonightLine.compose(rhythm: rhythm, tonightRevealText: nil, isPaydayMoment: false, now: tuesdayNight)
        #expect(line == "You usually work Tuesdays.")
    }

    @Test("not a usual night, nothing logged: no line")
    func offNightSilence() {
        let rhythm = WorkRhythm(usualWeekdays: [6], typicalLogHour: 22)
        let line = TonightLine.compose(rhythm: rhythm, tonightRevealText: nil, isPaydayMoment: false, now: tuesdayNight)
        #expect(line == nil)
    }
}
