import Testing
import Foundation
@testable import Payday

/// A gregorian calendar in the payroll zone, with the workweek start the
/// payroll calendar policy owns (Monday here, weekday 2).
private func payrollCalendar(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    calendar.firstWeekday = firstWeekday
    return calendar
}

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
    payrollCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func shiftID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
}

/// Definition of Done #5, first clause: **a day equals the sum of that day's
/// shifts.** Measured on the exact arithmetic `DayDetailSheet` performs —
/// the hero is `TipBreakdown` net plus `WageEstimate.centsByShiftID`, and
/// every `ShiftDayRow` under it prints its own slice out of that same
/// dictionary.
///
/// This is the invariant PR 3's first cut broke: the hero moved onto the
/// ledger's cumulative per-week allocation while each row kept calling
/// `WageEstimate.cents(wageCentsPerHour:hours:)`, which rounds every shift
/// independently. W1's two shifts on one day then read 2759 in the hero and
/// 1203 + 1557 = 2760 in the rows directly beneath it. A screen was a cent
/// apart from itself.
@Suite("A day's hero equals the sum of the shift rows it lists")
struct DayHeroEqualsItsRowsTests {
    /// Exactly what `DayDetailFacts` does, in the same order.
    private func dayFacts(
        entries: [TipEntry],
        wageCentsPerHour: Int?,
        workweekStartWeekday: Int = 2
    ) -> (heroCents: Int, rowCents: [Int], wagesByShiftID: [UUID: Int]) {
        let calendar = payrollCalendar(firstWeekday: workweekStartWeekday)
        let shifts = ShiftDays.groupedByShift(
            entries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod, calendar: calendar
        )
        let wagesByShiftID = WageEstimate.centsByShiftID(
            payrollTimeZone: PaydayTestZone.payroll,
            workweekStartWeekday: workweekStartWeekday,
            shifts: shifts,
            wageCentsPerHour: wageCentsPerHour
        )
        let hero = TipBreakdown.total(of: entries).netTotalCents
            + shifts.reduce(0) { $0 + (wagesByShiftID[$1.shiftID] ?? 0) }
        // What ShiftDayRow renders: that shift's net tips plus its slice.
        let rows = shifts.map { group in
            TipBreakdown.total(of: group.items).netTotalCents + (wagesByShiftID[group.shiftID] ?? 0)
        }
        return (hero, rows, wagesByShiftID)
    }

