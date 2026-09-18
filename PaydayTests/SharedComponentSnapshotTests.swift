import Testing
import Foundation
import SwiftData
@testable import Payday

// MARK: - Shared fixtures

private func payrollCalendar(firstWeekday: Int = 2) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    calendar.firstWeekday = firstWeekday
    return calendar
}

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17) -> Date {
    payrollCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

/// The compensation policies a test STATES as its own history.
///
/// `LegacySnapshotBridge` values with `PolicyStore.policies` — the user's
/// real, effective-dated rate and workweek history — rather than a scalar
/// rate it re-stamps as `.distantPast`. So a test has to say what that
/// history is, and this is the plain one: one confirmed rate that has always
/// been the rate, one Monday-start workweek in the payroll zone. Tests about
/// rate HISTORY build their own (see `LegacySnapshotBridgeTests`).
private func testPolicies(rateCents: Int? = 283, workweekStartWeekday: Int = 2) -> CompensationPolicies {
    let calendar = PayrollCalendarPolicy(
        id: PolicyMigration.deterministicID("test/calendar/\(workweekStartWeekday)"),
        effectiveFrom: .distantPast,
        workweekStartWeekday: workweekStartWeekday,
        payrollTimeZone: PaydayTestZone.payroll
    )
    guard let rateCents, rateCents > 0 else {
        return CompensationPolicies(rates: [], calendars: [calendar])
    }
    return CompensationPolicies(
        rates: [PayRatePolicy(
            id: PolicyMigration.deterministicID("test/rate/\(rateCents)"),
            effectiveFrom: .distantPast,
            hourlyRateCents: rateCents,
            provenance: .confirmed
        )],
        calendars: [calendar]
    )
}

private func shiftID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
}

private func groups(_ entries: [TipEntry], firstWeekday: Int = 2) -> [(day: Date, shiftID: UUID, items: [TipEntry])] {
    ShiftDays.groupedByShift(
        entries,
        shiftID: \.shiftID,
        date: \.date,
        period: \.shiftPeriod,
        calendar: payrollCalendar(firstWeekday: firstWeekday)
    )
}

/// W1: 4.25h lunch and 5.5h dinner on one Monday at $2.83, 5000c and 6000c
/// of credit tips. The week's wages are 2759, allocated 1203 to lunch and
/// 1556 to dinner. Independent per-shift rounding gives 1557 for the dinner
/// shift and 2760 for the pair, which is the wrong answer every one of these
/// tests is built to catch.
private func w1Entries() -> [TipEntry] {
    let day = at(2026, 9, 28)
    return [
        TipEntry(date: day, amountCents: 5000, kind: .credit, hoursWorked: 4.25,
                 shiftPeriod: .lunch, shiftID: shiftID(1)),
        TipEntry(date: day.addingTimeInterval(3600), amountCents: 6000, kind: .credit, hoursWorked: 5.5,
                 shiftPeriod: .dinner, shiftID: shiftID(2))
    ]
}

private func w1Snapshot(rateCents: Int? = 283) -> EarningsSnapshot {
    let snapshot = LegacySnapshotBridge.snapshot(
        shifts: groups(w1Entries()),
        policies: testPolicies(rateCents: rateCents),
        payrollTimeZone: PaydayTestZone.payroll,
        asOf: at(2026, 9, 30)
    )
    return try! #require(snapshot)
}

// MARK: - ShiftDayRow

/// [SC-01] The row's figure is the ledger's, and it is the ledger's by
/// construction rather than by agreement.
@Suite("ShiftDayRow reads its figure from the snapshot")
struct ShiftDayRowSnapshotTests {
    private func rowFacts(_ snapshot: EarningsSnapshot?, _ id: UUID) -> ShiftDayRowFacts {
        ShiftDayRowFacts(
            snapshot: snapshot,
            shiftID: id,
            day: at(2026, 9, 28),
            period: .dinner,
            dayHasMultipleShifts: true
        )
    }

    @Test("W1's dinner row is 6000 + 1556, the number only a workweek allocation produces")
    func w1RowsAreTheAllocation() throws {
        let snapshot = w1Snapshot()
        let lunch = rowFacts(snapshot, shiftID(1))
        let dinner = rowFacts(snapshot, shiftID(2))

        #expect(lunch.amount.cents == 5000 + 1203)
        #expect(dinner.amount.cents == 6000 + 1556)

        // The assertion that fails if the row ever computes its own wage:
        // 5.5h at 283c rounded ALONE is 1557, and the app still has that
        // function, so this is a live comparison and not a historical note.
        #expect(WageEstimate.cents(wageCentsPerHour: 283, hours: 5.5) == 1557)
        #expect(dinner.amount.cents != 6000 + 1557)

        // And the rows telescope to the week the ledger valued.
        let week = try #require(lunch.amount.cents).advanced(by: try #require(dinner.amount.cents))
        #expect(week == 5000 + 6000 + 2759)
        #expect(week != 5000 + 6000 + 2760, "the superseded per-shift rounding")
    }

