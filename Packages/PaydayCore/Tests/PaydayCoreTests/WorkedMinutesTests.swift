import Testing
@testable import PaydayCore

@Suite("WorkedMinutes")
struct WorkedMinutesTests {
    @Test("383/60 hours is exactly 383 minutes")
    func minutesFromFractionalHours() {
        #expect(WorkedMinutes.minutes(fromHours: 383.0 / 60.0) == 383)
        #expect(WorkedMinutes.minutes(fromHours: 4.25) == 255)
        #expect(WorkedMinutes.minutes(fromHours: 5.5) == 330)
        #expect(WorkedMinutes.minutes(fromHours: 0) == 0)
    }

    @Test("Every minute count survives a round trip through decimal hours", arguments: [0, 1, 59, 60, 383, 615, 2400, 2401, 10_000])
    func roundTrip(minutes: Int) {
        #expect(WorkedMinutes.minutes(fromHours: WorkedMinutes.hours(fromMinutes: minutes)) == minutes)
    }

    @Test("hoursLabel spells 383 minutes as 6h 23m")
    func labelWithMinutes() {
        #expect(WorkedMinutes.hoursLabel(minutes: 383) == "6h 23m")
    }

    @Test("hoursLabel drops the minutes only when they are exactly zero")
    func labelWholeHours() {
        #expect(WorkedMinutes.hoursLabel(minutes: WorkedMinutes.minutes(fromHours: 5.0)) == "5h")
        #expect(WorkedMinutes.hoursLabel(minutes: 0) == "0h")
        #expect(WorkedMinutes.hoursLabel(minutes: 61) == "1h 1m")
        #expect(WorkedMinutes.hoursLabel(minutes: 2400) == "40h")
    }
}
