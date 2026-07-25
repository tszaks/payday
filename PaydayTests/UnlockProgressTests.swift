import Testing
import Foundation
@testable import Payday

/// Midnight, matching how TipEntry.date is always stored in production —
/// same convention as StatsEngineTests.
private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func record(_ year: Int, _ month: Int, _ day: Int, cents: Int, kind: TipKind = .cash, hoursWorked: Double? = nil, salesCents: Int? = nil, shiftID: UUID? = nil) -> TipRecord {
    TipRecord(date: date(year, month, day), amountCents: cents, kind: kind, isDouble: false, hoursWorked: hoursWorked, salesCents: salesCents, shiftID: shiftID)
}

private func isWeekday(_ unlock: Unlock) -> Bool {
    if case .weekday = unlock.kind { return true }
    return false
}

@Suite("Insights gate")
struct InsightsUnlockTests {
    @Test("no records unlocks nothing but insights, needing 5 from 0")
    func noRecords() {
        let unlocks = UnlockProgress.nextUnlocks(records: [])
        #expect(unlocks.count == 1)
        #expect(unlocks[0].kind == .insights)
        #expect(unlocks[0].have == 0)
        #expect(unlocks[0].need == 5)
    }

    @Test("insights leads over 3 shifts across 3 weekdays, and the limit caps the result at 2")
    func insightsFirstAndLimitRespected() {
        let asOf = date(2026, 7, 10)
        let records = [
            record(2026, 7, 1, cents: 5000, hoursWorked: 5, salesCents: 20000), // Wednesday
            record(2026, 7, 3, cents: 6000), // Friday
            record(2026, 7, 6, cents: 7000)  // Monday
        ]
        // Hours and sales are each logged on exactly 1 shift here too, so
        // there are 4 qualifying candidates (insights, weekday, hourlyRate,
        // tipPercent) all tied on remaining count except insights — proving
        // the default limit of 2 actually truncates rather than coincidentally
        // matching the candidate count.
        let unlocks = UnlockProgress.nextUnlocks(records: records, asOf: asOf)
        #expect(unlocks.count == 2)
        #expect(unlocks[0].kind == .insights)
        #expect(unlocks[0].have == 3)
        #expect(unlocks[0].need == 5)
    }
}

@Suite("Weekday gate")
struct WeekdayUnlockTests {
    @Test("the weekday with 2 shifts wins over one with 1 shift, since it has the smaller remaining")
    func smallestRemainingWins() {
        let asOf = date(2026, 7, 20)
        let records = [
            record(2026, 7, 1, cents: 5000), // Wednesday
            record(2026, 7, 8, cents: 5000), // Wednesday again
            record(2026, 7, 3, cents: 5000)  // Friday
        ]
        let unlocks = UnlockProgress.nextUnlocks(records: records, asOf: asOf, limit: 5)
        let weekdayUnlocks = unlocks.filter(isWeekday)
        #expect(weekdayUnlocks.count == 1)
        let wednesday = Calendar.current.component(.weekday, from: date(2026, 7, 1))
        #expect(weekdayUnlocks[0].kind == .weekday(wednesday))
        #expect(weekdayUnlocks[0].have == 2)
        #expect(weekdayUnlocks[0].need == 3)
    }

    @Test("a weekday whose only shift is older than 45 days is excluded, not nagged about forever")
    func staleWeekdayExcluded() {
        let records = [record(2026, 1, 1, cents: 5000)]
        let asOf = date(2026, 7, 20) // roughly 200 days later
        let unlocks = UnlockProgress.nextUnlocks(records: records, asOf: asOf, limit: 5)
        #expect(!unlocks.contains(where: isWeekday))
    }

    @Test("a weekday within the 45-day window is still included")
    func recentWeekdayIncluded() {
        let records = [record(2026, 7, 1, cents: 5000)]
        let asOf = date(2026, 7, 20) // 19 days later
        let unlocks = UnlockProgress.nextUnlocks(records: records, asOf: asOf, limit: 5)
        #expect(unlocks.contains(where: isWeekday))
    }
}

@Suite("Hourly rate gate")
struct HourlyRateUnlockTests {
    @Test("absent when no shift has hours logged")
    func absentAtZero() {
        let records = [record(2026, 7, 1, cents: 5000), record(2026, 7, 2, cents: 5000)]
        let unlocks = UnlockProgress.nextUnlocks(records: records, limit: 10)
        #expect(!unlocks.contains { $0.kind == .hourlyRate })
    }

    @Test("present with have 1 once a single shift logs hours")
    func presentAtOne() {
        let records = [record(2026, 7, 1, cents: 5000, hoursWorked: 5), record(2026, 7, 2, cents: 5000)]
        let unlocks = UnlockProgress.nextUnlocks(records: records, limit: 10)
        let unlock = unlocks.first { $0.kind == .hourlyRate }
        #expect(unlock?.have == 1)
        #expect(unlock?.need == 3)
    }

    @Test("absent once the gate is already cleared at 3")
    func absentAtThreshold() {
        let records = [
            record(2026, 7, 1, cents: 5000, hoursWorked: 5),
            record(2026, 7, 2, cents: 5000, hoursWorked: 5),
            record(2026, 7, 3, cents: 5000, hoursWorked: 5)
        ]
        let unlocks = UnlockProgress.nextUnlocks(records: records, limit: 10)
        #expect(!unlocks.contains { $0.kind == .hourlyRate })
    }
}