    @Test("the row's figure IS the snapshot's answer for that shift, field for field")
    func theFigureIsTheSnapshotsAnswer() throws {
        let snapshot = w1Snapshot()
        let valuation = try #require(snapshot.valuation(shiftID(2)))
        let facts = rowFacts(snapshot, shiftID(2))
        // Not "equal to a number the snapshot also happens to report": the
        // row's cents are that valuation's components, and the row carries
        // the snapshot's stamp so two rows on two screens are provably
        // reading one dataset.
        #expect(facts.amount.cents == valuation.components.earnedIncomeCents)
        #expect(facts.stamp == snapshot.stamp)
    }

    @Test("a shift the snapshot does not hold renders no currency, never $0.00")
    func aMissingShiftRendersNoCurrency() {
        let facts = rowFacts(w1Snapshot(), shiftID(999))
        #expect(facts.amount.isUnavailable)
        #expect(facts.amount.text == nil)
        #expect((facts.amount.text ?? ShiftDayRow.unavailablePlaceholder) != Money.string(fromCents: 0))
    }

    @Test("no snapshot at all renders no currency either, and says so to VoiceOver")
    func noSnapshotRendersNoCurrency() {
        let facts = rowFacts(nil, shiftID(1))
        #expect(facts.isUnbacked)
        #expect(facts.amount.isUnavailable)
        #expect(facts.amount.text == nil)
    }

    @Test("a shift that genuinely earned nothing still prints a number")
    func arealZeroIsStillANumber() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 0, kind: .cash, shiftID: shiftID(7))
        ]
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(entries),
            policies: testPolicies(rateCents: nil),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        let facts = rowFacts(snapshot, shiftID(7))
        #expect(facts.amount.cents == 0)
        #expect(facts.amount.text == Money.string(fromCents: 0))
    }

    @Test("with the wage feature off, a row's figure is labelled Tips rather than Total")
    func wagesOffRelabelsTheRow() {
        let facts = rowFacts(w1Snapshot(rateCents: nil), shiftID(2))
        #expect(facts.amount.metric == .nonWageEarnings)
        #expect(facts.amount.label == "Tips")
        #expect(facts.amount.mayBeCalledATotal == false)
        // No rate means no wage, so the figure is the tips alone.
        #expect(facts.amount.cents == 6000)
    }

    @Test("a shift with tips but no hours logged is partial, so its row is never called a Total")
    func aShiftWithNoHoursIsNeverATotal() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 4000, kind: .credit, shiftID: shiftID(3))
        ]
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(entries),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        let facts = rowFacts(snapshot, shiftID(3))
        #expect(facts.amount.completeness.state == .partial(missingHours: 1, missingRate: 0))
        #expect(facts.amount.label == "Known so far")
        #expect(facts.amount.mayBeCalledATotal == false)
        #expect(facts.amount.caption == "wages missing for 1 shift")
        // The figure is the tips that ARE known, not a fabricated wage.
        #expect(facts.amount.cents == 4000)
    }

    @Test("the row's note is trimmed and an all-whitespace note is dropped")
    func noteHandling() {
        let snapshot = w1Snapshot()
        #expect(ShiftDayRowFacts(
            snapshot: snapshot, shiftID: shiftID(1), day: at(2026, 9, 28),
            period: nil, dayHasMultipleShifts: false, note: "  slammed  "
        ).note == "slammed")
        #expect(ShiftDayRowFacts(
            snapshot: snapshot, shiftID: shiftID(1), day: at(2026, 9, 28),
            period: nil, dayHasMultipleShifts: false, note: "   \n "
        ).note == nil)
    }
}

// MARK: - HeroBreakdownDrawer

