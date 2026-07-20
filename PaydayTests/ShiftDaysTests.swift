import Testing
import Foundation
@testable import Payday

private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: d))!
}

@Suite("Shift grouping")
struct ShiftDaysTests {
    @Test("two shifts on one day become two groups, ordered lunch then dinner")
    func doubleDaySplitsIntoTwoOrderedGroups() {
        let lunch = UUID()
        let dinner = UUID()
        let records = [
            TipRecord(date: day(2026, 7, 1), amountCents: 5000, kind: .cash, isDouble: false, shiftPeriod: .dinner, shiftID: dinner),
            TipRecord(date: day(2026, 7, 1), amountCents: 4000, kind: .cash, isDouble: false, shiftPeriod: .lunch, shiftID: lunch)
        ]
        let groups = ShiftDays.groupedByShift(records, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
        #expect(groups.count == 2)
        #expect(groups[0].shiftID == lunch)
        #expect(groups[1].shiftID == dinner)
    }

    @Test("cash and credit of one closeout stay a single group")
    func oneShiftKeepsCashAndCreditTogether() {
        let shift = UUID()
        let records = [
            TipRecord(date: day(2026, 7, 1), amountCents: 5000, kind: .cash, isDouble: false, shiftID: shift),
            TipRecord(date: day(2026, 7, 1), amountCents: 3000, kind: .credit, isDouble: false, shiftID: shift)
        ]
        let groups = ShiftDays.groupedByShift(records, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
        #expect(groups.count == 1)
        #expect(groups[0].items.count == 2)
    }

    @Test("records with a nil shiftID fall back to one shift per day")
    func nilShiftIDFallsBackToDay() {
        let records = [
            TipRecord(date: day(2026, 7, 1), amountCents: 5000, kind: .cash, isDouble: false),
            TipRecord(date: day(2026, 7, 1), amountCents: 3000, kind: .credit, isDouble: false)
        ]
        let groups = ShiftDays.groupedByShift(records, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
        #expect(groups.count == 1)
    }

    @Test("a single-shift day reads as a plain human label")
    func singleShiftLabelIsPlain() {
        let label = ShiftDays.shiftLabel(day: day(2026, 7, 1), period: .lunch, dayHasMultipleShifts: false, relativeTo: day(2026, 7, 1))
        #expect(label == "Today")
    }

    @Test("a double day labels each shift by its period")
    func doubleDayLabelsByPeriod() {
        let lunch = ShiftDays.shiftLabel(day: day(2026, 7, 1), period: .lunch, dayHasMultipleShifts: true, relativeTo: day(2026, 7, 1))
        let dinner = ShiftDays.shiftLabel(day: day(2026, 7, 1), period: .dinner, dayHasMultipleShifts: true, relativeTo: day(2026, 7, 1))
        #expect(lunch == "Today · Lunch")
        #expect(dinner == "Today · Dinner")
    }

    @Test("5 worked days with 2 doubles count as 7 shifts, not 5 days — the YTD card's counting rule")
    func fiveDaysTwoDoublesCountSevenShifts() {
        let records = [
            TipRecord(date: day(2026, 1, 5), amountCents: 5000, kind: .cash, isDouble: false, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 6), amountCents: 5000, kind: .cash, isDouble: true, shiftPeriod: .lunch, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 6), amountCents: 5000, kind: .cash, isDouble: true, shiftPeriod: .dinner, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 7), amountCents: 5000, kind: .cash, isDouble: false, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 8), amountCents: 5000, kind: .cash, isDouble: true, shiftPeriod: .lunch, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 8), amountCents: 5000, kind: .cash, isDouble: true, shiftPeriod: .dinner, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 9), amountCents: 5000, kind: .cash, isDouble: false, shiftID: UUID())
        ]
        let groups = ShiftDays.groupedByShift(records, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
        #expect(groups.count == 7)
    }
}
