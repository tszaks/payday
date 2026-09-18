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

/// Σ of the figures the rows actually rendered. A row whose figure is
/// `.unavailable` contributes nothing and is visible as a `nil` in the array,
/// so a hero that matched a silently-zeroed row would still fail the count
/// assertions next to this one.
private func rowSum(_ rows: [Int?]) -> Int {
    rows.compactMap { $0 }.reduce(0, +)
}

/// The compensation policies these suites value with, as `PolicyStore` would
/// hold them: a real effective-dated history, never a scalar rate and never a
/// scalar weekday. A scalar rate becomes a `.distantPast` `.confirmed` policy
/// that reprices every pre-raise shift at today's rate, and a scalar weekday
/// re-buckets overtime into a week the engine never chose.
private func parityPolicies(
    rateCents: Int?,
    workweekStartWeekday: Int = 2,
    rateEffectiveFrom: CivilDay = .distantPast
) -> CompensationPolicies {
    let calendar = PayrollCalendarPolicy(
        id: PolicyMigration.deterministicID("parity/calendar/\(workweekStartWeekday)"),
        effectiveFrom: .distantPast,
        workweekStartWeekday: workweekStartWeekday,
        payrollTimeZone: PaydayTestZone.payroll
    )
    guard let rateCents else { return CompensationPolicies(rates: [], calendars: [calendar]) }
    return CompensationPolicies(
        rates: [PayRatePolicy(
            id: PolicyMigration.deterministicID("parity/rate/\(rateCents)"),
            effectiveFrom: rateEffectiveFrom,
            hourlyRateCents: rateCents,
            provenance: .confirmed
        )],
        calendars: [calendar]
    )
}

/// Definition of Done #5, first clause: **a day equals the sum of that day's
/// shifts.**
///
/// Measured on the REAL adapter. Until PR 5 wave 1 these tests re-implemented
/// `DayDetailFacts`'s arithmetic in a local helper ("exactly what
/// DayDetailFacts does, in the same order"), which pins the helper and not the
/// screen — the failure mode the whole plan exists to remove. `DayDetailFacts`
/// is now internal and these suites construct it.
///
/// The invariant is no longer an equality the screen has to maintain; it is an
/// identity. `DayDetailFacts.total` is `snapshot.day(thatDay)` and
/// `DayDetailFacts.shifts` is that same result's `shiftIDs`, so the hero and
/// the rows name one selection of one allocation.
///
/// This is the invariant PR 3's first cut broke: the hero moved onto the
/// ledger's cumulative per-week allocation while each row kept calling
/// `WageEstimate.cents(wageCentsPerHour:hours:)`, which rounds every shift
/// independently. W1's two shifts on one day then read 2759 in the hero and
/// 1203 + 1557 = 2760 in the rows directly beneath it. A screen was a cent
/// apart from itself.
@Suite("A day's hero equals the sum of the shift rows it lists")
struct DayHeroEqualsItsRowsTests {
    /// The real screen adapter, plus what the rows under it render.
    private func dayFacts(
        entries: [TipEntry],
        date: Date,
        rateCents: Int?,
        workweekStartWeekday: Int = 2
    ) -> (facts: DayDetailFacts, heroCents: Int?, rowCents: [Int?], wagesByShiftID: [UUID: Int]) {
        let facts = DayDetailFacts(
            allEntries: entries,
            date: date,
            policies: parityPolicies(rateCents: rateCents, workweekStartWeekday: workweekStartWeekday),
            payrollTimeZone: PaydayTestZone.payroll
        )
        let rows = facts.shifts.map { group in
            facts.rowFacts(for: group, shiftCount: facts.shifts.count, note: nil).amount.cents
        }
        let wages = Dictionary(
            facts.shifts.map { ($0.shiftID, facts.snapshot?.valuation($0.shiftID)?.components.wagesCents ?? 0) },
            uniquingKeysWith: +
        )
        return (facts, facts.total.cents, rows, wages)
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
        let facts = dayFacts(entries: entries, date: day, rateCents: 283)

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
        #expect(facts.heroCents == rowSum(facts.rowCents))
        #expect(facts.heroCents == 5000 + 6000 + 2759)
        // A complete day may be called a total. The label is the figure's.
        #expect(facts.facts.total.label == "Total")
    }

