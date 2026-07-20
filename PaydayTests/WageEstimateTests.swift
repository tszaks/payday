import Testing
import Foundation
@testable import Payday

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Suite("WageEstimate cents")
struct WageEstimateCentsTests {
    @Test("multiplies wage rate by hours, rounding to the nearest cent")
    func rateTimesHours() {
        #expect(WageEstimate.cents(wageCentsPerHour: 283, hours: 8) == 2264)
    }

    @Test("rounds fractional cents to the nearest whole cent")
    func roundsFractionalCents() {
        // 2.83 * 7.75 = 21.9325 -> 2193 cents rounded, not truncated to 2192.
        #expect(WageEstimate.cents(wageCentsPerHour: 283, hours: 7.75) == 2193)
    }

    @Test("nil when the wage rate isn't set")
    func nilWhenRateUnset() {
        #expect(WageEstimate.cents(wageCentsPerHour: nil, hours: 8) == nil)
    }

    @Test("nil when no hours were logged — never fabricated from a fallback")
    func nilWhenHoursAreZero() {
        #expect(WageEstimate.cents(wageCentsPerHour: 283, hours: 0) == nil)
    }
}

@Suite("WageEstimate loggedHours")
struct WageEstimateLoggedHoursTests {
    @Test("sums each shift's canonical hours across multiple shifts")
    func sumsAcrossShifts() {
        let shiftOne = [TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit, hoursWorked: 5)]
        let shiftTwo = [TipEntry(date: date(2026, 7, 2), amountCents: 9200, kind: .credit, hoursWorked: 6)]
        #expect(WageEstimate.loggedHours(shiftGroups: [shiftOne, shiftTwo]) == 11)
    }

    @Test("a shift with no logged hours contributes zero, not nil-propagated nonsense")
    func missingHoursContributeZero() {
        let shiftWithHours = [TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit, hoursWorked: 5)]
        let shiftWithoutHours = [TipEntry(date: date(2026, 7, 2), amountCents: 3200, kind: .cash)]
        #expect(WageEstimate.loggedHours(shiftGroups: [shiftWithHours, shiftWithoutHours]) == 5)
    }

    @Test("two TipEntry records (cash + credit) for the SAME shift never double-count its hours")
    func sameShiftEntriesDontDoubleCount() {
        let credit = TipEntry(date: date(2026, 7, 1), amountCents: 8600, kind: .credit, hoursWorked: 5)
        let cash = TipEntry(date: date(2026, 7, 1), amountCents: 3200, kind: .cash, hoursWorked: 5)
        // Both rows report hoursWorked (the pre-ShiftDetails corruption case),
        // but they belong to one shift group, so ShiftDetails.resolve counts
        // it once — 5, never 10.
        #expect(WageEstimate.loggedHours(shiftGroups: [[credit, cash]]) == 5)
    }

    @Test("empty input sums to zero")
    func emptyInputIsZero() {
        #expect(WageEstimate.loggedHours(shiftGroups: []) == 0)
    }
}

@Suite("WageEstimate shiftTotalCents")
struct WageEstimateShiftTotalCentsTests {
    @Test("cash + credit, net of tip-out, plus base-rate wages for the hours logged")
    func cashCreditTipOutAndWages() {
        // Credit 38400, tip-out 6408, 6 hours at $2.83/hr -> 1698 cents wages.
        let cents = WageEstimate.shiftTotalCents(cashCents: 0, creditCents: 38400, tipOutCents: 6408, wageCentsPerHour: 283, hoursWorked: 6)
        #expect(cents == 38400 - 6408 + 1698)
    }

    @Test("no hours logged yet: no wages, total is just cash + credit net of tip-out")
    func noHoursNoWages() {
        let cents = WageEstimate.shiftTotalCents(cashCents: 10000, creditCents: 5000, tipOutCents: 2000, wageCentsPerHour: 2000, hoursWorked: nil)
        #expect(cents == 13000)
    }

    @Test("nil wage rate degrades to today's tips-only math exactly")
    func nilRateDegradesToTipsOnly() {
        let cents = WageEstimate.shiftTotalCents(cashCents: 10000, creditCents: 5000, tipOutCents: 2000, wageCentsPerHour: nil, hoursWorked: 6)
        #expect(cents == 13000)
    }

    @Test("zero tip-out and zero wage rate: total is just the gross")
    func noTipOutNoWage() {
        let cents = WageEstimate.shiftTotalCents(cashCents: 10000, creditCents: 5000, tipOutCents: 0, wageCentsPerHour: nil, hoursWorked: nil)
        #expect(cents == 15000)
    }
}
