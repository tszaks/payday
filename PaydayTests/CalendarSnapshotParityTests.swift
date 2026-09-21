import Testing
import Foundation
@testable import Payday

/// A gregorian calendar in the frozen payroll zone, week starting Monday
/// unless a test says otherwise. The grid's weekday is LAYOUT only; the
/// workweek that owns overtime lives on the payroll calendar policy.
private func calendarInPayrollZone(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    calendar.firstWeekday = firstWeekday
    return calendar
}

private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
    calendarInPayrollZone().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func id(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
}

/// The user's own effective-dated history. Never a scalar rate, never a
/// scalar weekday: a scalar rate becomes a `.distantPast` `.confirmed` policy
/// that reprices every pre-raise shift at today's rate, and a scalar weekday
/// re-buckets overtime into a week the engine never chose.
private func policies(
    rateCents: Int?,
    workweekStartWeekday: Int = 2,
    rateEffectiveFrom: CivilDay = .distantPast,
    provenance: RateProvenance = .confirmed
) -> CompensationPolicies {
    let calendar = PayrollCalendarPolicy(
        id: PolicyMigration.deterministicID("cal-parity/calendar/\(workweekStartWeekday)"),
        effectiveFrom: .distantPast,
        workweekStartWeekday: workweekStartWeekday,
        payrollTimeZone: PaydayTestZone.payroll
    )
    guard let rateCents else { return CompensationPolicies(rates: [], calendars: [calendar]) }
    return CompensationPolicies(
        rates: [PayRatePolicy(
            id: PolicyMigration.deterministicID("cal-parity/rate/\(rateCents)"),
            effectiveFrom: rateEffectiveFrom,
            hourlyRateCents: rateCents,
            provenance: provenance
        )],
        calendars: [calendar]
    )
}

/// One snapshot, built exactly as both Calendar surfaces build it.
@MainActor
private func snapshot(records: [ShiftRecord], policies: CompensationPolicies) -> EarningsSnapshot? {
    CalendarEarnings.snapshot(
        records: records,
        policies: policies,
        payrollTimeZone: PaydayTestZone.payroll
    )
}

/// Definition of Done #5, the Calendar clause in full: **calendar day == day
/// detail == the sum of that day's shifts == the chart point for the same
/// metric**, and **a month == the sum of its days**.
///
/// Every figure here comes from a REAL adapter — `CalendarMonthFacts`,
/// `DayDetailFacts`, `EarningsChartFacts` — over one whole-dataset snapshot.
/// Nothing in this file re-implements a screen's arithmetic, because a test
/// that does that pins its own helper.
///
/// The case is deliberately a week that crosses the overtime threshold AND a
/// month boundary, because that is the shape every superseded path got wrong:
/// a per-day ledger slice carries no week overtime at all, and a per-month one
/// splits the week into two fragments and allocates the threshold twice.
@Suite("Calendar parity: tile == sheet == Σ shifts == chart point")
@MainActor
struct CalendarSnapshotParityTests {
    /// Mon 2026-09-28 through Fri 2026-10-02, 10h a day, $10.00/hr, workweek
    /// starting Monday. 50 hours in ONE week that straddles the month edge:
    /// 40h regular ($400) plus 10h at 1.5x ($150) is $550.00, and Friday
    /// 10/02 is the day carrying all ten overtime hours.
    private func straddlingWeek() -> [ShiftRecord] {
        (0..<5).map { index in
            ShiftRecord(
                id: id(index + 1),
                workDate: calendarInPayrollZone().date(
                    byAdding: .day, value: index, to: day(2026, 9, 28)
                )!,
                shiftPeriod: .dinner,
                creditTipsCents: 1_000,
                hoursWorked: 10
            )
        }
    }