    @Test("a day whose shifts straddle the weekly threshold now CARRIES the week's overtime")
    func straddlingDayReconciles() {
        // Mon-Wed 10h each puts 30 hours on the clock; Thursday's lunch and
        // dinner then split the last 10 regular hours and 2 hours of overtime.
        var entries = (0..<3).map { index in
            TipEntry(date: at(2026, 10, 5 + index), amountCents: 1000, kind: .credit,
                     hoursWorked: 10, shiftPeriod: .dinner, shiftID: shiftID(index + 1))
        }
        let thursday = at(2026, 10, 8)
        entries.append(TipEntry(date: thursday, amountCents: 2000, kind: .credit, hoursWorked: 4,
                                shiftPeriod: .lunch, shiftID: shiftID(4)))
        entries.append(TipEntry(date: thursday.addingTimeInterval(3600), amountCents: 3000, kind: .credit,
                                hoursWorked: 8, shiftPeriod: .dinner, shiftID: shiftID(5)))

        // THE FIX. The sheet is handed the whole dataset and asks the engine
        // for one DAY out of it, so the week is allocated as a week: the
        // dinner shift carries 2 hours at 1.5x. Before PR 5 wave 1 this sheet
        // built a snapshot from one day's entries, the threshold was split
        // over Thursday's 12 hours alone, and no overtime appeared at all.
        let facts = dayFacts(entries: entries, date: thursday, rateCents: 283)
        #expect(facts.rowCents.count == 2)
        #expect(facts.wagesByShiftID[shiftID(4)] == 1132)
        #expect(facts.wagesByShiftID[shiftID(5)] == 2547)
        #expect(facts.wagesByShiftID.values.reduce(0, +) == 3679)
        #expect(facts.wagesByShiftID.values.reduce(0, +) != 3396, "the superseded day-scoped allocation")

        #expect(facts.rowCents == [2000 + 1132, 3000 + 2547])
        #expect(facts.heroCents == rowSum(facts.rowCents))
        #expect(facts.heroCents == 2000 + 3000 + 3679)

        // The same numbers the pre-PR-5 helper produced for the whole week,
        // which is the point: the sheet is no longer 283c short of the truth.
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
        let facts = dayFacts(entries: entries, date: day, rateCents: nil)
        #expect(facts.wagesByShiftID.values.allSatisfy { $0 == 0 })
        #expect(facts.heroCents == rowSum(facts.rowCents))
        #expect(facts.heroCents == 9000)
        // Wages off means the figure IS non-wage earnings, so it takes a
        // non-wage label. "Total" here would name a different metric from the
        // number under it.
        #expect(facts.facts.total.label == "Tips")
        #expect(facts.facts.total.metric == .nonWageEarnings)
    }

