import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite("ShiftBeliefLine")
struct ShiftBeliefLineTests {
    private let now = date(2026, 7, 12, 20, 0)

    @Test("Today, when the shift's date is the same calendar day as now")
    func todayLabel() {
        let line = ShiftBeliefLine.compose(date: now, shiftPeriod: nil, clockIn: nil, clockOut: nil, tipOutCents: 0, now: now)
        #expect(line == "Today · add details")
    }

    @Test("Yesterday, exactly one calendar day back")
    func yesterdayLabel() {
        let yesterday = date(2026, 7, 11, 9, 0)
        let line = ShiftBeliefLine.compose(date: yesterday, shiftPeriod: nil, clockIn: nil, clockOut: nil, tipOutCents: 0, now: now)
        #expect(line == "Yesterday · add details")
    }

    @Test("an absolute abbreviated date beyond yesterday, never a weekday name")
    func absoluteDateLabel() {
        let older = date(2026, 7, 1, 9, 0)
        let line = ShiftBeliefLine.compose(date: older, shiftPeriod: nil, clockIn: nil, clockOut: nil, tipOutCents: 0, now: now)
        #expect(line == "Jul 1 · add details")
    }

    @Test("nothing known beyond the date falls back to 'add details'")
    func addDetailsFallback() {
        let line = ShiftBeliefLine.compose(date: now, shiftPeriod: nil, clockIn: nil, clockOut: nil, tipOutCents: 0, now: now)
        #expect(line == "Today · add details")
    }

    @Test("the period clause names Lunch or Dinner when set")
    func periodClause() {
        let line = ShiftBeliefLine.compose(date: now, shiftPeriod: .dinner, clockIn: nil, clockOut: nil, tipOutCents: 0, now: now)
        #expect(line == "Today · Dinner")
    }

    @Test("the punch range only appears when BOTH clockIn and clockOut are set")
    func punchRangeRequiresBothPunches() {
        let onlyIn = ShiftBeliefLine.compose(date: now, shiftPeriod: nil, clockIn: date(2026, 7, 12, 17, 2), clockOut: nil, tipOutCents: 0, now: now)
        #expect(onlyIn == "Today · add details")
    }

    @Test("punch range formats as a spaced en dash, AM/PM shown once when both sides agree")
    func punchRangeFormatting() {
        let clockIn = date(2026, 7, 12, 17, 2)
        let clockOut = date(2026, 7, 12, 23, 41)
        let line = ShiftBeliefLine.compose(date: now, shiftPeriod: nil, clockIn: clockIn, clockOut: clockOut, tipOutCents: 0, now: now)
        #expect(line == "Today · 5:02 – 11:41 PM")
    }

    @Test("tipped-out clause shows whole dollars when the amount is an even dollar figure")
    func tippedOutEvenDollars() {
        let line = ShiftBeliefLine.compose(date: now, shiftPeriod: nil, clockIn: nil, clockOut: nil, tipOutCents: 1500, now: now)
        #expect(line == "Today · $15 tipped out")
    }

    @Test("tipped-out clause shows cents when the amount isn't an even dollar figure")
    func tippedOutWithCents() {
        let line = ShiftBeliefLine.compose(date: now, shiftPeriod: nil, clockIn: nil, clockOut: nil, tipOutCents: 1550, now: now)
        #expect(line == "Today · $15.50 tipped out")
    }

    @Test("no tipped-out clause when tipOutCents is zero")
    func noTippedOutClauseWhenZero() {
        let line = ShiftBeliefLine.compose(date: now, shiftPeriod: .lunch, clockIn: nil, clockOut: nil, tipOutCents: 0, now: now)
        #expect(line == "Today · Lunch")
    }

    @Test("clauses order as date, period, punch range, tipped-out")
    func clauseOrdering() {
        let clockIn = date(2026, 7, 12, 17, 2)
        let clockOut = date(2026, 7, 12, 23, 41)
        let line = ShiftBeliefLine.compose(date: now, shiftPeriod: .dinner, clockIn: clockIn, clockOut: clockOut, tipOutCents: 1500, now: now)
        #expect(line == "Today · Dinner · 5:02 – 11:41 PM · $15 tipped out")
    }
}