/// [SC-02] / [SC-03] The drawer's itemization and its bottom line, composed
/// once from one `EarningsResult`.
@Suite("HeroBreakdownDrawer is composed from one EarningsResult")
struct HeroBreakdownDrawerSnapshotTests {
    /// W1's day, plus a 1000c tip-out on the dinner shift so the subtotal
    /// and the subtraction rows appear.
    private func dayWithTipOut() throws -> EarningsSnapshot {
        let day = at(2026, 9, 28)
        let entries = [
            TipEntry(date: day, amountCents: 5000, kind: .credit, hoursWorked: 4.25,
                     shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: day.addingTimeInterval(3600), amountCents: 6000, kind: .credit, hoursWorked: 5.5,
                     tipOutCents: 1000, shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        return try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(entries),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
    }

    @Test("the rows run additions, subtotal, subtraction, and every figure is an engine component")
    func rowOrderAndFigures() throws {
        let snapshot = try dayWithTipOut()
        let result = snapshot.day(CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll))
        let rows = BreakdownRow.ledgerRows(result)

        #expect(rows.map(\.label) == [
            "Cash tips",
            "Credit tips",
            "Wages · 9h 45m",
            "Earned",
            "Tipped out"
        ])
        #expect(rows.map(\.cents) == [0, 11000, 2759, 13759, -1000])
        // The subtotal is the engine's, not four terms the screen added:
        // exactly one row carries a divider, and it is that one.
        #expect(rows.filter(\.dividerAbove).map(\.label) == ["Earned"])
        // 2759, never 2760: the wage row is the week's allocation.
        #expect(rows.first { $0.label.hasPrefix("Wages") }?.cents == 2759)
    }

    @Test("the bottom line is You kept when something was tipped out, and its cents are the engine's")
    func totalRowLabelAndCents() throws {
        let snapshot = try dayWithTipOut()
        let result = snapshot.day(CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll))
        let total = BreakdownRow.total(result)
        #expect(total.label == "You kept")
        #expect(total.emphasized)
        #expect(total.cents == result.knownComponents.earnedIncomeCents)
        #expect(total.cents == 11000 + 2759 - 1000)
        // The drawer reconciles: additions minus subtractions is the bottom
        // line, so a reader following the column lands on the same number.
        let rows = BreakdownRow.ledgerRows(result)
        let ledgerSum = rows
            .filter { $0.label != "Earned" }
            .reduce(0) { $0 + ($1.cents ?? 0) }
        #expect(ledgerSum == total.cents)
    }

    @Test("the collapsed lip quotes figures that reconcile to the bottom line")
    func lipReconciles() throws {
        let snapshot = try dayWithTipOut()
        let result = snapshot.day(CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll))
        #expect(BreakdownRow.lipText(result) == "Earned $137.59 · Tipped out $10.00")
        #expect(BreakdownRow.hasBreakdown(result))
    }

    @Test("a partial selection's bottom line is Known so far, never Total")
    func partialIsNeverATotal() throws {
        // Two shifts, one without hours: the day is partial.
        let day = at(2026, 9, 28)
        let entries = [
            TipEntry(date: day, amountCents: 5000, kind: .credit, hoursWorked: 4.25,
                     shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: day.addingTimeInterval(3600), amountCents: 6000, kind: .credit,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(entries),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        let result = snapshot.day(CivilDay(day, in: PaydayTestZone.payroll))
        let total = BreakdownRow.total(result)
        #expect(result.completeness.state == .partial(missingHours: 1, missingRate: 0))
        #expect(total.label == "Known so far")
        #expect(total.label != "Total")
        #expect(total.cents == result.knownComponents.earnedIncomeCents)
    }

    @Test("with wages off the bottom line is Tips, and no $0.00 wage row is drawn")
    func wagesOffDrawsNoWageRow() throws {
        let snapshot = w1Snapshot(rateCents: nil)
        let result = snapshot.day(CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll))
        let rows = BreakdownRow.ledgerRows(result)
        #expect(rows.contains { $0.label.hasPrefix("Wages") } == false)
        #expect(rows.contains { $0.label.hasPrefix("Overtime") } == false)
        #expect(BreakdownRow.total(result).label == "Tips")
    }

    @Test("a nil-cents row renders the placeholder, never $0.00")
    func nilCentsRendersThePlaceholder() {
        #expect(BreakdownRow.amountText(nil) == ShiftDayRow.unavailablePlaceholder)
        #expect(BreakdownRow.amountText(nil) != Money.string(fromCents: 0))
        #expect(BreakdownRow.amountText(0) == Money.string(fromCents: 0))
        #expect(BreakdownRow.amountText(-1000) == "−$10.00")
    }

    @Test("an overtime week itemizes regular and overtime separately, at their own hours")
    func overtimeSplitsIntoTwoRows() throws {
        // Design 1's worked example B, Mon-start week 28 Sep - 2 Oct 2026 at
        // 283c: 48h total, 40h regular (11320c) and 8h overtime (3396c).
        let hours: [Double] = [10.25, 9.75, 10.5, 11.5, 6]
        let entries = hours.enumerated().map { index, worked in
            TipEntry(date: at(2026, 9, 28 + index), amountCents: 1000, kind: .credit,
                     hoursWorked: worked, shiftID: shiftID(10 + index))
        }
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(entries),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 10, 31)
        ))
        let week = snapshot.range(DayRange(
            start: CivilDay(year: 2026, month: 9, day: 28),
            end: CivilDay(year: 2026, month: 10, day: 4)
        ))
        let rows = BreakdownRow.ledgerRows(week)
        #expect(rows.map(\.label) == ["Cash tips", "Credit tips", "Wages · 40h", "Overtime · 8h"])
        #expect(rows.map(\.cents) == [0, 5000, 11320, 3396])
        // 14716, the number the old month-first path lost 1131c of.
        #expect(BreakdownRow.total(week).cents == 5000 + 14716)
    }
}

