import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Suite("ShiftDetails resolve")
struct ShiftDetailsResolveTests {
    @Test("resolves from the credit entry when only credit holds a value")
    func onlyCredit() {
        let credit = TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit, hoursWorked: 5, tipOutCents: 1500, salesCents: 43000)
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash)
        let resolved = ShiftDetails.resolve(from: [credit, cash])
        #expect(resolved.hoursWorked == 5)
        #expect(resolved.tipOutCents == 1500)
        #expect(resolved.salesCents == 43000)
    }

    @Test("resolves from the cash entry when the value is on the 'wrong' entry and credit exists but is empty")
    func valueOnWrongEntry() {
        let credit = TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit)
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash, hoursWorked: 5, tipOutCents: 1500, salesCents: 43000)
        let resolved = ShiftDetails.resolve(from: [credit, cash])
        #expect(resolved.hoursWorked == 5)
        #expect(resolved.tipOutCents == 1500)
        #expect(resolved.salesCents == 43000)
    }

    @Test("prefers the credit entry's value, never sums, when both entries hold a value (the corruption case)")
    func valuesOnBothEntries() {
        let credit = TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit, hoursWorked: 5, tipOutCents: 1500, salesCents: 43000)
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash, hoursWorked: 5, tipOutCents: 1000, salesCents: 10000)
        let resolved = ShiftDetails.resolve(from: [credit, cash])
        // Credit's values win outright — never 10 hours, never $2500 tip-out.
        #expect(resolved.hoursWorked == 5)
        #expect(resolved.tipOutCents == 1500)
        #expect(resolved.salesCents == 43000)
    }

    @Test("falls back to the first entry when there's no credit entry at all")
    func cashOnly() {
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash, hoursWorked: 4)
        let resolved = ShiftDetails.resolve(from: [cash])
        #expect(resolved.hoursWorked == 4)
    }

    @Test("resolves to nil across the board when nothing was logged")
    func nothingLogged() {
        let credit = TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit)
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash)
        let resolved = ShiftDetails.resolve(from: [credit, cash])
        #expect(resolved.hoursWorked == nil)
        #expect(resolved.tipOutCents == nil)
        #expect(resolved.salesCents == nil)
        #expect(resolved.shiftPeriod == nil)
    }

    @Test("shift period follows the same credit-preferred, never-summed rule as the other three fields")
    func shiftPeriodResolvesLikeTheOthers() {
        let credit = TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit, shiftPeriod: .dinner)
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash, shiftPeriod: .lunch)
        // Credit's dinner wins outright — never averaged or overwritten by cash's lunch.
        #expect(ShiftDetails.resolve(from: [credit, cash]).shiftPeriod == .dinner)
    }
}

@Suite("ShiftDetails write")
struct ShiftDetailsWriteTests {
    @Test("writes onto the credit entry when one exists, leaving cash untouched")
    func writesToCreditWhenPresent() {
        let credit = TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit)
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash)
        ShiftDetails.write(hoursWorked: 5, tipOutCents: 1500, salesCents: 43000, shiftPeriod: .dinner, into: [cash, credit])
        #expect(credit.hoursWorked == 5)
        #expect(credit.tipOutCents == 1500)
        #expect(credit.salesCents == 43000)
        #expect(credit.shiftPeriod == .dinner)
        #expect(cash.hoursWorked == nil)
        #expect(cash.tipOutCents == nil)
        #expect(cash.salesCents == nil)
        #expect(cash.shiftPeriod == nil)
    }

    @Test("writes onto the only entry when there's no credit entry")
    func writesToSoleEntry() {
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash)
        ShiftDetails.write(hoursWorked: 4, tipOutCents: nil, salesCents: nil, shiftPeriod: .lunch, into: [cash])
        #expect(cash.hoursWorked == 4)
        #expect(cash.shiftPeriod == .lunch)
    }

    @Test("heals a night that was previously corrupted with values split across both entries")
    func healsSplitValues() {
        // Simulates the pre-fix bug: hours set independently on both tabs.
        let credit = TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit, hoursWorked: 5, tipOutCents: 1500, shiftPeriod: .lunch)
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash, hoursWorked: 5, tipOutCents: 1000, shiftPeriod: .dinner)
        // Editing the shift now writes one corrected value through ShiftDetails.
        ShiftDetails.write(hoursWorked: 6, tipOutCents: 2000, salesCents: nil, shiftPeriod: .dinner, into: [cash, credit])
        #expect(credit.hoursWorked == 6)
        #expect(credit.tipOutCents == 2000)
        #expect(credit.shiftPeriod == .dinner)
        // The stray values that were on cash are cleared, not left behind.
        #expect(cash.hoursWorked == nil)
        #expect(cash.tipOutCents == nil)
        #expect(cash.salesCents == nil)
        #expect(cash.shiftPeriod == nil)
    }

    @Test("clearing a value (nil) removes it from the canonical entry too")
    func clearingRemovesValue() {
        let entry = TipEntry(date: date(2026, 7, 1), amountCents: 5000, kind: .cash, hoursWorked: 5, shiftPeriod: .lunch)
        ShiftDetails.write(hoursWorked: nil, tipOutCents: nil, salesCents: nil, shiftPeriod: nil, into: [entry])
        #expect(entry.hoursWorked == nil)
        #expect(entry.shiftPeriod == nil)
    }
}