    @Test("a shift with no hours logged contributes nothing, the day still reconciles, and it is never called a total")
    func missingHoursReconciles() {
        let day = at(2026, 9, 28)
        let entries = [
            TipEntry(date: day, amountCents: 5000, kind: .credit, hoursWorked: 4.25,
                     shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: day.addingTimeInterval(3600), amountCents: 6000, kind: .credit,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let facts = dayFacts(entries: entries, date: day, rateCents: 283)
        #expect(facts.wagesByShiftID[shiftID(1)] == 1203)
        #expect(facts.wagesByShiftID[shiftID(2)] == 0)
        #expect(facts.heroCents == rowSum(facts.rowCents))
        // The audit's headline defect, now unspellable: a day whose wage
        // picture has a hole says so instead of printing a total.
        #expect(facts.facts.total.label == "Known so far")
        #expect(facts.facts.total.mayBeCalledATotal == false)
        #expect(facts.facts.total.caption == "wages missing for 1 shift")
    }
}

/// Definition of Done #5, last clause: **a month equals the sum of its days.**
///
/// CLOSED by PR 5 wave 1, group 2.2 (2026-09-18). The `withKnownIssue` wrapper
/// that used to live in this suite is deleted, and `monthEqualsSumOfItsDays`
/// asserts for real.
///
/// What it took: `CalendarMonthFacts` no longer computes anything. It takes one
/// whole-dataset `EarningsSnapshot` and asks it twice — `range(month)` for the
/// headline, `days(in: month)` for the tiles — so both sides select out of the
/// same per-shift valuations, each allocated over its COMPLETE workweek. The
/// old shape sliced the ledger per day for the tiles
/// (`WageEstimate.centsSummedPerShift`, one `Dictionary(grouping: by: \.day)`
/// bucket at a time) while the headline went through `PeriodIncome.wages` over
/// the month's entries, so a month got the week's overtime and a single day
/// never could: 19716 against 18585, 1131c apart on one screen.
@Suite("A month equals the sum of its days")
struct MonthEqualsSumOfItsDaysTests {
    /// W2's 48-hour week, moved wholly inside October 2026 (Mon 2026-10-05
    /// through Fri 2026-10-09) so nothing is lost to the month boundary and
    /// the only thing left to lose is the per-day slicing itself.
    static let w2Minutes: [Double] = [615, 585, 630, 690, 360]

    static func w2Entries() -> [TipEntry] {
        w2Minutes.enumerated().map { index, m in
            TipEntry(
                date: at(2026, 10, 5 + index),
                amountCents: 1000,
                kind: .credit,
                hoursWorked: m / 60,
                shiftPeriod: .dinner,
                shiftID: shiftID(index + 1)
            )
        }
    }

    /// The real adapter, fed the way `CalendarView` feeds it.
    static func monthFacts(
        entries: [TipEntry],
        month: (year: Int, month: Int),
        rateCents: Int?,
        workweekStartWeekday: Int = 2,
        rateEffectiveFrom: CivilDay = .distantPast
    ) -> CalendarMonthFacts {
        let calendar = payrollCalendar(firstWeekday: workweekStartWeekday)
        return CalendarMonthFacts(
            snapshot: CalendarEarnings.snapshot(
                shifts: CalendarEarnings.shiftGroups(
                    entries: entries,
                    payrollTimeZone: PaydayTestZone.payroll
                ),
                policies: parityPolicies(
                    rateCents: rateCents,
                    workweekStartWeekday: workweekStartWeekday,
                    rateEffectiveFrom: rateEffectiveFrom
                ),
                payrollTimeZone: PaydayTestZone.payroll
            ),
            displayedMonth: calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1))!,
            calendar: calendar
        )
    }

    private func octoberFacts() -> CalendarMonthFacts {
        Self.monthFacts(entries: Self.w2Entries(), month: (2026, 10), rateCents: 283)
    }

    @Test("MEASURED: the month header and its five tiles are now one answer, 19716, and the 1131c gap is gone")
    func headerAndTilesAgree() {
        let facts = octoberFacts()
        let tips = 5 * 1000

        // The header: one ledger pass over the whole dataset, so the week's
        // 8 hours past 40 pay 1.5x. 11320 regular + 3396 overtime.
        #expect(facts.monthFigure.cents == tips + 14716)

        // The tiles: the same allocation, selected per day. They now carry
        // the overtime they always earned.
        let tileTotal: Int = facts.tiles.compactMap(\.figure.cents).reduce(0, +)
        #expect(tileTotal == tips + 14716)
        #expect(tileTotal != tips + 13585, "the superseded per-day ledger slicing")
        #expect(facts.monthFigure.cents == tileTotal)

        // The heat ramp's normalizer is one of the tiles' own figures, so the
        // grid's brightest day is a day the header agrees with.
        let brightest: Int? = facts.tiles.compactMap(\.figure.cents).max()
        #expect(facts.brightestTileCents == brightest)
    }