// MARK: - NightlyEarningsChart

/// [SC-04] through [SC-07] and [SC-09]. The chart's bars are engine answers.
@Suite("NightlyEarningsChart bars are snapshot queries")
struct NightlyEarningsChartSnapshotTests {
    /// Five days in one Mon-start week, each with tips and hours, so the
    /// week carries overtime the M1 defect used to hide.
    private func weekSnapshot() throws -> EarningsSnapshot {
        let hours: [Double] = [10.25, 9.75, 10.5, 11.5, 6]
        let entries = hours.enumerated().map { index, worked in
            TipEntry(date: at(2026, 9, 28 + index), amountCents: 1000, kind: .credit,
                     hoursWorked: worked, shiftID: shiftID(10 + index))
        }
        return try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(entries),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 10, 31)
        ))
    }

    private let weekRange = DayRange(
        start: CivilDay(year: 2026, month: 9, day: 28),
        end: CivilDay(year: 2026, month: 10, day: 4)
    )

    @Test("a daily bar IS snapshot.day(thatDay), as a whole value")
    func aDailyBarIsTheDayResult() throws {
        let snapshot = try weekSnapshot()
        let facts = EarningsChartFacts(
            snapshot: snapshot,
            range: weekRange,
            timeZone: PaydayTestZone.payroll,
            asOf: .distantFuture
        )
        #expect(facts.granularity == .day)
        #expect(facts.points.count == 7)
        for point in facts.points {
            // Not "the cents agree". The whole result: same components, same
            // completeness, same scope, same manifest digest.
            #expect(point.result == snapshot.day(point.range.start))
        }
    }

    @Test("the bars are wage-inclusive, which is the M1 defect closing")
    func barsAreWageInclusive() throws {
        let snapshot = try weekSnapshot()
        let facts = EarningsChartFacts(
            snapshot: snapshot,
            range: weekRange,
            timeZone: PaydayTestZone.payroll,
            asOf: .distantFuture
        )
        let monday = facts.points.first { $0.range.start == CivilDay(year: 2026, month: 9, day: 28) }
        let mondayResult = try #require(monday?.result)
        // 10.25h at 283c, all regular: 2901c of wages on top of 1000c tips.
        #expect(monday?.cents == 1000 + 2901)
        // The old input was `ShiftFacts.netCents`, i.e. nonWageEarnings, so
        // this is the exact number the chart used to draw and no longer does.
        #expect(monday?.cents != mondayResult.knownComponents.nonWageEarningsCents)
        #expect(mondayResult.knownComponents.nonWageEarningsCents == 1000)
    }

    @Test("the bars sum to the whole-range answer, so the chart and a headline cannot disagree")
    func barsSumToTheWholeRange() throws {
        let snapshot = try weekSnapshot()
        for granularity in [EarningsChartAxisGranularity.day, .week, .month] {
            // Force each granularity by charting a range that selects it,
            // always containing the same week of shifts.
            let range: DayRange
            switch granularity {
            case .day: range = weekRange
            case .week: range = DayRange(start: weekRange.start, end: weekRange.start.adding(days: 40))
            default: range = DayRange(start: weekRange.start, end: weekRange.start.adding(days: 200))
            }
            let facts = EarningsChartFacts(
                snapshot: snapshot,
                range: range,
                timeZone: PaydayTestZone.payroll,
                asOf: .distantFuture
            )
            #expect(facts.granularity == granularity)
            let whole = try #require(facts.whole)
            #expect(facts.points.reduce(0) { $0 + $1.cents } == whole.knownComponents.earnedIncomeCents)
            // 5000c of tips + 14716c of wages, whatever the bar width.
            #expect(whole.knownComponents.earnedIncomeCents == 5000 + 14716)
        }
    }

    @Test("no snapshot means no bars, and no bar means no currency")
    func noSnapshotMeansNoBars() {
        let facts = EarningsChartFacts(
            snapshot: nil,
            range: weekRange,
            timeZone: PaydayTestZone.payroll
        )
        #expect(facts.points.isEmpty)
        #expect(facts.maxCents == 0)
        #expect(facts.whole == nil)
        #expect(facts.isUnbacked)
        // A valid x-domain even with nothing to draw, so the chart does not
        // trap on a reversed range.
        #expect(facts.xDomain.lowerBound < facts.xDomain.upperBound)
    }

    @Test("a bar covering a shift with no hours knows it is partial")
    func aPartialBarKnowsIt() throws {
        let day = at(2026, 9, 28)
        let entries = [
            TipEntry(date: day, amountCents: 5000, kind: .credit, hoursWorked: 4.25,
                     shiftPeriod: .lunch, shiftID: shiftID(1)),
            TipEntry(date: day.addingTimeInterval(3600), amountCents: 6000, kind: .credit,
                     shiftPeriod: .dinner, shiftID: shiftID(2))
        ]
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(entries),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        let facts = EarningsChartFacts(
            snapshot: snapshot,
            range: DayRange(day: CivilDay(day, in: PaydayTestZone.payroll)),
            timeZone: PaydayTestZone.payroll,
            asOf: .distantFuture
        )
        let bar = try #require(facts.points.first)
        #expect(bar.isPartial)
        // The scrub header and the peak annotation both read through the
        // figure, so neither can call this bar a Total.
        #expect(bar.figure.label == "Known so far")
        #expect(bar.figure.mayBeCalledATotal == false)
        #expect(bar.figure.text != nil)
    }

    @Test("the whole-history initializer spans the snapshot's own first and last shift")
    func wholeHistorySpansTheSnapshot() throws {
        let snapshot = try weekSnapshot()
        let facts = EarningsChartFacts(wholeOf: snapshot, timeZone: PaydayTestZone.payroll)
        #expect(facts.points.first?.range.start == CivilDay(year: 2026, month: 9, day: 28))
        #expect(facts.points.last?.range.end == CivilDay(year: 2026, month: 10, day: 2))
        #expect(facts.points.reduce(0) { $0 + $1.cents } == 5000 + 14716)
    }

    @Test("a to-date chart stops at the cutoff instead of drawing an empty future")
    func asOfClampsTheChart() throws {
        let snapshot = try weekSnapshot()
        let facts = EarningsChartFacts(
            snapshot: snapshot,
            range: weekRange,
            timeZone: PaydayTestZone.payroll,
            asOf: CivilDay(year: 2026, month: 9, day: 30)
        )
        #expect(facts.points.count == 3)
        #expect(facts.points.last?.range.end == CivilDay(year: 2026, month: 9, day: 30))
        // Mon + Tue + Wed: 3000c tips and 2901 + 2759 + 2972 of wages.
        #expect(facts.points.reduce(0) { $0 + $1.cents } == 3000 + 2901 + 2759 + 2972)
    }
}