@Suite("Tip percent gate")
struct TipPercentUnlockTests {
    @Test("absent when no shift has sales logged")
    func absentAtZero() {
        let records = [record(2026, 7, 1, cents: 5000), record(2026, 7, 2, cents: 5000)]
        let unlocks = UnlockProgress.nextUnlocks(records: records, limit: 10)
        #expect(!unlocks.contains { $0.kind == .tipPercent })
    }

    @Test("present with have 1 once a single shift logs sales")
    func presentAtOne() {
        let records = [record(2026, 7, 1, cents: 5000, salesCents: 20000), record(2026, 7, 2, cents: 5000)]
        let unlocks = UnlockProgress.nextUnlocks(records: records, limit: 10)
        let unlock = unlocks.first { $0.kind == .tipPercent }
        #expect(unlock?.have == 1)
        #expect(unlock?.need == 3)
    }

    @Test("absent once the gate is already cleared at 3")
    func absentAtThreshold() {
        let records = [
            record(2026, 7, 1, cents: 5000, salesCents: 20000),
            record(2026, 7, 2, cents: 5000, salesCents: 20000),
            record(2026, 7, 3, cents: 5000, salesCents: 20000)
        ]
        let unlocks = UnlockProgress.nextUnlocks(records: records, limit: 10)
        #expect(!unlocks.contains { $0.kind == .tipPercent })
    }
}

@Suite("Mature account")
struct MatureAccountUnlockTests {
    @Test("every gate cleared leaves nothing left to anticipate")
    func noUnlocksWhenEverythingIsCleared() {
        // 3 full weeks (21 consecutive days from a Monday) gives exactly 3
        // occurrences of every weekday, each shift logging both hours and
        // sales — every gate in the file cleared at once.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var day = date(2026, 6, 29) // a Monday
        var records: [TipRecord] = []
        for _ in 0..<21 {
            records.append(TipRecord(date: day, amountCents: 5000, kind: .cash, isDouble: false, hoursWorked: 5, salesCents: 20000))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let unlocks = UnlockProgress.nextUnlocks(records: records, asOf: date(2026, 7, 20), limit: 10)
        #expect(unlocks.isEmpty)
    }
}

@Suite("Unlock copy")
struct UnlockCopyTests {
    @Test("insights copy is singular for exactly 1 remaining, plural otherwise")
    func insightsSingularPlural() {
        let singular = Unlock(kind: .insights, have: 4, need: 5)
        #expect(singular.line == "1 more shift and Payday starts reading your patterns.")
        let plural = Unlock(kind: .insights, have: 3, need: 5)
        #expect(plural.line == "2 more shifts and Payday starts reading your patterns.")
    }

    @Test("weekday copy names the weekday and is singular for exactly 1 remaining, plural otherwise")
    func weekdaySingularPlural() {
        let friday = Calendar.current.component(.weekday, from: date(2026, 7, 3))
        let singular = Unlock(kind: .weekday(friday), have: 2, need: 3)
        #expect(singular.line == "1 more Friday shift and Fridays get their own read.")
        let plural = Unlock(kind: .weekday(friday), have: 1, need: 3)
        #expect(plural.line == "2 more Friday shifts and Fridays get their own read.")
    }

    @Test("hourlyRate copy is singular for exactly 1 remaining, plural otherwise")
    func hourlyRateSingularPlural() {
        let singular = Unlock(kind: .hourlyRate, have: 2, need: 3)
        #expect(singular.line == "1 more shift with times and your hourly rate unlocks.")
        let plural = Unlock(kind: .hourlyRate, have: 1, need: 3)
        #expect(plural.line == "2 more shifts with times and your hourly rate unlocks.")
    }

    @Test("tipPercent copy is singular for exactly 1 remaining, plural otherwise")
    func tipPercentSingularPlural() {
        let singular = Unlock(kind: .tipPercent, have: 2, need: 3)
        #expect(singular.line == "1 more shift with sales and your tip percent unlocks.")
        let plural = Unlock(kind: .tipPercent, have: 1, need: 3)
        #expect(plural.line == "2 more shifts with sales and your tip percent unlocks.")
    }
}

@Suite("Shift counting")
struct ShiftCountTests {
    @Test("records sharing a shiftID count as one shift")
    func groupsByShiftID() {
        let shiftID = UUID()
        let records = [
            record(2026, 7, 1, cents: 5000, kind: .cash, shiftID: shiftID),
            record(2026, 7, 1, cents: 3000, kind: .credit, shiftID: shiftID)
        ]
        #expect(UnlockProgress.shiftCount(records: records) == 1)
    }

    @Test("legacy records with a nil shiftID fall back to grouping by calendar day")
    func groupsLegacyByDay() {
        let records = [
            record(2026, 7, 1, cents: 5000, kind: .cash),
            record(2026, 7, 1, cents: 3000, kind: .credit)
        ]
        #expect(UnlockProgress.shiftCount(records: records) == 1)
    }

    @Test("distinct days are distinct shifts")
    func distinctDaysAreDistinctShifts() {
        let records = [record(2026, 7, 1, cents: 5000), record(2026, 7, 2, cents: 5000)]
        #expect(UnlockProgress.shiftCount(records: records) == 2)
    }
}
