import Testing
@testable import PaydayCore

@Suite("DayRange")
struct DayRangeTests {
    let week = DayRange(start: CivilDay(year: 2026, month: 9, day: 28), end: CivilDay(year: 2026, month: 10, day: 4))

    @Test("count is inclusive")
    func count() {
        #expect(week.count == 7)
        #expect(DayRange(day: CivilDay(year: 2026, month: 9, day: 28)).count == 1)
    }

    @Test("contains includes both endpoints and nothing outside")
    func contains() {
        #expect(week.contains(CivilDay(year: 2026, month: 9, day: 28)))
        #expect(week.contains(CivilDay(year: 2026, month: 10, day: 4)))
        #expect(week.contains(CivilDay(year: 2026, month: 10, day: 1)))
        #expect(!week.contains(CivilDay(year: 2026, month: 9, day: 27)))
        #expect(!week.contains(CivilDay(year: 2026, month: 10, day: 5)))
    }

    @Test("clamped(to:) trims the end to asOf and leaves earlier ends alone")
    func clamped() {
        let asOf = CivilDay(year: 2026, month: 10, day: 2)
        let clamped = week.clamped(to: asOf)
        #expect(clamped.start == week.start)
        #expect(clamped.end == asOf)
        #expect(clamped.count == 5)
        #expect(!clamped.contains(CivilDay(year: 2026, month: 10, day: 3)))
        #expect(week.clamped(to: CivilDay(year: 2026, month: 12, day: 25)) == week)
    }

    @Test("clamped(to:) before the start yields an empty range, not a trap")
    func clampedBeforeStart() {
        let empty = week.clamped(to: CivilDay(year: 2026, month: 9, day: 1))
        #expect(empty.isEmpty)
        #expect(empty.count == 0)
        #expect(!empty.contains(CivilDay(year: 2026, month: 9, day: 28)))
        #expect(empty.days.isEmpty)
    }

    @Test("days lists every day in order")
    func days() {
        let days = week.days
        #expect(days.count == 7)
        #expect(days.first == week.start)
        #expect(days.last == week.end)
        #expect(days.map(\.weekday) == [2, 3, 4, 5, 6, 7, 1])
    }
}