    @Test("a month equals the sum of its days")
    func monthEqualsSumOfItsDays() {
        let facts = octoberFacts()
        let tileTotal: Int = facts.tiles.compactMap(\.figure.cents).reduce(0, +)
        #expect(facts.monthFigure.cents == tileTotal)
    }

    @Test("MEASURED: the per-day tiles, and the naive per-shift rounding they replaced")
    func perDayTilesCarryTheWeeksOvertime() {
        let facts = octoberFacts()
        let naive: [Int] = Self.w2Minutes.map { WageEstimate.cents(wageCentsPerHour: 283, hours: $0 / 60) ?? 0 }
        #expect(naive == [2901, 2759, 2972, 3255, 1698])
        let tiles: [Int] = facts.tiles.compactMap(\.figure.cents).filter { $0 > 0 }.sorted()
        // MEASURED 2026-09-18 on the real adapter. Each tile is 1000 of tips
        // plus that day's slice of the week's allocation:
        //   Mon 615m  2901  (cumulative 615m,  all regular)
        //   Tue 585m  2759  (cumulative 1200m, all regular)
        //   Wed 630m  2972  (cumulative 1830m, all regular)
        //   Thu 690m  3537  (crosses 2400m: 570m regular + 120m at 1.5x)
        //   Fri 360m  2547  (cumulative 2880m, all overtime)
        #expect(tiles == [3547, 3759, 3901, 3972, 4537])
        // And it lands on the DAYS that earned it, which a spread-evenly
        // allocation would also sum correctly and still be wrong about.
        let calendar = payrollCalendar()
        let byDay = (5...9).map { facts.tile(on: calendar.date(from: DateComponents(year: 2026, month: 10, day: $0))!)?.figure.cents }
        #expect(byDay == [3901, 3759, 3972, 4537, 3547])
        // Every tile is a day's whole earnings, so the difference from the
        // naive base-rate sum is exactly the week's overtime.
        let tileSum: Int = tiles.reduce(0, +)
        let naiveSum: Int = naive.reduce(0, +) + 5000
        #expect(tileSum - naiveSum == 1131)
    }

    @Test("a month nobody worked is an empty month, and a month nothing is known about is not")
    func emptyAndUnbackedMonthsDiffer() {
        let empty = Self.monthFacts(entries: [], month: (2026, 10), rateCents: 283)
        #expect(empty.isUnbacked == false)
        #expect(empty.daysWorkedCount == 0)
        #expect(empty.hasAnythingLogged == false)
        #expect(empty.monthFigure.cents == 0)
        #expect(empty.tiles.count == 31)

        // Rule 4: a read that produced no dataset renders no currency at all,
        // and it must not be mistaken for a month nobody worked.
        let unbacked = CalendarMonthFacts(
            snapshot: nil,
            displayedMonth: payrollCalendar().date(from: DateComponents(year: 2026, month: 10, day: 1))!,
            calendar: payrollCalendar()
        )
        #expect(unbacked.isUnbacked)
        #expect(unbacked.monthFigure.isUnavailable)
        #expect(unbacked.monthFigure.text == nil)
        #expect(unbacked.monthFigure.cents == nil)
        #expect(unbacked.tiles.isEmpty)
        #expect(unbacked.hasAnythingLogged == false)
        #expect(unbacked.monthCaption == "this month")
        // The grid still draws: a failed money read is not a missing month.
        #expect(unbacked.gridDays.count == 35)
    }
}