    @Test("the tile, the day sheet's hero, that day's rows and the chart point are one figure")
    func fourSurfacesAgreeOnOneDay() throws {
        let records = straddlingWeek()
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        let friday = day(2026, 10, 2)

        // 1. The calendar tile.
        let month = CalendarMonthFacts(
            snapshot: engine,
            displayedMonth: day(2026, 10, 1),
            calendar: calendarInPayrollZone()
        )
        let tile = try #require(month.tile(on: friday))

        // 2. The sheet that tile opens.
        let sheet = DayDetailFacts(
            shiftRecords: records,
            date: friday,
            policies: policies(rateCents: 1_000),
            payrollTimeZone: PaydayTestZone.payroll
        )

        // 3. The rows the sheet lists.
        let rows = sheet.shiftRecords.map { record in
            sheet.rowFacts(
                shiftID: record.id, day: record.workDate,
                period: record.shiftPeriod,
                shiftCount: sheet.shiftRecords.count, note: record.note
            ).amount.cents
        }

        // 4. The chart point for the same day, from the shared component.
        let chart = EarningsChartFacts(
            snapshot: engine,
            range: DayRange(
                start: CivilDay(day(2026, 9, 28), in: PaydayTestZone.payroll),
                end: CivilDay(friday, in: PaydayTestZone.payroll)
            ),
            timeZone: PaydayTestZone.payroll
        )
        #expect(chart.granularity == .day)
        let point = try #require(chart.points.first { $0.range.start == tile.civilDay })

        // Friday is 10h of which every hour is past 40: 10 x 1500 = 15000,
        // plus its own 1000 of tips.
        #expect(tile.figure.cents == 16_000)
        #expect(sheet.total.cents == 16_000)
        #expect(rows == [16_000])
        #expect(point.cents == 16_000)

        // Stated as identities rather than as four numbers that happen to
        // match, so a future divergence cannot hide behind a literal.
        #expect(sheet.total.cents == tile.figure.cents)
        let rowSum: Int = rows.compactMap { $0 }.reduce(0, +)
        #expect(rowSum == sheet.total.cents)
        #expect(point.cents == tile.figure.cents)
        // Same dataset, by construction: one stamp behind all of it.
        #expect(month.stamp?.digest == sheet.stamp?.digest)
        #expect(chart.stamp?.digest == month.stamp?.digest)
        #expect(point.result.manifestDigest == engine.stamp.digest)
    }

    @Test("MEASURED: the straddling week's overtime lands on the right DAY, not spread and not lost")
    func overtimeLandsOnTheDayThatEarnedIt() throws {
        let records = straddlingWeek()
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        let september = CalendarMonthFacts(
            snapshot: engine, displayedMonth: day(2026, 9, 1), calendar: calendarInPayrollZone()
        )
        let october = CalendarMonthFacts(
            snapshot: engine, displayedMonth: day(2026, 10, 1), calendar: calendarInPayrollZone()
        )

        // Mon 9/28 through Thu 10/1 are the first 40 hours: $100 a day flat.
        let septemberTiles = september.tiles.compactMap(\.figure.cents).filter { $0 > 0 }
        #expect(septemberTiles == [11_000, 11_000, 11_000])
        // Thursday 10/1 is the 40th hour's day, still straight time.
        #expect(october.tile(on: day(2026, 10, 1))?.figure.cents == 11_000)
        // Friday 10/2 is the overtime day.
        #expect(october.tile(on: day(2026, 10, 2))?.figure.cents == 16_000)

        // The week as the engine allocated it: 5 x 1000 tips + 55000 wages.
        let wholeWeek = engine.range(DayRange(
            start: CivilDay(day(2026, 9, 28), in: PaydayTestZone.payroll),
            end: CivilDay(day(2026, 10, 2), in: PaydayTestZone.payroll)
        ))
        #expect(wholeWeek.knownComponents.wagesCents == 55_000)
        // And the two months' tiles partition it exactly, with nothing
        // double-allocated at the month edge — the defect a per-month ledger
        // pass produced, which priced each fragment's hours against its own
        // fresh 40-hour threshold and lost every overtime hour.
        let septemberSum: Int = septemberTiles.reduce(0, +)
        let octoberSum: Int = october.tiles.compactMap(\.figure.cents).reduce(0, +)
        let weekCents: Int = wholeWeek.knownComponents.earnedIncomeCents
        #expect(septemberSum + octoberSum == weekCents)
    }

