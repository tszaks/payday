import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite("Work schedule nudge timing")
struct WorkScheduleNudgeTests {
    private typealias Shift = WorkScheduleNudge.ScheduledShift

    @Test("fires 15 minutes after a future shift's end")
    func firesAfterFutureEnd() {
        let shift = Shift(start: date(2026, 7, 28, hour: 17), end: date(2026, 7, 28, hour: 22))
        let fireDate = WorkScheduleNudge.fireDate(
            shifts: [shift],
            now: date(2026, 7, 28, hour: 12),
            alreadyLoggedToday: false
        )
        #expect(fireDate == date(2026, 7, 28, hour: 22, minute: 15))
    }

    @Test("a shift that already ended is skipped")
    func skipsPastEvents() {
        let pastShift = Shift(start: date(2026, 7, 27, hour: 17), end: date(2026, 7, 27, hour: 22))
        let fireDate = WorkScheduleNudge.fireDate(
            shifts: [pastShift],
            now: date(2026, 7, 28, hour: 12),
            alreadyLoggedToday: false
        )
        #expect(fireDate == nil)
    }

    @Test("already logged today skips today's ending shift for tomorrow's")
    func skipsTodayWhenAlreadyLogged() {
        let todayShift = Shift(start: date(2026, 7, 28, hour: 17), end: date(2026, 7, 28, hour: 22))
        let tomorrowShift = Shift(start: date(2026, 7, 29, hour: 17), end: date(2026, 7, 29, hour: 22))
        let fireDate = WorkScheduleNudge.fireDate(
            shifts: [todayShift, tomorrowShift],
            now: date(2026, 7, 28, hour: 12),
            alreadyLoggedToday: true
        )
        #expect(fireDate == date(2026, 7, 29, hour: 22, minute: 15))
    }

    @Test("a shift beyond the 7-day horizon is excluded")
    func excludesBeyondHorizon() {
        let now = date(2026, 7, 28, hour: 12)
        let farShift = Shift(start: date(2026, 8, 5, hour: 17), end: date(2026, 8, 5, hour: 22)) // 8 days out
        let fireDate = WorkScheduleNudge.fireDate(shifts: [farShift], now: now, alreadyLoggedToday: false)
        #expect(fireDate == nil)
    }

    @Test("an all-day event is not a shift closeout time")
    func ignoresAllDayEvents() {
        let allDayEvent = Shift(start: date(2026, 7, 28, hour: 0), end: date(2026, 7, 29, hour: 0))
        let fireDate = WorkScheduleNudge.fireDate(
            shifts: [allDayEvent],
            now: date(2026, 7, 28, hour: 12),
            alreadyLoggedToday: false
        )
        #expect(fireDate == nil)
    }

    @Test("a double posted as two overlapping blocks nudges once, after the second")
    func overlappingClusterUsesLatestEnd() {
        let firstBlock = Shift(start: date(2026, 7, 28, hour: 11), end: date(2026, 7, 28, hour: 17))
        let secondBlock = Shift(start: date(2026, 7, 28, hour: 16), end: date(2026, 7, 28, hour: 22))
        let fireDate = WorkScheduleNudge.fireDate(
            shifts: [firstBlock, secondBlock],
            now: date(2026, 7, 28, hour: 9),
            alreadyLoggedToday: false
        )
        #expect(fireDate == date(2026, 7, 28, hour: 22, minute: 15))
    }

    @Test("no shifts means no fire date")
    func emptyShiftsProduceNil() {
        let fireDate = WorkScheduleNudge.fireDate(shifts: [], now: date(2026, 7, 28, hour: 12), alreadyLoggedToday: false)
        #expect(fireDate == nil)
    }
}