    @Test("W1's two shifts on one day: the rows are 1203 and 1556, and 2759 is both the hero and their sum")
    func w1DayReconciles() {
        let day = at(2026, 9, 28)
        let entries = [
            TipEntry(date: day, amountCents: 5000, kind: .credit, hoursWorked: 4.25,
                     shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: day.addingTimeInterval(3600), amountCents: 6000, kind: .credit, hoursWorked: 5.5,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let facts = dayFacts(entries: entries, wageCentsPerHour: 283)

        // The wage halves, pinned by number: lunch takes the threshold first.
        #expect(facts.wagesByShiftID[shiftID(1)] == 1203)
        #expect(facts.wagesByShiftID[shiftID(2)] == 1556)
        #expect(facts.wagesByShiftID.values.reduce(0, +) == 2759, "W1's golden number")
        #expect(facts.wagesByShiftID.values.reduce(0, +) != 2760, "the superseded per-shift rounding")

        // The row the person reads no longer uses the naive figure, which is
        // still 1557 for the same 5.5h shift on its own.
        #expect(WageEstimate.cents(wageCentsPerHour: 283, hours: 5.5) == 1557)
        #expect(facts.wagesByShiftID[shiftID(2)] != 1557)

        // And the invariant: hero == Σ rows, to the cent.
        #expect(facts.rowCents == [5000 + 1203, 6000 + 1556])
        #expect(facts.heroCents == facts.rowCents.reduce(0, +))
        #expect(facts.heroCents == 5000 + 6000 + 2759)
    }

    @Test("a day whose shifts straddle the weekly threshold still reconciles, overtime and all")
    func straddlingDayReconciles() {
        // Mon-Wed 10h each puts 30 hours on the clock; Thursday's lunch and
        // dinner then split the last 10 regular hours and 4 hours of overtime.
        var entries = (0..<3).map { index in
            TipEntry(date: at(2026, 10, 5 + index), amountCents: 1000, kind: .credit,
                     hoursWorked: 10, shiftPeriod: .dinner, shiftID: shiftID(index + 1))
        }
        let thursday = at(2026, 10, 8)
        entries.append(TipEntry(date: thursday, amountCents: 2000, kind: .credit, hoursWorked: 4,
                                shiftPeriod: .lunch, shiftID: shiftID(4)))
        entries.append(TipEntry(date: thursday.addingTimeInterval(3600), amountCents: 3000, kind: .credit,
                                hoursWorked: 8, shiftPeriod: .dinner, shiftID: shiftID(5)))

        // The sheet only ever sees ONE day's entries.
        let thursdayEntries = entries.filter { payrollCalendar().isDate($0.date, inSameDayAs: thursday) }
        let facts = dayFacts(entries: thursdayEntries, wageCentsPerHour: 283)

        #expect(facts.heroCents == facts.rowCents.reduce(0, +))
        #expect(facts.rowCents.count == 2)

        // CAVEAT, and it is why PR 5 exists: the sheet hands the ledger one
        // DAY, so the threshold is split over Thursday's 12 hours alone and
        // no overtime appears at all. 12h at 283c is 3396c straight time.
        #expect(facts.wagesByShiftID.values.reduce(0, +) == 3396)
        #expect(facts.wagesByShiftID[shiftID(4)] == 1132)
        #expect(facts.wagesByShiftID[shiftID(5)] == 2264)

        // Handed the whole week, the same Thursday pair is 1132 + 2547: the
        // dinner shift carries 2 hours at 1.5x. The day sheet is 283c short
        // of the truth, and that gap is PR 5's, not a rounding disagreement.
        let weekShifts = ShiftDays.groupedByShift(
            entries, shiftID: \.shiftID, date: \.date, period: \.shiftPeriod, calendar: payrollCalendar()
        )
        let weekWages = WageEstimate.centsByShiftID(
            payrollTimeZone: PaydayTestZone.payroll,
            workweekStartWeekday: 2,
            shifts: weekShifts,
            wageCentsPerHour: 283
        )
        #expect(weekWages[shiftID(4)] == 1132)
        #expect(weekWages[shiftID(5)] == 2547)
    }

    @Test("with no rate set no wage is fabricated, and the rows still sum to the hero")
    func noRateReconciles() {
        let day = at(2026, 9, 28)
        let entries = [
            TipEntry(date: day, amountCents: 6000, kind: .cash, hoursWorked: 5, tipOutCents: 1000,
                     shiftID: shiftID(1)),
            TipEntry(date: day.addingTimeInterval(3600), amountCents: 4000, kind: .credit, hoursWorked: 5,
                     shiftID: shiftID(2))
        ]
        let facts = dayFacts(entries: entries, wageCentsPerHour: nil)
        #expect(facts.wagesByShiftID.values.allSatisfy { $0 == 0 })
        #expect(facts.heroCents == facts.rowCents.reduce(0, +))
        #expect(facts.heroCents == 9000)
    }

    @Test("a shift with no hours logged contributes nothing, and the day still reconciles")
    func missingHoursReconciles() {
        let day = at(2026, 9, 28)
        let entries = [
            TipEntry(date: day, amountCents: 5000, kind: .credit, hoursWorked: 4.25,
                     shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: day.addingTimeInterval(3600), amountCents: 6000, kind: .credit,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let facts = dayFacts(entries: entries, wageCentsPerHour: 283)
        #expect(facts.wagesByShiftID[shiftID(1)] == 1203)
        #expect(facts.wagesByShiftID[shiftID(2)] == 0)
        #expect(facts.heroCents == facts.rowCents.reduce(0, +))
    }
}

/// Definition of Done #5, last clause: **a month equals the sum of its
/// days.** It does NOT hold yet, and this suite is where that debt is
/// measured rather than assumed.
///
/// `CalendarMonthFacts` computes its header from `PeriodIncome.wages` over
/// the whole month and its tiles from `WageEstimate.centsSummedPerShift`
/// called once per day (`CalendarView.swift:49`, one `Dictionary(grouping:
/// by: \.day)` bucket at a time). The ledger always splits the overtime
/// threshold over the COMPLETE workweek of the shifts it is handed, so a
/// month gets the overtime and a single day never can. The divergence is
/// pre-existing on `production` and consumer migration is explicitly PR 5;
/// what PR 3 owed was the measurement, which is here.
///
/// The parity assertion itself is wrapped in `withKnownIssue`, so it is
/// recorded as a known issue today and FAILS the build the moment PR 5 makes
/// it true — `withKnownIssue` reports `knownIssueNotRecorded` when its body
/// passes. Delete the wrapper in the PR that closes it.
@Suite("A month equals the sum of its days — open, PR 5")
struct MonthEqualsSumOfItsDaysTests {
    /// W2's 48-hour week, moved wholly inside October 2026 (Mon 2026-10-05
    /// through Fri 2026-10-09) so nothing is lost to the month boundary and
    /// the only thing left to lose is the per-day slicing itself.
    private func octoberFacts() -> CalendarMonthFacts {
        let calendar = payrollCalendar()
        let minutes = [615.0, 585, 630, 690, 360]
        let entries = minutes.enumerated().map { index, m in
            TipEntry(
                date: at(2026, 10, 5 + index),
                amountCents: 1000,
                kind: .credit,
                hoursWorked: m / 60,
                shiftPeriod: .dinner,
                shiftID: shiftID(index + 1)
            )
        }
        return CalendarMonthFacts(
            allEntries: entries,
            displayedMonth: calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!,
            calendar: calendar,
            wageCentsPerHour: 283,
            firstWeekday: 2,
            payrollTimeZone: PaydayTestZone.payroll
        )
    }

    @Test("MEASURED: the month header carries W2's 14716 of wages while its five tiles carry 13585")
    func headerAndTilesDisagreeByTheOvertime() {
        let facts = octoberFacts()
        let tips = 5 * 1000

        // The header: one ledger pass over the whole month, so the week's
        // 8 hours past 40 pay 1.5x. 11320 regular + 3396 overtime.
        #expect(facts.monthTotalCents == tips + 14716)

        // The tiles: five independent one-day passes, every hour at the base
        // rate. 2901 + 2759 + 2972 + 3255 + 1698.
        let tileTotal = facts.monthDailyTotals.reduce(0) { $0 + $1.cents }
        #expect(tileTotal == tips + 13585)
        #expect(facts.monthDailyTotals.map(\.cents).sorted() == [1000 + 1698, 1000 + 2759, 1000 + 2901, 1000 + 2972, 1000 + 3255])

        // 1131c apart on one screen, which is exactly W2's lost overtime.
        #expect(facts.monthTotalCents - tileTotal == 1131)

        // The chart bars and the y-axis maximum are built from the same
        // per-day values, so they disagree with the header too.
        #expect(facts.displayedMonthMaxCents == 1000 + 3255)
        #expect(facts.displayedMonthMaxCents < facts.monthTotalCents)
    }

    @Test("a month equals the sum of its days")
    func monthEqualsSumOfItsDays() {
        withKnownIssue("Definition of Done #5: CalendarView slices the ledger per day (CalendarView.swift:49), so a week's overtime never reaches a tile. Closes in PR 5, when every consumer reads EarningsSnapshot over the whole dataset. Delete this wrapper then.") {
            let facts = octoberFacts()
            let tileTotal = facts.monthDailyTotals.reduce(0) { $0 + $1.cents }
            #expect(facts.monthTotalCents == tileTotal)
        }
    }

    /// The single-shift-per-day case, which is what the calendar usually
    /// shows, is byte-identical to the old behaviour: with one shift in the
    /// bucket there is nothing for a cumulative allocation to do. Stated as a
    /// test so nobody claims the tiles changed for every day.
    @Test("a one-shift day's tile is unchanged by the ledger: one shift is its own naive rounding")
    func singleShiftTilesAreUnchanged() {
        let facts = octoberFacts()
        let naive = [615.0, 585, 630, 690, 360].map {
            WageEstimate.cents(wageCentsPerHour: 283, hours: $0 / 60) ?? 0
        }
        #expect(naive == [2901, 2759, 2972, 3255, 1698])
        #expect(facts.monthDailyTotals.map(\.cents).sorted() == naive.map { $0 + 1000 }.sorted())
    }
}