    @Test("every month equals the sum of its own days, month by month")
    func eachMonthEqualsItsDays() throws {
        let records = straddlingWeek()
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        for (year, month) in [(2026, 9), (2026, 10), (2026, 11)] {
            let facts = CalendarMonthFacts(
                snapshot: engine,
                displayedMonth: day(year, month, 1),
                calendar: calendarInPayrollZone()
            )
            let tiles: Int = facts.tiles.compactMap(\.figure.cents).reduce(0, +)
            let header: Int? = facts.monthFigure.cents
            #expect(header == tiles, "\(year)-\(month) header against its own tiles")
        }
    }

    @Test("the grid's week start moves the layout and nothing else")
    func gridWeekdayIsLayoutOnly() throws {
        let records = straddlingWeek()
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        // Two grids over the same month and the same snapshot, differing only
        // in the Settings "First day" control. This is the control that used
        // to reach a money path and put Dashboard's overtime in a different
        // week than Insights'.
        let mondayGrid = CalendarMonthFacts(
            snapshot: engine, displayedMonth: day(2026, 10, 1), calendar: calendarInPayrollZone(firstWeekday: 2)
        )
        let sundayGrid = CalendarMonthFacts(
            snapshot: engine, displayedMonth: day(2026, 10, 1), calendar: calendarInPayrollZone(firstWeekday: 1)
        )
        #expect(mondayGrid.gridDays != sundayGrid.gridDays, "the layout does change")
        #expect(mondayGrid.monthFigure.cents == sundayGrid.monthFigure.cents)
        #expect(mondayGrid.tiles.compactMap(\.figure.cents) == sundayGrid.tiles.compactMap(\.figure.cents))
        #expect(mondayGrid.monthHoursLabel == sundayGrid.monthHoursLabel)
    }

    @Test("the month's hours come off the engine's own minute count")
    func hoursAreTheEnginesMinutes() throws {
        let records = straddlingWeek()
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        let october = CalendarMonthFacts(
            snapshot: engine, displayedMonth: day(2026, 10, 1), calendar: calendarInPayrollZone()
        )
        // Two 10-hour days fall in October.
        #expect(october.monthHoursLabel == WorkedMinutes.hoursLabel(minutes: 1_200))
        #expect(october.daysWorkedCount == 2)
    }

    @Test("a month with an unpriced shift reads Known so far, never Total, and says what is missing")
    func partialMonthIsNeverCalledATotal() throws {
        // Two shifts, one with hours logged and one without, so the engine can
        // price one of them and not the other. This is the audit's headline
        // defect in its original shape: the unpriced shift silently
        // contributed zero wages under an unchanged "Total".
        let records = [
            ShiftRecord(id: id(1), workDate: day(2026, 10, 5), shiftPeriod: .dinner,
                        creditTipsCents: 1_000, hoursWorked: 5),
            ShiftRecord(id: id(2), workDate: day(2026, 10, 6), shiftPeriod: .dinner,
                        creditTipsCents: 2_000)
        ]
        let facts = CalendarMonthFacts(
            snapshot: snapshot(records: records, policies: policies(rateCents: 1_000)),
            displayedMonth: day(2026, 10, 1),
            calendar: calendarInPayrollZone()
        )
        #expect(facts.monthFigure.label == "Known so far")
        #expect(facts.monthFigure.mayBeCalledATotal == false)
        #expect(facts.monthCaption == "known so far this month")
        #expect(facts.monthFigure.caption == "wages missing for 1 shift")
        // The figure is still the sum of its days, hole and all.
        let partialTiles: Int = facts.tiles.compactMap(\.figure.cents).reduce(0, +)
        #expect(facts.monthFigure.cents == partialTiles)
        #expect(facts.monthFigure.cents == 8_000)
    }