/// Definition of Done #5, and the rule the whole goal is measured against:
/// "the same metric, date scope, cutoff, source revision, **compensation
/// policy**, and engine version must return the same integer-cents result on
/// every consumer." Within one screen, that means the hero and the rows
/// beneath it must bucket overtime by the SAME workweek.
///
/// This is the trap PR 5 wave 0's first cut walked into. Payday has two
/// independent weekday controls in the same Settings screen, and they never
/// write each other:
///
/// - Settings > "First day" writes `PaySchedule.firstWeekday`, the pay-period
///   GRID's weekday (SettingsView.swift:249).
/// - Settings > Payroll > "Workweek starts" writes
///   `PayrollCalendarPolicy.workweekStartWeekday`, which is what actually owns
///   overtime (PayrollSettingsSection.swift:96). PR 3 severed the two on
///   purpose.
///
/// Wave 0 moved the shift ROWS onto `EarningsSnapshot`, which buckets by the
/// policy, while the hero stayed on `PeriodIncome`, which was handed the
/// grid's weekday. Set the two controls differently and one screen answered
/// two different overtime allocations over the same shifts.
@Suite("A screen's hero and its rows bucket overtime by one workweek")
struct OneWorkweekPerScreenTests {
    /// Five 10-hour days, Sunday 2026-09-27 through Thursday 2026-10-01, at
    /// $10.00/hr. The bucketing is the whole point:
    ///
    /// - **Monday-start (2):** Sun 9/27 sits alone in the week of Mon 9/21
    ///   (10h), and Mon–Thu fill the week of Mon 9/28 to exactly 40h. No
    ///   overtime anywhere: 50h x $10 = $500.00.
    /// - **Sunday-start (1):** all five days are one week of 50h, so 10h
    ///   cross the threshold: 40 x $10 + 10 x $15 = $550.00.
    ///
    /// A $50.00 gap, which is what makes the disagreement legible rather than
    /// a rounding cent.
    private func entries() -> [TipEntry] {
        [
            (2026, 9, 27, 1), (2026, 9, 28, 2), (2026, 9, 29, 3),
            (2026, 9, 30, 4), (2026, 10, 1, 5)
        ].map { year, month, day, index in
            TipEntry(
                date: at(year, month, day),
                amountCents: 1_000,
                kind: .credit,
                hoursWorked: 10,
                shiftID: shiftID(index)
            )
        }
    }

    /// The user's real history: overtime is bucketed Sunday-start.
    private func sundayStartPolicies() -> CompensationPolicies {
        CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("parity/rate/1000"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 1_000,
                provenance: .confirmed
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("parity/calendar/1"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 1,
                payrollTimeZone: PaydayTestZone.payroll
            )]
        )
    }

    @Test("Period detail: the hero's wages are exactly the sum of its rows' wages, with the grid weekday set against the policy")
    func periodDetailHeroEqualsItsRows() throws {
        let period = PayPeriod(start: at(2026, 9, 27, hour: 0), end: at(2026, 10, 10, hour: 23))
        // The GRID says Monday. The POLICY says Sunday. Only the policy owns
        // overtime, so every wage figure on this screen must read 55000.
        let schedule = PaySchedule(
            frequency: .biweekly,
            anchorPeriodEnd: at(2026, 10, 10, hour: 0),
            firstWeekday: 2
        )
        let facts = PeriodDetailFacts(
            allEntries: entries(),
            paycheckRecords: [],
            period: period,
            schedule: schedule,
            wageCentsPerHour: 1_000,
            policies: sundayStartPolicies(),
            payrollTimeZone: PaydayTestZone.payroll,
            calendar: payrollCalendar()
        )

        let rowWages = facts.wagesByShiftID.values.reduce(0, +)
        // 40h regular + 10h at 1.5x, because the POLICY buckets Sunday-start.
        #expect(rowWages == 55_000)
        #expect(facts.wages?.totalCents == 55_000)
        // The invariant: the hero's wage figure IS the sum of the row
        // figures. Before the workweek was unified this read 50000 against
        // 55000 — one screen, two overtime allocations, $50.00 apart.
        #expect(facts.wages?.totalCents == rowWages)
        #expect(facts.wages?.totalCents != 50_000, "the superseded grid-weekday allocation")
    }
}
