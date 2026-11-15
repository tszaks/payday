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
            TipRecord(date: day(2026, 7, 1), amountCents: 5000, kind: .cash, shiftPeriod: .dinner, shiftID: dinner),
            TipRecord(date: day(2026, 7, 1), amountCents: 4000, kind: .cash, shiftPeriod: .lunch, shiftID: lunch)
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
            TipRecord(date: day(2026, 7, 1), amountCents: 5000, kind: .cash, shiftID: shift),
            TipRecord(date: day(2026, 7, 1), amountCents: 3000, kind: .credit, shiftID: shift)
        ]
        let groups = ShiftDays.groupedByShift(records, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
        #expect(groups.count == 1)
        #expect(groups[0].items.count == 2)
    }

    @Test("records with a nil shiftID fall back to one shift per day")
    func nilShiftIDFallsBackToDay() {
        let records = [
            TipRecord(date: day(2026, 7, 1), amountCents: 5000, kind: .cash),
            TipRecord(date: day(2026, 7, 1), amountCents: 3000, kind: .credit)
        ]
        let groups = ShiftDays.groupedByShift(records, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
        #expect(groups.count == 1)
    }

    @Test("a single-shift day always shows its exact date and period")
    func singleShiftLabelIsComplete() {
        let label = ShiftDays.shiftLabel(day: day(2026, 7, 1), period: .lunch, dayHasMultipleShifts: false)
        #expect(label == "Wednesday, Jul 1 · Lunch")
    }

    @Test("a double day uses the same exact-date shape for each period")
    func doubleDayLabelsByPeriod() {
        let lunch = ShiftDays.shiftLabel(day: day(2026, 7, 1), period: .lunch, dayHasMultipleShifts: true)
        let dinner = ShiftDays.shiftLabel(day: day(2026, 7, 1), period: .dinner, dayHasMultipleShifts: true)
        #expect(lunch == "Wednesday, Jul 1 · Lunch")
        #expect(dinner == "Wednesday, Jul 1 · Dinner")
    }

    @Test("shift labels do not change as a record ages")
    func shiftLabelsIgnoreRecency() {
        let today = Calendar.current.startOfDay(for: .now)
        let label = ShiftDays.shiftLabel(day: today, period: .dinner, dayHasMultipleShifts: false)

        #expect(!label.contains("Today"))
        #expect(label == "\(today.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) · Dinner")
    }

    @Test("5 worked days with 2 doubles count as 7 shifts, not 5 days — the YTD card's counting rule")
    func fiveDaysTwoDoublesCountSevenShifts() {
        let records = [
            TipRecord(date: day(2026, 1, 5), amountCents: 5000, kind: .cash, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 6), amountCents: 5000, kind: .cash, shiftPeriod: .lunch, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 6), amountCents: 5000, kind: .cash, shiftPeriod: .dinner, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 7), amountCents: 5000, kind: .cash, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 8), amountCents: 5000, kind: .cash, shiftPeriod: .lunch, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 8), amountCents: 5000, kind: .cash, shiftPeriod: .dinner, shiftID: UUID()),
            TipRecord(date: day(2026, 1, 9), amountCents: 5000, kind: .cash, shiftID: UUID())
        ]
        let groups = ShiftDays.groupedByShift(records, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod)
        #expect(groups.count == 7)
    }
}