    @Test("an estimated rate carries its caption onto the month")
    func estimatedMonthCarriesItsCaption() throws {
        let records = straddlingWeek()
        let facts = CalendarMonthFacts(
            snapshot: snapshot(
                records: records,
                policies: policies(rateCents: 1_000, provenance: .assumedFromLegacySetting)
            ),
            displayedMonth: day(2026, 10, 1),
            calendar: calendarInPayrollZone()
        )
        #expect(facts.monthFigure.caption == "Wages estimated from your current rate")
        #expect(facts.monthFigure.label == "Total")
        #expect(facts.monthCaption == "this month")
    }

    @Test("a day sheet lists exactly the shifts the engine selected for that day")
    func sheetRowsAreTheDayResultsOwnShifts() throws {
        let records = straddlingWeek()
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        let friday = day(2026, 10, 2)
        let sheet = DayDetailFacts(
            shiftRecords: records,
            date: friday,
            policies: policies(rateCents: 1_000),
            payrollTimeZone: PaydayTestZone.payroll
        )
        let engineIDs = engine.day(CivilDay(friday, in: PaydayTestZone.payroll)).shiftIDs
        #expect(sheet.shiftRecords.map(\.id) == engineIDs)
        #expect(engineIDs == [id(5)])
        // And a day nobody worked lists nothing rather than zeroes.
        let quiet = DayDetailFacts(
            shiftRecords: records,
            date: day(2026, 10, 20),
            policies: policies(rateCents: 1_000),
            payrollTimeZone: PaydayTestZone.payroll
        )
        #expect(quiet.shiftRecords.isEmpty)
        #expect(quiet.isUnbacked == false)
    }

    @Test("a future-dated shift still reaches its tile and its month")
    func futureDatedShiftsStillRender() throws {
        // The calendar has never applied a to-date clamp, and `asOf` is
        // `.distantFuture` for exactly this reason: someone who logs
        // tomorrow's shift expects to see it tomorrow. The clamp has to be the
        // same for the headline and the tiles or the screen disagrees with
        // itself, which is why it lives in the stamp.
        let future = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
        let records = [
            ShiftRecord(id: id(9), workDate: future, shiftPeriod: .dinner,
                        creditTipsCents: 4_200, hoursWorked: 6)
        ]
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        let facts = CalendarMonthFacts(
            snapshot: engine,
            displayedMonth: future,
            calendar: calendarInPayrollZone()
        )
        #expect(facts.tile(on: future)?.figure.cents == 10_200)
        #expect(facts.monthFigure.cents == 10_200)
        let futureTiles: Int = facts.tiles.compactMap(\.figure.cents).reduce(0, +)
        #expect(facts.monthFigure.cents == futureTiles)
    }