// MARK: - ShiftContextMenu (Duplicate)

/// [SC-08] Duplicate copies verbatim. Proven through the engine: the copy
/// values the same as its source.
@Suite("Duplicate is valued identically by the engine")
@MainActor
struct DuplicateShiftValuationTests {
    @Test("a duplicated shift's non-wage components and minutes match its source exactly")
    func duplicateIsValuedIdenticallyByTheEngine() throws {
        let source = [
            TipEntry(date: at(2026, 9, 28), amountCents: 5000, kind: .credit, hoursWorked: 6.5,
                     tipOutCents: 800, salesCents: 120_000, shiftPeriod: .dinner, shiftID: shiftID(1),
                     serverCount: 4),
            TipEntry(date: at(2026, 9, 28), amountCents: 2000, kind: .cash, shiftID: shiftID(1))
        ]
        // Exactly what `duplicateShift(_:into:)` writes: every stored field
        // copied per row, one fresh shared shiftID, recordedAt = now.
        let copyID = shiftID(2)
        let copy = source.map { entry in
            TipEntry(
                date: entry.date,
                amountCents: entry.amountCents,
                kind: entry.kind,
                note: entry.note,
                recordedAt: .now,
                hoursWorked: entry.hoursWorked,
                tipOutCents: entry.tipOutCents,
                salesCents: entry.salesCents,
                shiftPeriod: entry.shiftPeriod,
                shiftID: copyID,
                clockIn: entry.clockIn,
                clockOut: entry.clockOut,
                serverCount: entry.serverCount,
                receiptMetrics: entry.receiptMetrics
            )
        }

        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(source + copy),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        let original = try #require(snapshot.valuation(shiftID(1)))
        let duplicate = try #require(snapshot.valuation(copyID))

        // The verbatim-copy contract, measured on what the engine sees. A
        // future edit that normalized a stored amount, dropped the receipt
        // payload, or re-derived the hours breaks one of these.
        #expect(duplicate.components.voluntaryCashCents == original.components.voluntaryCashCents)
        #expect(duplicate.components.voluntaryCreditCents == original.components.voluntaryCreditCents)
        #expect(duplicate.components.gratuityFeesCents == original.components.gratuityFeesCents)
        #expect(duplicate.components.tipOutCents == original.components.tipOutCents)
        #expect(duplicate.components.nonWageEarningsCents == original.components.nonWageEarningsCents)
        #expect(duplicate.minutesWorked == original.minutesWorked)
        #expect(duplicate.workDay == original.workDay)

        // And the one thing a duplicate MAY change: its WAGE. Measured, not
        // assumed — the first version of this test asserted the two wages
        // were equal and they are not. 6.5h at 283c is 1839.5c exact, so the
        // ledger's cumulative allocation hands the first shift 1840 and the
        // second 1839, telescoping to the week's exact 13h × 283c = 3679.
        // The copy is a cent under its source, and the pair still sums to
        // the number the hero above them shows.
        //
        // That is the engine working as designed (Design 1, step 5), and it
        // is exactly why the verbatim-copy contract above is asserted on the
        // NON-wage side. A wage is a property of a workweek, so it is not a
        // property a copy can inherit. (Independent per-shift rounding would
        // give 1840 twice and a week of 3680, the superseded answer.)
        #expect(original.components.wagesCents == 1840)
        #expect(duplicate.components.wagesCents == 1839)
        #expect(original.components.wagesCents + duplicate.components.wagesCents == 3679)
        #expect(abs(duplicate.components.wagesCents - original.components.wagesCents) <= 1)
        #expect(duplicate.overtimeMinutes == 0)
    }