    @Test("a worked day worth nothing is not announced as no shifts")
    func aZeroDayIsStillAWorkedDay() throws {
        let worked = day(2026, 10, 7)
        let records = [
            ShiftRecord(id: id(1), workDate: worked, shiftPeriod: .dinner)
        ]
        let facts = CalendarMonthFacts(
            snapshot: snapshot(records: records, policies: policies(rateCents: nil)),
            displayedMonth: day(2026, 10, 1),
            calendar: calendarInPayrollZone()
        )
        let tile = try #require(facts.tile(on: worked))
        #expect(tile.hasShifts)
        #expect(tile.figure.cents == 0)
        #expect(facts.daysWorkedCount == 1)
        // A neighbouring day genuinely has nothing.
        #expect(facts.tile(on: day(2026, 10, 8))?.hasShifts == false)
    }
    /// **The month drawer cannot disagree with the month face.**
    ///
    /// The Calendar hero was the only one without a breakdown drawer, so a
    /// person could see WHAT their month came to and never what it was made
    /// of. A drawer is a SECOND surface showing the same fact, and this
    /// project's claim is that two surfaces do not disagree -- so it gets
    /// the same treatment as every other pair rather than being trusted
    /// because it happens to read the same variable today.
    ///
    /// The reconciliation asserted is the one a person would do by hand:
    /// cash + credit + gratuity + wages - tipped out == the headline.
    @Test("the month drawer's rows reconcile to the month headline")
    func monthDrawerReconcilesToTheHeadline() throws {
        // A fixture WITH a tip-out, deliberately. `straddlingWeek()` has
        // none, and the first version of this test used it -- so dropping
        // the "Tipped out" row from the drawer changed nothing and the
        // mutation passed. A reconciliation over a figure with nothing to
        // subtract cannot detect a missing subtraction.
        let records = straddlingWeek().enumerated().map { index, record -> ShiftRecord in
            record.tipOutCents = 1_500          // $15 off every shift
            if index == 0 { record.creditTipsCents += 2_000 }   // and one uneven day
            return record
        }
        let engine = try #require(snapshot(
            records: records, policies: policies(rateCents: 1_000)))
        let month = CalendarMonthFacts(
            snapshot: engine,
            displayedMonth: day(2026, 10, 1),
            calendar: calendarInPayrollZone()
        )

        // The row list carries a SUBTOTAL ("Earned", gross before tip-out),
        // so summing every row double-counts it. The first version of this
        // test summed them all and reported 51000 against a correct 24000 --
        // the test was wrong about the shape, not the drawer about the money.
        //
        // The real reconciliation, and the one a person reads down the
        // drawer: the addends make the subtotal, and the subtotal minus the
        // tip-out is the headline.
        let byLabel = Dictionary(
            month.monthBreakdownRows.map { ($0.label, $0.cents ?? 0) },
            uniquingKeysWith: { a, _ in a })
        let subtotal = try #require(byLabel["Earned"], "no subtotal row")
        let tipOut = try #require(byLabel["Tipped out"], "no tip-out row -- the fixture must have one or this proves nothing")

        let addends = month.monthBreakdownRows
            .filter { $0.label != "Earned" && $0.label != "Tipped out" }
            .compactMap { $0.cents }
            .reduce(0, +)
        #expect(addends == subtotal,
                "cash + credit + gratuity + wages = \(addends), subtotal says \(subtotal)")
        #expect(tipOut < 0, "Tipped out must SUBTRACT, or the headline is gross")
        #expect(subtotal + tipOut == month.monthFigure.cents,
                "subtotal \(subtotal) + tipout \(tipOut) != headline \(month.monthFigure.cents ?? -1)")
        #expect(month.monthBreakdownTotal.cents == month.monthFigure.cents,
                "the drawer's bottom line and the face are one number or neither is trustworthy")
    }

    /// A failed read has nothing to explain, and must not offer to.
    @Test("an unavailable month offers no drawer")
    func anUnavailableMonthHasNoDrawer() {
        let month = CalendarMonthFacts(
            snapshot: nil,
            displayedMonth: day(2026, 10, 1),
            calendar: calendarInPayrollZone()
        )
        #expect(month.monthHasBreakdown == false)
        #expect(month.monthBreakdownRows.isEmpty)
    }

    /// **The month caption names the unpriced day, and names the RIGHT one.**
    ///
    /// `CompletenessCopyTests` covers the sentence. This covers the wiring:
    /// that `CalendarMonthFacts` finds the unpriced shift from the engine's
    /// own valuations over the month's range. A wrong range or an inverted
    /// filter would produce a confident, well-formed, wrong date.
    @Test("the month caption names the shift that is missing hours")
    func theMonthCaptionNamesTheUnpricedShift() throws {
        // Four priced days and one with NO hours, so the month is `.partial`
        // for exactly one reason and exactly one day.
        var records = straddlingWeek()
        records[3].hoursWorked = nil          // Thu 2026-10-01
        let engine = try #require(snapshot(
            records: records, policies: policies(rateCents: 1_000)))
        let month = CalendarMonthFacts(
            snapshot: engine,
            displayedMonth: day(2026, 10, 1),
            calendar: calendarInPayrollZone()
        )

        let caption = try #require(month.monthWagesCaption)
        #expect(caption.contains("Oct 1"), "expected the unpriced day named; got \(caption)")
        #expect(!caption.contains("1 shift"), "naming replaces counting; got \(caption)")
        // And it must not name a day that IS priced.
        #expect(!caption.contains("Oct 2"), "named a priced day; got \(caption)")
    }

    /// A fully priced month says nothing, rather than saying nothing is wrong.
    @Test("a complete month has no wages caption")
    func aCompleteMonthHasNoWagesCaption() throws {
        let engine = try #require(snapshot(
            records: straddlingWeek(), policies: policies(rateCents: 1_000)))
        let month = CalendarMonthFacts(
            snapshot: engine,
            displayedMonth: day(2026, 10, 1),
            calendar: calendarInPayrollZone()
        )
        #expect(month.monthWagesCaption == nil)
    }

}