    @Test("a duplicate that crosses the overtime threshold is priced differently, by rule")
    func aDuplicateMayChangeItsOwnWage() throws {
        // A 39h week plus a 39h duplicate: the copy lands almost entirely in
        // overtime. This is the engine working, not the copy misbehaving, and
        // it is why the verbatim contract is asserted on the non-wage side.
        let source = [
            TipEntry(date: at(2026, 9, 28), amountCents: 1000, kind: .credit, hoursWorked: 39,
                     shiftID: shiftID(1))
        ]
        let copy = [
            TipEntry(date: at(2026, 9, 29), amountCents: 1000, kind: .credit, recordedAt: .now,
                     hoursWorked: 39, shiftID: shiftID(2))
        ]
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(source + copy),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        let original = try #require(snapshot.valuation(shiftID(1)))
        let duplicate = try #require(snapshot.valuation(shiftID(2)))
        #expect(original.overtimeMinutes == 0)
        #expect(duplicate.overtimeMinutes == 38 * 60)
        #expect(duplicate.components.nonWageEarningsCents == original.components.nonWageEarningsCents)
    }
}

// MARK: - UndoDeleteToast

/// [SC-10] Undo is an exact inverse, measured through the engine rather than
/// by eyeballing the fields.
@Suite("Undo restores a shift the engine values identically")
@MainActor
struct UndoDeleteInverseTests {
    private func valuation(of entries: [TipEntry], id: UUID) throws -> ShiftValuation {
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(entries),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        return try #require(snapshot.valuation(id))
    }

    @Test("undoIsAnExactInverseThroughTheEngine: the restored shift values to the same cents and minutes")
    func undoIsAnExactInverseThroughTheEngine() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 5000, kind: .credit, hoursWorked: 6.5,
                     tipOutCents: 800, salesCents: 120_000, shiftPeriod: .dinner, shiftID: shiftID(1),
                     serverCount: 4),
            TipEntry(date: at(2026, 9, 28), amountCents: 2000, kind: .cash, shiftID: shiftID(1))
        ]
        let before = try valuation(of: entries, id: shiftID(1))

        // The exact round trip `UndoDeleteToastState` performs: snapshot
        // every row, then rebuild every row from its snapshot.
        let restored = entries.map { DeletedTipSnapshot(entry: $0).restored() }
        let after = try valuation(of: restored, id: shiftID(1))

        #expect(after == before)
    }

    @Test("the round trip preserves every stored field the engine reads, named one by one")
    func everyEngineRelevantFieldSurvives() throws {
        let entry = TipEntry(
            date: at(2026, 9, 28), amountCents: 5000, kind: .credit, note: "slammed",
            recordedAt: at(2026, 9, 28, hour: 23), hoursWorked: 6.5, tipOutCents: 800,
            salesCents: 120_000, shiftPeriod: .dinner, shiftID: shiftID(1),
            clockIn: at(2026, 9, 28, hour: 16), clockOut: at(2026, 9, 28, hour: 22),
            serverCount: 4
        )
        let restored = DeletedTipSnapshot(entry: entry).restored()

        #expect(restored.id == entry.id)
        #expect(restored.date == entry.date)
        #expect(restored.amountCents == entry.amountCents)
        #expect(restored.kind == entry.kind)
        #expect(restored.note == entry.note)
        #expect(restored.recordedAt == entry.recordedAt)
        #expect(restored.shiftID == entry.shiftID)
        #expect(restored.hoursWorked == entry.hoursWorked)
        #expect(restored.tipOutCents == entry.tipOutCents)
        #expect(restored.salesCents == entry.salesCents)
        #expect(restored.shiftPeriod == entry.shiftPeriod)
        #expect(restored.clockIn == entry.clockIn)
        #expect(restored.clockOut == entry.clockOut)
        #expect(restored.serverCount == entry.serverCount)
        #expect(restored.receiptMetrics == entry.receiptMetrics)
    }

    @Test("a deleted shift is absent from the snapshot, and its row renders no currency rather than $0")
    func aDeletedShiftRendersNoCurrency() throws {
        let entries = [
            TipEntry(date: at(2026, 9, 28), amountCents: 5000, kind: .credit, hoursWorked: 6.5,
                     shiftID: shiftID(1)),
            TipEntry(date: at(2026, 9, 29), amountCents: 4000, kind: .credit, hoursWorked: 5,
                     shiftID: shiftID(2))
        ]
        let surviving = entries.filter { $0.shiftID != shiftID(1) }
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(surviving),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        #expect(snapshot.valuation(shiftID(1)) == nil)
        let facts = ShiftDayRowFacts(
            snapshot: snapshot, shiftID: shiftID(1), day: at(2026, 9, 28),
            period: nil, dayHasMultipleShifts: false
        )
        #expect(facts.amount.isUnavailable)
        #expect(facts.amount.text == nil)
    }
}