/// The 2026-09-20 honesty pass on the month card: a day you have not lived
/// is styled and announced as future rather than as "no shifts", and the
/// card's one secondary money line is a windowed month-over-month
/// comparison, never a restated amount.
@Suite("Calendar honesty: full grid, future days, month delta")
@MainActor
struct CalendarHonestyTests {

    // MARK: grid shape

    @Test("the current month renders its full grid, future days included")
    func currentMonthKeepsFullGrid() {
        // September 2026 on a Monday-first grid: Aug 31 leads, Sep 30 ends,
        // Oct 1–4 trails — 35 cells. Today is Wednesday Sep 16; the days
        // after it are styled and announced as future by DayCell, but a
        // trimmed grid would hide that the rest of the month exists.
        let facts = CalendarMonthFacts(
            snapshot: nil,
            displayedMonth: day(2026, 9, 1),
            calendar: calendarInPayrollZone(),
            now: day(2026, 9, 16)
        )
        #expect(facts.gridDays.count == 35)
        #expect(
            facts.gridDays.last.map { CivilDay($0, in: PaydayTestZone.payroll) }
                == CivilDay(year: 2026, month: 10, day: 4),
            "the grid still runs through the month's trailing week"
        )
    }

    @Test("a past month renders its grid in full")
    func pastMonthKeepsFullGrid() {
        // August 2026 Monday-first: 5 leading days + 31 + 6 trailing = 42.
        let facts = CalendarMonthFacts(
            snapshot: nil,
            displayedMonth: day(2026, 8, 1),
            calendar: calendarInPayrollZone(),
            now: day(2026, 9, 16)
        )
        #expect(facts.gridDays.count == 42)
    }

    @Test("a future month renders its grid in full")
    func futureMonthKeepsFullGrid() {
        // October 2026, viewed from Sep 16. Trimming here would empty the
        // whole grid — the disagreeing case a naive rule gets wrong.
        let facts = CalendarMonthFacts(
            snapshot: nil,
            displayedMonth: day(2026, 10, 1),
            calendar: calendarInPayrollZone(),
            now: day(2026, 9, 16)
        )
        #expect(facts.gridDays.count == 35)
    }

    // MARK: future-day voice

    @Test("a future in-month day is announced as upcoming, never as no shifts")
    func futureDayIsUpcoming() {
        let label = DayCell.label(
            day: day(2026, 9, 25), tile: nil, isCurrentMonth: true, isFuture: true)
        #expect(label.contains("upcoming"), "got \(label)")
        #expect(!label.contains("no shifts"))
    }

    @Test("a future day with a logged shift still reads its amount")
    func futureWorkedDayReadsAmount() {
        let tile = CalendarDayTile(
            civilDay: CivilDay(year: 2026, month: 9, day: 25),
            day: day(2026, 9, 25),
            figure: EarningsFigure(
                metric: .earnedIncome, amount: .cents(4_200),
                label: "Total", caption: nil, completeness: .empty),
            hasShifts: true
        )
        #expect(
            DayCell.label(
                day: day(2026, 9, 25), tile: tile,
                isCurrentMonth: true, isFuture: true)
                == "September 25, $42.00 logged"
        )
    }

    @Test("a past day with nothing still reads no shifts")
    func pastDayStillNoShifts() {
        #expect(
            DayCell.label(
                day: day(2026, 9, 8), tile: nil,
                isCurrentMonth: true, isFuture: false)
                == "September 8, no shifts"
        )
    }

    // MARK: the month-over-month line

    /// Aug 10: $100 tips + 5h wages. Aug 25: $500 + 5h — AFTER the window.
    /// Sep 5: $312.34 + 5h. Every shift is alone in its workweek, so wages
    /// are 5h × $10 straight time on each.
    private func windowedMonthRecords() -> [ShiftRecord] {
        [
            ShiftRecord(id: id(1), workDate: day(2026, 8, 10), shiftPeriod: .dinner,
                        creditTipsCents: 10_000, hoursWorked: 5),
            ShiftRecord(id: id(2), workDate: day(2026, 8, 25), shiftPeriod: .dinner,
                        creditTipsCents: 50_000, hoursWorked: 5),
            ShiftRecord(id: id(3), workDate: day(2026, 9, 5), shiftPeriod: .dinner,
                        creditTipsCents: 31_234, hoursWorked: 5),
        ]
    }

    @Test("an in-progress month compares against the same window one month back")
    func inProgressDeltaUsesTheWindow() throws {
        let engine = try #require(snapshot(
            records: windowedMonthRecords(), policies: policies(rateCents: 1_000)))
        let facts = CalendarMonthFacts(
            snapshot: engine,
            displayedMonth: day(2026, 9, 1),
            calendar: calendarInPayrollZone(),
            now: day(2026, 9, 20)
        )
        let delta = try #require(facts.monthDelta)
        #expect(delta.windowLabel == "Aug 1–20")
        // Windowed: 36234 − 15000. Naive whole-August would count the Aug 25
        // shift too: 36234 − 70000 = −33766 — a decline the data never had.
        #expect(delta.cents == 21_234)
        #expect(delta.cents != -33_766, "counted Aug 21–31 against a 20-day month")
    }

    @Test("a completed month names the bare prior month")
    func completedDeltaNamesTheMonth() throws {
        let records = [
            ShiftRecord(id: id(1), workDate: day(2026, 7, 15), shiftPeriod: .dinner,
                        creditTipsCents: 20_000, hoursWorked: 5),
            ShiftRecord(id: id(2), workDate: day(2026, 8, 10), shiftPeriod: .dinner,
                        creditTipsCents: 10_000, hoursWorked: 5),
        ]
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        let facts = CalendarMonthFacts(
            snapshot: engine,
            displayedMonth: day(2026, 8, 1),
            calendar: calendarInPayrollZone(),
            now: day(2026, 9, 20)
        )
        let delta = try #require(facts.monthDelta)
        #expect(delta.windowLabel == "July")
        #expect(delta.cents == -10_000)
    }

    @Test("a first month has no comparison to make")
    func emptyPriorWindowSuppressesTheDelta() throws {
        let records = [
            ShiftRecord(id: id(1), workDate: day(2026, 9, 5), shiftPeriod: .dinner,
                        creditTipsCents: 10_000, hoursWorked: 5),
        ]
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        let facts = CalendarMonthFacts(
            snapshot: engine,
            displayedMonth: day(2026, 9, 1),
            calendar: calendarInPayrollZone(),
            now: day(2026, 9, 20)
        )
        #expect(facts.monthDelta == nil, "Aug 1–20 is empty — '↑ $150 vs nothing' would be a lie")
    }

    @Test("a partial month never enters a delta against a total")
    func partialMonthSuppressesTheDelta() throws {
        var records = windowedMonthRecords()
        records[2].hoursWorked = nil        // Sep 5 is unpriced → the month is partial
        let engine = try #require(snapshot(records: records, policies: policies(rateCents: 1_000)))
        let facts = CalendarMonthFacts(
            snapshot: engine,
            displayedMonth: day(2026, 9, 1),
            calendar: calendarInPayrollZone(),
            now: day(2026, 9, 20)
        )
        #expect(facts.monthFigure.mayBeCalledATotal == false)
        #expect(facts.monthDelta == nil)
    }

    @Test("a failed read has no delta")
    func unbackedMonthHasNoDelta() {
        let facts = CalendarMonthFacts(
            snapshot: nil,
            displayedMonth: day(2026, 9, 1),
            calendar: calendarInPayrollZone(),
            now: day(2026, 9, 20)
        )
        #expect(facts.monthDelta == nil)
    }
}