// MARK: - The bridge itself

/// The wave-0 feed. It is not a second engine, and these tests are how that
/// claim is checked rather than asserted.
@Suite("LegacySnapshotBridge is the same engine over the legacy table")
struct LegacySnapshotBridgeTests {
    @Test("the bridge's wages are exactly WageEstimate.centsByShiftID's, which is the ledger's")
    func bridgeWagesMatchTheExistingPath() throws {
        let entries = w1Entries()
        let shifts = groups(entries)
        let existing = WageEstimate.centsByShiftID(
            payrollTimeZone: PaydayTestZone.payroll,
            workweekStartWeekday: 2,
            shifts: shifts,
            wageCentsPerHour: 283
        )
        let snapshot = w1Snapshot()
        for shift in shifts {
            #expect(
                snapshot.valuation(shift.shiftID)?.components.wagesCents == existing[shift.shiftID],
                "shift \(shift.shiftID) disagreed"
            )
        }
    }

    @Test("the bridge's tips are exactly TipBreakdown's, per shift and in total")
    func bridgeTipsMatchTipBreakdown() throws {
        let entries = w1Entries()
        let shifts = groups(entries)
        let snapshot = w1Snapshot()
        for shift in shifts {
            let breakdown = TipBreakdown.total(of: shift.items)
            let components = try #require(snapshot.valuation(shift.shiftID)?.components)
            #expect(components.voluntaryCashCents == breakdown.cashCents)
            #expect(components.voluntaryCreditCents == breakdown.creditCents)
            #expect(components.gratuityFeesCents == breakdown.gratuityFeesCents)
            #expect(components.tipOutCents == breakdown.tipOutCents)
            #expect(components.nonWageEarningsCents == breakdown.netTotalCents)
        }
        let day = snapshot.day(CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll))
        #expect(day.knownComponents.nonWageEarningsCents == TipBreakdown.total(of: entries).netTotalCents)
    }

    @Test("a group's own shiftID is the snapshot's key, so a row can never miss its own valuation")
    func theCallersIDIsTheKey() throws {
        // A legacy row with NO shiftID: `ShiftDays.groupedByShift` invents a
        // deterministic day-derived id, and `LegacyLedgerBridge.shiftInput`
        // invents a DIFFERENT one. The bridge uses the caller's, so the
        // lookup hits.
        let entries = [TipEntry(date: at(2026, 9, 28), amountCents: 5000, kind: .credit, hoursWorked: 5)]
        let shifts = groups(entries)
        let group = try #require(shifts.first)
        #expect(group.items.first?.shiftID == nil)
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: shifts,
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        #expect(snapshot.valuation(group.shiftID) != nil)
        #expect(snapshot.valuation(group.shiftID)?.components.voluntaryCreditCents == 5000)
    }

    @Test("no rate means the wage feature is off, not a wage of zero under a Total")
    func noRateMeansWagesOff() {
        let snapshot = w1Snapshot(rateCents: nil)
        #expect(snapshot.wageFeatureEnabled == false)
        let day = snapshot.day(CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll))
        #expect(day.completeness.state == .off)
        #expect(EarningsFigure.earnedIncome(day).label == "Tips")
    }

    /// The defect the `policies:` parameter exists to close.
    ///
    /// The first cut of the bridge took one scalar `rateCents` and
    /// `LegacyLedgerBridge.policies` turned it into a single `PayRatePolicy`
    /// at `effectiveFrom: .distantPast`, so every shift ever worked was
    /// repriced at today's rate on every migrated surface. `PolicyStore`
    /// holds real dated history — `PayrollSettingsSection` ships a "Rate
    /// changed on…" control that writes it — and now the bridge reads it.
    @Test("a shift worked before a raise is priced at the OLD rate, not today's")
    func rateHistoryIsHonoured() throws {
        let march = at(2026, 3, 2)
        let september = at(2026, 9, 28)
        let entries = [
            TipEntry(date: march, amountCents: 0, kind: .credit, hoursWorked: 8, shiftID: shiftID(1)),
            TipEntry(date: september, amountCents: 0, kind: .credit, hoursWorked: 8, shiftID: shiftID(2))
        ]
        let raiseDay = CivilDay(year: 2026, month: 6, day: 1)
        let policies = CompensationPolicies(
            rates: [
                PayRatePolicy(
                    id: PolicyMigration.deterministicID("test/rate/1000"),
                    effectiveFrom: .distantPast,
                    hourlyRateCents: 1000,
                    provenance: .confirmed
                ),
                PayRatePolicy(
                    id: PolicyMigration.deterministicID("test/rate/2000"),
                    effectiveFrom: raiseDay,
                    hourlyRateCents: 2000,
                    provenance: .confirmed
                )
            ],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("test/calendar/2"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: PaydayTestZone.payroll
            )]
        )
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(entries),
            policies: policies,
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))

        // 8h at $10/h, because March predates the raise.
        #expect(snapshot.valuation(shiftID(1))?.components.wagesCents == 8_000)
        // 8h at $20/h.
        #expect(snapshot.valuation(shiftID(2))?.components.wagesCents == 16_000)

        // And the range total, which is what a chart and a hero read. The
        // superseded scalar path answered 32000 here: both shifts at the
        // latest rate.
        let year = snapshot.range(DayRange(
            start: CivilDay(year: 2026, month: 1, day: 1),
            end: CivilDay(year: 2026, month: 12, day: 31)
        ))
        #expect(year.knownComponents.wagesCents == 24_000)
        #expect(year.knownComponents.wagesCents != 32_000, "the superseded distantPast-scalar answer")
    }

    /// `.estimated` was unreachable on every wave-0 surface while the bridge
    /// synthesized a `.confirmed` policy, which made
    /// `CompletenessCopy.caption(.estimated)` dead code in production even
    /// though `PolicyStore.runMigrationsIfNeeded` writes exactly this
    /// provenance for every upgrading Payday 1.0 user.
    @Test("a legacy-assumed rate reaches the screen as .estimated, with its caption")
    func assumedRateIsEstimatedNotComplete() throws {
        let policies = CompensationPolicies(
            rates: [PayRatePolicy(
                id: PolicyMigration.deterministicID("test/rate/assumed"),
                effectiveFrom: .distantPast,
                hourlyRateCents: 283,
                provenance: .assumedFromLegacySetting
            )],
            calendars: [PayrollCalendarPolicy(
                id: PolicyMigration.deterministicID("test/calendar/2"),
                effectiveFrom: .distantPast,
                workweekStartWeekday: 2,
                payrollTimeZone: PaydayTestZone.payroll
            )]
        )
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: groups(w1Entries()),
            policies: policies,
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        let day = snapshot.day(CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll))
        #expect(day.completeness.state == .estimated)
        #expect(CompletenessCopy.caption(day.completeness.state) == "Wages estimated from your current rate")

        // The same shifts under a CONFIRMED rate are complete, so the state
        // is tracking the provenance and not something else about the day.
        let confirmed = w1Snapshot().day(CivilDay(at(2026, 9, 28), in: PaydayTestZone.payroll))
        #expect(confirmed.completeness.state == .complete)
    }

    @Test("an empty shift list is a snapshot with no shifts, not a nil snapshot")
    func emptyIsStillASnapshot() throws {
        // The row type is spelled out because the bridge is generic over
        // `LegacyShiftRow` now, and an empty literal gives inference nothing
        // to work from. The assertion is unchanged.
        let snapshot = try #require(LegacySnapshotBridge.snapshot(
            shifts: [(day: Date, shiftID: UUID, items: [TipEntry])](),
            policies: testPolicies(rateCents: 283),
            payrollTimeZone: PaydayTestZone.payroll,
            asOf: at(2026, 9, 30)
        ))
        #expect(snapshot.shifts.isEmpty)
        #expect(snapshot.completeness.state == .noShifts)
    }
}
