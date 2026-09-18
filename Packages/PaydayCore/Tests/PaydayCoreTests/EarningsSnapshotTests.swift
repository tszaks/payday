import Foundation
import Testing
@testable import PaydayCore

// MARK: - Fixture plumbing

/// Builds a snapshot from a fixture's own declared inputs. Every number
/// asserted below comes from the fixture files, which were specified
/// independently of this code.
private func snapshot(
    _ id: String,
    asOf: CivilDay? = nil,
    generation: UInt64 = 1,
    ratePolicies: (([PayRatePolicy]) -> [PayRatePolicy])? = nil,
    schedule: PayScheduleInput?? = nil
) throws -> EarningsSnapshot {
    let fixture = try FixtureLoader.load(id)
    return try EarningsSnapshot.build(
        try inputs(fixture, asOf: asOf, ratePolicies: ratePolicies, schedule: schedule),
        generation: generation,
        computedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
}

private func inputs(
    _ fixture: Fixture,
    asOf: CivilDay? = nil,
    ratePolicies: (([PayRatePolicy]) -> [PayRatePolicy])? = nil,
    schedule: PayScheduleInput?? = nil
) throws -> EarningsInputs {
    let rates = ratePolicies.map { $0(fixture.toRatePolicies()) } ?? fixture.toRatePolicies()
    guard let cutoff = asOf ?? fixture.asOf else {
        Issue.record("Fixture \(fixture.id) declares no asOf and none was passed")
        throw FixtureLoader.Error.missing(id: fixture.id)
    }
    return EarningsInputs(
        shifts: fixture.toShiftInputs(),
        paychecks: try fixture.toPaycheckInputs(),
        schedule: schedule ?? fixture.toScheduleInput(),
        rates: rates,
        calendars: try fixture.toCalendarPolicies(),
        asOf: cutoff
    )
}

private func day(_ iso: String) -> CivilDay {
    guard let day = CivilDay(iso: iso) else {
        fatalError("test wrote a malformed day literal: \(iso)")
    }
    return day
}

private func range(_ start: String, _ end: String) -> DayRange {
    DayRange(start: day(start), end: day(end))
}

private func shiftID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

// MARK: - Additivity

@Suite("EarningsSnapshot additivity")
struct EarningsSnapshotAdditivityTests {
    /// W2's whole boundary week: the range total is 14716 and the five day
    /// totals are 2901 / 2759 / 2972 / 3537 / 2547 (M1.days). Σ days must
    /// equal the range, or a chart disagrees with the headline above it.
    @Test("range equals the sum of its days")
    func rangeEqualsSumOfDays() throws {
        let snap = try snapshot("W2")
        let week = range("2026-09-28", "2026-10-04")

        let whole = snap.range(week)
        let days = snap.days(in: week)

        #expect(whole.knownComponents.earnedIncomeCents == 14716)
        #expect(days.reduce(0) { $0 + $1.knownComponents.earnedIncomeCents } == 14716)
        #expect(days.reduce(EarningsComponents.zero) { $0 + $1.knownComponents } == whole.knownComponents)
        #expect(days.reduce(0) { $0 + $1.minutes } == whole.minutes)
        #expect(days.reduce(0) { $0 + $1.regularMinutes } == whole.regularMinutes)
        #expect(days.reduce(0) { $0 + $1.overtimeMinutes } == whole.overtimeMinutes)
        #expect(days.flatMap(\.shiftIDs) == whole.shiftIDs)
        // The clamp shortened the week: asOf is Friday, the bucket ends Sunday.
        #expect(days.count == 5)
    }

    /// M1's per-day chart points, each asserted by the fixture.
    @Test("every day equals the fixture's chart point")
    func dayEqualsChartPoint() throws {
        let snap = try snapshot("M1")
        let expected: [(String, Int, Int, Int, Int)] = [
            ("2026-09-28", 2901, 615, 615, 0),
            ("2026-09-29", 2759, 585, 585, 0),
            ("2026-09-30", 2972, 630, 630, 0),
            ("2026-10-01", 3537, 690, 570, 120),
            ("2026-10-02", 2547, 360, 0, 360),
        ]
        for (iso, cents, minutes, regular, overtime) in expected {
            let result = snap.day(day(iso))
            #expect(result.knownComponents.earnedIncomeCents == cents, "\(iso)")
            #expect(result.minutes == minutes, "\(iso)")
            #expect(result.regularMinutes == regular, "\(iso)")
            #expect(result.overtimeMinutes == overtime, "\(iso)")
            #expect(result.scope == .day(day(iso)))
        }
        // M1: monthTotalEqualsSumOfChartPoints.
        #expect(snap.month(YearMonth(year: 2026, month: 9)).knownComponents.earnedIncomeCents == 8632)
        #expect(snap.month(YearMonth(year: 2026, month: 10)).knownComponents.earnedIncomeCents == 6084)
        #expect(snap.range(range("2026-09-28", "2026-10-02")).knownComponents.earnedIncomeCents == 14716)
    }

    /// W2's whole point: September 8632 + October 6084 == 14716, and the
    /// month-first recomputation that loses the overtime premium reads 13585.
    @Test("month plus month equals the containing range, and is not the month-first answer")
    func monthPlusMonthEqualsRange() throws {
        let snap = try snapshot("W2")
        let september = snap.month(YearMonth(year: 2026, month: 9))
        let october = snap.month(YearMonth(year: 2026, month: 10))
        let containing = snap.range(range("2026-09-01", "2026-10-31"))

        #expect(september.knownComponents.earnedIncomeCents == 8632)
        #expect(october.knownComponents.earnedIncomeCents == 6084)
        #expect(september.knownComponents + october.knownComponents == containing.knownComponents)
        #expect(containing.knownComponents.earnedIncomeCents == 14716)
        #expect(containing.knownComponents.earnedIncomeCents != 13585, "W2's asserted wrong answer")
        #expect(october.knownComponents.earnedIncomeCents != 4953, "the month-first October")
        #expect(september.shiftIDs + october.shiftIDs == containing.shiftIDs)
    }

    /// The pay period Sep 21 .. Oct 4 contains the whole 48-hour workweek,
    /// so it keeps the 480 overtime minutes and 3396c of premium the week
    /// produced (S2.payPeriodSep21ToOct4). A period that re-derived overtime
    /// from its own hours would still find them here; the case that proves
    /// the rule is October alone, whose 1050 minutes sit under the 2400
    /// threshold and still carry 480 overtime minutes because the WEEK
    /// crossed it.
    @Test("a pay period straddling a workweek keeps the week's overtime")
    func payPeriodKeepsOvertime() throws {
        let snap = try snapshot("W2")
        let period = snap.payPeriod(range("2026-09-21", "2026-10-04"))
        #expect(period.overtimeMinutes == 480)
        #expect(period.knownComponents.overtimeWagesCents == 3396)
        #expect(period.knownComponents.earnedIncomeCents == 14716)

        // October in isolation: 1050 minutes, all of which a period-first
        // engine would call regular. 480 of them are overtime.
        let october = snap.month(YearMonth(year: 2026, month: 10))
        #expect(october.minutes == 1050)
        #expect(october.overtimeMinutes == 480)
        #expect(october.knownComponents.overtimeWagesCents == 3396)
        #expect(october.knownComponents.earnedIncomeCents == 6084)

        // And the second half of the same week, as its own pay period:
        // Oct 1 .. Oct 4 is entirely past the threshold Sep 28-30 consumed.
        let secondHalf = snap.payPeriod(range("2026-10-01", "2026-10-04"))
        #expect(secondHalf.overtimeMinutes == 480)
        #expect(secondHalf.knownComponents.overtimeWagesCents == 3396)
    }

    /// A pay period crossing New Year's Eve contributes only its in-year
    /// days to each year's YTD, and the two YTDs sum to the period.
    @Test("year to date clips a pay period that crosses the year boundary")
    func yearToDateClipsAcrossTheBoundary() throws {
        // Two shifts in one Monday-start workweek (Mon 2026-12-28 ..
        // Sun 2027-01-03): Dec 30 and Jan 1, 300 minutes each at 283c.
        // 283 * 300 * 100 = 8_490_000 units -> roundCents = 1415 each (Z1's
        // number for a 300-minute shift at 283c).
        let calendar = PayrollCalendarPolicy(
            id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!,
            effectiveFrom: day("2025-12-29"),
            workweekStartWeekday: 2,
            payrollTimeZone: TimeZone(identifier: "America/New_York")!
        )
        let rate = PayRatePolicy(
            id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!,
            effectiveFrom: day("2025-12-29"),
            hourlyRateCents: 283,
            provenance: .confirmed
        )
        let snap = try EarningsSnapshot.build(EarningsInputs(
            shifts: [
                ShiftInput(id: shiftID(1), workDay: day("2026-12-30"), minutesWorked: 300),
                ShiftInput(id: shiftID(2), workDay: day("2027-01-01"), minutesWorked: 300),
            ],
            rates: [rate],
            calendars: [calendar],
            asOf: day("2027-06-30")
        ))

        let period = snap.payPeriod(range("2026-12-28", "2027-01-10"))
        #expect(period.knownComponents.earnedIncomeCents == 2830)
        #expect(period.shiftIDs == [shiftID(1), shiftID(2)])

        let ytd2026 = snap.yearToDate(year: 2026)
        let ytd2027 = snap.yearToDate(year: 2027)
        #expect(ytd2026.knownComponents.earnedIncomeCents == 1415)
        #expect(ytd2026.shiftIDs == [shiftID(1)])
        #expect(ytd2027.knownComponents.earnedIncomeCents == 1415)
        #expect(ytd2027.shiftIDs == [shiftID(2)])
        #expect(ytd2026.knownComponents + ytd2027.knownComponents == period.knownComponents)
        #expect(ytd2026.range == range("2026-01-01", "2026-12-31"))
        #expect(ytd2026.scope == .yearToDate(year: 2026))

        // A YTD asked before year end clamps to asOf, not to Dec 31.
        let midYear = snap.yearToDate(year: 2027, asOf: day("2027-01-01"))
        #expect(midYear.range == range("2027-01-01", "2027-01-01"))
        #expect(midYear.knownComponents.earnedIncomeCents == 1415)
    }
}

// MARK: - asOf

@Suite("EarningsSnapshot asOf clamp")
struct EarningsSnapshotAsOfTests {
    /// Every query in S2's `queries` table, which was specified against
    /// `StatsEngine.periodToDateTotal`'s cutoff rule
    /// (`min(startOfDay(asOf), period.end)`, inclusive on both ends).
    @Test("S2: asOf clamps the range end for tips and wages alike")
    func s2ClampTable() throws {
        let snap = try snapshot("S2")
        let future = shiftID(6)

        // range(Sep 28 .. Oct 9, asOf Oct 2)
        let clamped = snap.range(range("2026-09-28", "2026-10-09"))
        #expect(clamped.range == range("2026-09-28", "2026-10-02"))
        #expect(clamped.knownComponents.earnedIncomeCents == 14716)
        #expect(clamped.knownComponents.nonWageEarningsCents == 0, "the future shift's tips must not leak")
        #expect(clamped.knownComponents.wagesCents == 14716)
        #expect(clamped.minutes == 2880)
        #expect(clamped.hourlyRateCents == 307)
        #expect(clamped.shiftIDs == (1...5).map(shiftID))
        #expect(clamped.completeness.state == .complete)
        // S2's four asserted wrong answers for this one query.
        #expect(clamped.knownComponents.earnedIncomeCents != 28980, "no asOf at all")
        #expect(clamped.knownComponents.earnedIncomeCents != 26716, "asOf on wages only, tips leak")
        #expect(clamped.knownComponents.earnedIncomeCents != 16980, "asOf on tips only, wages leak")

        // month(2026-10, asOf Oct 2)
        let october = snap.month(YearMonth(year: 2026, month: 10))
        #expect(october.range == range("2026-10-01", "2026-10-02"))
        #expect(october.knownComponents.earnedIncomeCents == 6084)
        #expect(october.hourlyRateCents == 348)
        #expect(october.knownComponents.earnedIncomeCents != 20348, "October including the future shift")

        // month(2026-09, asOf Oct 2) is unclamped: the month ends first.
        let september = snap.month(YearMonth(year: 2026, month: 9))
        #expect(september.range == range("2026-09-01", "2026-09-30"))
        #expect(september.knownComponents.earnedIncomeCents == 8632)
        #expect(september.hourlyRateCents == 283)

        // payPeriod(Sep 21 .. Oct 4, asOf Oct 2)
        let thisPeriod = snap.payPeriod(range("2026-09-21", "2026-10-04"))
        #expect(thisPeriod.range == range("2026-09-21", "2026-10-02"))
        #expect(thisPeriod.knownComponents.earnedIncomeCents == 14716)
        #expect(thisPeriod.hourlyRateCents == 307)

        // payPeriod(Oct 5 .. Oct 18, asOf Oct 2): start is past the cutoff,
        // so the selection is EMPTY and must not trap.
        let nextPeriod = snap.payPeriod(range("2026-10-05", "2026-10-18"))
        #expect(nextPeriod.range?.isEmpty == true, "S2 calls this effectiveRange null")
        #expect(nextPeriod.shiftIDs.isEmpty)
        #expect(nextPeriod.knownComponents == .zero)
        #expect(nextPeriod.coveredComponents == .zero)
        #expect(nextPeriod.minutes == 0)
        #expect(nextPeriod.hourlyRateCents == nil)
        #expect(nextPeriod.completeness.state == .noShifts)
        #expect(nextPeriod.knownComponents.earnedIncomeCents != 14264, "the period with no asOf")
        #expect(nextPeriod.knownComponents.earnedIncomeCents != 2264,
                "today's bug: tips clamped, wages summed over the whole period")

        // range(Oct 9 .. Oct 9, asOf Oct 2): same empty case.
        let futureRange = snap.range(range("2026-10-09", "2026-10-09"))
        #expect(futureRange.range?.isEmpty == true)
        #expect(futureRange.knownComponents.earnedIncomeCents == 0)
        #expect(futureRange.knownComponents.earnedIncomeCents != 14264)

        // day(Oct 9) takes no asOf, so it DOES return the future shift.
        // S2.dayOct9Unclamped asserts this is correct, not a wrong answer.
        let futureDay = snap.day(day("2026-10-09"))
        #expect(futureDay.shiftIDs == [future])
        #expect(futureDay.knownComponents.earnedIncomeCents == 14264)
        #expect(futureDay.knownComponents.nonWageEarningsCents == 12000)
        #expect(futureDay.knownComponents.wagesCents == 2264)
        #expect(futureDay.hourlyRateCents == 1783)
        #expect(futureDay.completeness.state == .complete)

        // The ledger valued it regardless of the query cutoff.
        let valuation = snap.valuation(future)
        #expect(valuation?.workweekStart == day("2026-10-05"))
        #expect(valuation?.wage.isValued == true)
        #expect(valuation?.components.regularWagesCents == 2264)
    }

    /// `days(in:)` is clamped so that a chart's bars sum to the headline
    /// above them, while `day(_:)` is not so that DayDetail on a future
    /// shift shows the shift. The asymmetry is deliberate; this pins it.
    @Test("days(in:) is clamped while day(_:) is not")
    func daysAreClampedButADayIsNot() throws {
        let snap = try snapshot("S2")
        let wide = range("2026-09-28", "2026-10-09")

        let series = snap.days(in: wide)
        #expect(series.count == 5, "Sep 28 through the Oct 2 cutoff")
        #expect(series.last?.range == range("2026-10-02", "2026-10-02"))
        #expect(series.reduce(0) { $0 + $1.knownComponents.earnedIncomeCents }
                == snap.range(wide).knownComponents.earnedIncomeCents)
        #expect(series.contains { !$0.shiftIDs.contains(shiftID(6)) })
        #expect(series.allSatisfy { !$0.shiftIDs.contains(shiftID(6)) })

        #expect(snap.day(day("2026-10-09")).shiftIDs == [shiftID(6)])
    }

    /// An explicit `asOf` overrides the stamp's, and `.distantFuture` opts
    /// out of the clamp entirely.
    @Test("an explicit asOf overrides the stamp, and distantFuture disables the clamp")
    func explicitAsOfOverridesTheStamp() throws {
        let snap = try snapshot("S2")
        let wide = range("2026-09-28", "2026-10-09")

        #expect(snap.stamp.asOf == day("2026-10-02"))
        #expect(snap.range(wide, asOf: .distantFuture).knownComponents.earnedIncomeCents == 28980)
        #expect(snap.range(wide, asOf: day("2026-09-29")).shiftIDs == [shiftID(1), shiftID(2)])
        #expect(snap.range(wide, asOf: day("2026-09-27")).shiftIDs.isEmpty)
    }
}

// MARK: - Hourly rate

@Suite("EarningsSnapshot hourly rate")
struct EarningsSnapshotHourlyRateTests {
    /// H1: shift A is 10000c over 300 minutes, shift B is 10000c with no
    /// hours at all. The rate is 2000c/h (covered income over covered
    /// minutes), never 4000c/h (all income over covered minutes).
    @Test("H1: an hours-less shift is excluded from both sides of the rate")
    func h1ExcludesUncoveredShiftsFromBothSides() throws {
        let snap = try snapshot("H1")
        let result = snap.range(range("2026-09-28", "2026-10-02"))

        #expect(result.knownComponents.earnedIncomeCents == 20000)
        #expect(result.coveredComponents.earnedIncomeCents == 10000)
        #expect(result.minutes == 300)
        #expect(result.hourlyRateCents == 2000)
        #expect(result.hourlyRateCents != 4000, "H1's asserted wrong answer")
        #expect(result.completeness.totalShifts == 2)
        #expect(result.completeness.shiftsWithHours == 1)
        #expect(result.completeness.shiftsWageValued == 0)
        #expect(result.completeness.shiftsWageAssumed == 0)
        #expect(result.coveredShiftCount == 1)
        #expect(result.shiftIDs == [shiftID(1), shiftID(2)])

        // H1 declares no rate policy, so the wage feature is off entirely.
        #expect(snap.wageFeatureEnabled == false)
        #expect(result.completeness.state == .off)

        // The threshold split survives the missing rate: 300 known minutes,
        // 300 of them regular, zero cents of wages.
        #expect(result.regularMinutes == 300)
        #expect(result.overtimeMinutes == 0)
        #expect(result.knownComponents.wagesCents == 0)
        #expect(snap.valuation(shiftID(1))?.wage.unavailableReason == .rateNotSet)
        #expect(snap.valuation(shiftID(1))?.regularMinutes == 300)
        #expect(snap.valuation(shiftID(2))?.regularMinutes == nil)
    }

    /// No covered minutes means no rate, never a division by zero and never
    /// a zero presented as a rate.
    @Test("hourlyRateCents is nil without covered minutes")
    func hourlyRateIsNilWithoutCoverage() throws {
        let snap = try snapshot("H1")
        let bDayOnly = snap.day(day("2026-09-29"))
        #expect(bDayOnly.minutes == 0)
        #expect(bDayOnly.hourlyRateCents == nil)
        #expect(bDayOnly.knownComponents.earnedIncomeCents == 10000)
    }

    /// The valued split and the calendar split are the same number for a
    /// priced shift, across every fixture in the corpus. Two fields holding
    /// one value is only safe if something checks.
    @Test("the threshold split agrees with the valued wage split on every fixture")
    func thresholdSplitAgreesWithTheValuedWageSplit() throws {
        for id in FixtureLoader.availableIDs() {
            let fixture = try FixtureLoader.load(id)
            guard fixture.asOf != nil, !fixture.shifts.isEmpty else { continue }
            let snap = try EarningsSnapshot.build(try inputs(fixture))
            for valuation in snap.shifts {
                switch valuation.wage {
                case .valued(let components, _):
                    #expect(valuation.regularMinutes == components.regularMinutes, "\(id)/\(valuation.id)")
                    #expect(valuation.overtimeMinutes == components.overtimeMinutes, "\(id)/\(valuation.id)")
                    #expect(valuation.minutesWorked == components.minutesWorked, "\(id)/\(valuation.id)")
                case .unavailable:
                    // Split only where there were hours AND a workweek.
                    let splittable = valuation.minutesWorked != nil && valuation.workweekStart != nil
                    #expect((valuation.regularMinutes != nil) == splittable, "\(id)/\(valuation.id)")
                }
            }
        }
    }
}

// MARK: - Completeness

@Suite("EarningsSnapshot completeness states")
struct EarningsSnapshotCompletenessTests {
    @Test("complete: W2's week, every shift valued from a confirmed rate")
    func completeState() throws {
        let snap = try snapshot("W2")
        let week = snap.range(range("2026-09-28", "2026-10-04"))
        #expect(week.completeness.state == .complete)
        #expect(week.completeness.totalShifts == 5)
        #expect(week.completeness.shiftsWithHours == 5)
        #expect(week.completeness.shiftsWageValued == 5)
        #expect(week.completeness.shiftsWageAssumed == 0)
        #expect(week.completeness.wageFeatureEnabled)
    }

    /// C1: W2 with Thursday's hours removed. The honest headline is 10330
    /// labelled "Known so far", never 14716 and never 10330 called a total.
    @Test("partial: C1's week reports missingHours 1 and a known total of 10330")
    func partialState() throws {
        let snap = try snapshot("C1")
        let week = snap.range(range("2026-09-28", "2026-10-04"))

        #expect(week.completeness.state == .partial(missingHours: 1, missingRate: 0))
        #expect(week.completeness.totalShifts == 5)
        #expect(week.completeness.shiftsWithHours == 4)
        #expect(week.completeness.shiftsWageValued == 4)
        #expect(week.knownComponents.earnedIncomeCents == 10330)
        #expect(week.knownComponents.earnedIncomeCents != 14716, "W2's complete week")
        #expect(week.minutes == 2190)
        #expect(week.regularMinutes == 2190)
        #expect(week.overtimeMinutes == 0)
        #expect(week.hourlyRateCents == 283)
        #expect(week.coveredShiftCount == 4)

        // C1's month split: September is complete, October is partial.
        let september = snap.month(YearMonth(year: 2026, month: 9))
        #expect(september.completeness.state == .complete)
        #expect(september.knownComponents.earnedIncomeCents == 8632)
        let october = snap.month(YearMonth(year: 2026, month: 10))
        #expect(october.completeness.state == .partial(missingHours: 1, missingRate: 0))
        #expect(october.knownComponents.earnedIncomeCents == 1698)
        #expect(september.knownComponents.earnedIncomeCents
                + october.knownComponents.earnedIncomeCents == 10330)
    }

    /// The legacy rate the migration adopts is an ASSUMPTION, so the same
    /// cents come back as `.estimated` until the user confirms the history.
    @Test("estimated: an assumed legacy rate values every shift and still says so")
    func estimatedState() throws {
        let snap = try snapshot("W2", ratePolicies: { rates in
            rates.map { rate in
                PayRatePolicy(
                    id: rate.id,
                    effectiveFrom: rate.effectiveFrom,
                    hourlyRateCents: rate.hourlyRateCents,
                    provenance: .assumedFromLegacySetting
                )
            }
        })
        let week = snap.range(range("2026-09-28", "2026-10-04"))

        #expect(week.completeness.state == .estimated)
        #expect(week.completeness.shiftsWageValued == 5)
        #expect(week.completeness.shiftsWageAssumed == 5)
        // Not a cent moves: `.estimated` is a caption, not a different number.
        #expect(week.knownComponents.earnedIncomeCents == 14716)
    }

    /// One confirmed rate and one assumed one: some shifts assumed is still
    /// `.estimated`, because the headline carries an assumption either way.
    @Test("estimated: a mix of confirmed and assumed rates is still estimated")
    func estimatedWithAMixedHistory() throws {
        let snap = try snapshot("W2", ratePolicies: { rates in
            rates.map {
                PayRatePolicy(id: $0.id, effectiveFrom: $0.effectiveFrom,
                              hourlyRateCents: $0.hourlyRateCents,
                              provenance: .assumedFromLegacySetting)
            } + [PayRatePolicy(
                id: UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000001")!,
                effectiveFrom: day("2026-10-01"),
                hourlyRateCents: 283,
                provenance: .confirmed
            )]
        })
        let week = snap.range(range("2026-09-28", "2026-10-04"))
        #expect(week.completeness.state == .estimated)
        #expect(week.completeness.shiftsWageAssumed == 3, "Sep 28-30 sit under the assumed policy")
        #expect(week.completeness.shiftsWageValued == 5)
    }

    @Test("off: no rate policy at all means wages are not a feature yet")
    func offState() throws {
        let snap = try snapshot("H1")
        #expect(snap.completeness.state == .off)
        #expect(snap.range(range("2026-09-28", "2026-10-02")).completeness.state == .off)
    }

    @Test("noShifts: an empty selection is not a zero total")
    func noShiftsState() throws {
        let snap = try snapshot("W2")
        let empty = snap.range(range("2026-08-01", "2026-08-31"))
        #expect(empty.completeness.state == .noShifts)
        #expect(empty.knownComponents == .zero)
        #expect(empty.hourlyRateCents == nil)
        #expect(snap.day(day("2026-08-01")).completeness.state == .noShifts)
    }

    /// A rate policy that starts after a shift leaves that shift unpriced
    /// while its neighbours are valued: `.partial(missingRate:)`.
    @Test("partial: missingRate counts shifts with hours and no rate in effect")
    func partialMissingRate() throws {
        let snap = try snapshot("W2", ratePolicies: { rates in
            rates.map {
                PayRatePolicy(id: $0.id, effectiveFrom: day("2026-10-01"),
                              hourlyRateCents: $0.hourlyRateCents, provenance: .confirmed)
            }
        })
        let week = snap.range(range("2026-09-28", "2026-10-04"))
        #expect(week.completeness.state == .partial(missingHours: 0, missingRate: 3))
        #expect(week.completeness.shiftsWithHours == 5)
        #expect(week.completeness.shiftsWageValued == 2)
        // The unpriced Monday-to-Wednesday minutes still pushed the week
        // into overtime, which is why Friday is all overtime here too.
        #expect(week.minutes == 2880)
        #expect(week.regularMinutes == 2400)
        #expect(week.overtimeMinutes == 480)
    }
}

// MARK: - Digests

@Suite("EarningsSnapshot input digests")
struct EarningsSnapshotDigestTests {
    /// The digest is a function of the input SET, not of the order a store
    /// happened to return it in.
    ///
    /// The hex is pinned so a change to how the snapshot assembles its
    /// inputs is a failing test rather than a silently different
    /// fingerprint. The canonical FORMAT is pinned independently by
    /// `InputManifestTests.pinnedDigest`; this pin is over W2's inputs
    /// specifically (5 shifts, 1 rate, 1 calendar, the biweekly schedule,
    /// asOf 2026-10-02, engine 1).
    @Test("the manifest digest is order-independent and pinned")
    func digestIsOrderIndependentAndPinned() throws {
        let fixture = try FixtureLoader.load("W2")
        let forward = try inputs(fixture)
        var reversed = forward
        reversed.shifts.reverse()

        let a = try EarningsSnapshot.build(forward, generation: 1)
        let b = try EarningsSnapshot.build(reversed, generation: 99)

        #expect(a.stamp.digest == b.stamp.digest)
        #expect(a.stamp.digest == "6ec417bb99ebaf1cd8183b33118fd4271273ebf7cfae29488573632c4ed1dfb9")
        #expect(a.shifts == b.shifts, "the valuations are order-independent too")
        #expect(a.stamp.generation != b.stamp.generation, "only the generation differs")
    }

    /// Editing a paycheck must move the paycheck sub-digest and nothing
    /// else, so a consumer can say WHICH input changed.
    @Test("editing a paycheck changes paychecksDigest only")
    func editingAPaycheckMovesOneDigest() throws {
        let fixture = try FixtureLoader.load("W2")
        var before = try inputs(fixture)
        before.paychecks = [PaycheckInput(
            id: UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000001")!,
            periodStart: day("2026-09-21"),
            periodEnd: day("2026-10-04"),
            paidTipsCents: 10000
        )]
        var after = before
        after.paychecks[0].paidTipsCents = 10050

        let a = try EarningsSnapshot.build(before).stamp.manifest
        let b = try EarningsSnapshot.build(after).stamp.manifest

        #expect(a.paychecksDigest != b.paychecksDigest)
        #expect(a.shiftsDigest == b.shiftsDigest)
        #expect(a.scheduleDigest == b.scheduleDigest)
        #expect(a.policiesDigest == b.policiesDigest)
        #expect(a.digest != b.digest, "the full digest still moves")
        #expect(a.paycheckCount == b.paycheckCount)
    }

    /// The pay schedule is in the digest because it decides which shifts a
    /// pay period contains, and nothing else about a shift changes with it.
    ///
    /// The two period ranges are `PayPeriodCalculator`'s answers for Oct 2
    /// under each schedule, stated as literals: biweekly anchored Sun
    /// 2026-10-04 gives Sep 21 .. Oct 4 (the previous boundary is Sep 20),
    /// monthly anchored 2026-09-30 gives Oct 1 .. Oct 31.
    @Test("changing the schedule changes scheduleDigest and period membership")
    func changingTheScheduleMovesOneDigestAndThePeriod() throws {
        let fixture = try FixtureLoader.load("W2")
        let biweekly = try inputs(fixture)
        let monthly = try inputs(fixture, schedule: PayScheduleInput(
            frequency: "monthly",
            anchorPeriodEnd: day("2026-09-30"),
            payDelayDays: 5,
            firstWeekday: 2
        ))

        let a = try EarningsSnapshot.build(biweekly)
        let b = try EarningsSnapshot.build(monthly)

        #expect(a.stamp.manifest.scheduleDigest != b.stamp.manifest.scheduleDigest)
        #expect(a.stamp.manifest.shiftsDigest == b.stamp.manifest.shiftsDigest)
        #expect(a.stamp.manifest.policiesDigest == b.stamp.manifest.policiesDigest)
        #expect(a.stamp.manifest.paychecksDigest == b.stamp.manifest.paychecksDigest)
        #expect(a.shifts == b.shifts, "no cent moves: the schedule is not a wage input")

        let biweeklyPeriod = a.payPeriod(range("2026-09-21", "2026-10-04"))
        let monthlyPeriod = b.payPeriod(range("2026-10-01", "2026-10-31"))
        #expect(biweeklyPeriod.shiftIDs == (1...5).map(shiftID))
        #expect(monthlyPeriod.shiftIDs == [shiftID(4), shiftID(5)])
        #expect(biweeklyPeriod.knownComponents.earnedIncomeCents == 14716)
        #expect(monthlyPeriod.knownComponents.earnedIncomeCents == 6084)
    }

    /// W3's whole point restated at the snapshot level: the calendar grid's
    /// `firstWeekday` is not a wage input, so flipping it moves the schedule
    /// digest and not one cent.
    @Test("W3: flipping the grid firstWeekday moves no money")
    func gridFirstWeekdayMovesNoMoney() throws {
        let w2 = try snapshot("W2")
        let w3 = try snapshot("W3")
        #expect(w3.stamp.manifest.shiftsDigest == w2.stamp.manifest.shiftsDigest)
        #expect(w3.stamp.manifest.policiesDigest == w2.stamp.manifest.policiesDigest)
        #expect(w3.stamp.manifest.scheduleDigest != w2.stamp.manifest.scheduleDigest)
        #expect(w3.range(range("2026-09-28", "2026-10-04")).knownComponents
                == w2.range(range("2026-09-28", "2026-10-04")).knownComponents)
    }

    /// Every result carries the stamp's engine and digest, which is how two
    /// consumers prove they are quoting the same dataset.
    @Test("every result carries engineVersion and manifestDigest")
    func everyResultCarriesItsProvenance() throws {
        let snap = try snapshot("W2")
        let results = [
            snap.day(day("2026-09-28")),
            snap.month(YearMonth(year: 2026, month: 9)),
            snap.payPeriod(range("2026-09-21", "2026-10-04")),
            snap.yearToDate(year: 2026),
            snap.range(range("2026-09-28", "2026-10-04")),
            snap.shift(shiftID(1))!,
        ] + snap.days(in: range("2026-09-28", "2026-10-04"))

        for result in results {
            #expect(result.engineVersion == snap.stamp.engineVersion)
            #expect(result.engineVersion == CompensationLedger.engineVersion)
            #expect(result.manifestDigest == snap.stamp.digest)
            #expect(result.scope != nil)
            #expect(result.metric == .earnedIncome)
        }
    }
}

// MARK: - Shifts, paychecks, Codable

@Suite("EarningsSnapshot shifts and paychecks")
struct EarningsSnapshotShiftAndPaycheckTests
{
    @Test("shift(id) returns one shift's own figures, and nil for an unknown id")
    func shiftQuery() throws {
        let snap = try snapshot("W2")
        let thursday = snap.shift(shiftID(4))
        #expect(thursday?.knownComponents.earnedIncomeCents == 3537)
        #expect(thursday?.regularMinutes == 570)
        #expect(thursday?.overtimeMinutes == 120)
        #expect(thursday?.minutes == 690)
        #expect(thursday?.range == nil, "a shift is a row, not a span")
        #expect(thursday?.scope == .shift(shiftID(4)))
        #expect(thursday?.completeness.totalShifts == 1)
        #expect(snap.shift(UUID()) == nil)
    }

    /// P1: the stub implies a 50c correction. `observedPaidTips` stays
    /// exactly as entered; the engine never rewrites it.
    @Test("P1: a paycheck's observed tips are carried verbatim")
    func paycheckIsCarriedVerbatim() throws {
        let fixture = try FixtureLoader.load("P1")
        let paychecks = try fixture.toPaycheckInputs()
        guard let stub = paychecks.first else {
            Issue.record("P1 declares no paycheck")
            return
        }
        #expect(stub.paidTipsCents == 10000, "P1.observedPaidTipsCents")

        var built = try inputs(fixture, asOf: fixture.asOf ?? day("2026-10-02"))
        built.paychecks = paychecks
        let snap = try EarningsSnapshot.build(built)

        let reconciliation = snap.paycheck(periodEnd: stub.periodEnd)
        #expect(reconciliation?.observedPaidTipsCents == 10000)
        #expect(reconciliation?.paycheck == stub)
        #expect(reconciliation?.expected.scope == .paycheck(periodEnd: stub.periodEnd))
        #expect(reconciliation?.expected.range == stub.period,
                "a stub in hand is a settled period, so it is not clamped")
        #expect(snap.paycheck(periodEnd: day("2001-01-01")) == nil)
        #expect(snap.paycheckReconciliations.count == paychecks.count)
    }

    /// Encode, shuffle the encoded shifts, decode: every query must answer
    /// identically, which is what "rebuilt indexes" has to mean.
    @Test("Codable round-trip preserves every query, even from a shuffled payload")
    func codableRoundTripPreservesEveryQuery() throws {
        var built = try inputs(try FixtureLoader.load("S2"))
        built.paychecks = [PaycheckInput(
            id: UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000001")!,
            periodStart: day("2026-09-21"),
            periodEnd: day("2026-10-04"),
            paidTipsCents: 12345,
            grossPayCents: 40000
        )]
        let original = try EarningsSnapshot.build(built, generation: 7)

        let encoded = try JSONEncoder().encode(original)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json["shifts"] = Array((json["shifts"] as! [Any]).reversed())
        let shuffled = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(EarningsSnapshot.self, from: shuffled)

        #expect(decoded == original, "the re-sort makes a shuffled payload equal")
        #expect(decoded.stamp == original.stamp)
        #expect(decoded.completeness == original.completeness)

        let week = range("2026-09-28", "2026-10-09")
        #expect(decoded.range(week) == original.range(week))
        #expect(decoded.days(in: week) == original.days(in: week))
        #expect(decoded.month(YearMonth(year: 2026, month: 10))
                == original.month(YearMonth(year: 2026, month: 10)))
        #expect(decoded.payPeriod(range("2026-09-21", "2026-10-04"))
                == original.payPeriod(range("2026-09-21", "2026-10-04")))
        #expect(decoded.yearToDate(year: 2026) == original.yearToDate(year: 2026))
        #expect(decoded.day(day("2026-10-09")) == original.day(day("2026-10-09")))
        for id in (1...6).map(shiftID) {
            #expect(decoded.shift(id) == original.shift(id), "\(id)")
            #expect(decoded.valuation(id) == original.valuation(id), "\(id)")
        }
        #expect(decoded.paycheck(periodEnd: day("2026-10-04"))
                == original.paycheck(periodEnd: day("2026-10-04")))
        #expect(decoded.paycheck(periodEnd: day("2026-10-04"))?.observedPaidTipsCents == 12345)
    }

    /// A draft substituted into the inputs is valued through the same
    /// weekly allocation as everything else, so a preview cannot quote a
    /// number the committed shift would not produce.
    @Test("substituting a draft reprices only what the draft changes")
    func draftSubstitution() throws {
        let built = try inputs(try FixtureLoader.load("W2"))
        let base = try EarningsSnapshot.build(built)

        // Friday's 360 minutes become 420: 60 more overtime minutes at
        // 283c * 1.5. Overtime cumulative 283*540*150 = 22_923_000 units ->
        // roundCents = 3821 (22_923_000 * 2 + 6000) / 12000 = 3821 (naive
        // 3820.5, half-up). Thursday's 849 is untouched, so Friday takes
        // 3821 - 849 = 2972.
        var draft = built.shifts.first { $0.id == shiftID(5) }!
        draft.minutesWorked = 420
        let preview = try EarningsSnapshot.build(built.substituting(draft))

        #expect(preview.shift(shiftID(5))?.knownComponents.overtimeWagesCents == 2972)
        #expect(preview.shift(shiftID(4))?.knownComponents
                == base.shift(shiftID(4))?.knownComponents, "an earlier shift never moves")
        #expect(preview.range(range("2026-09-28", "2026-10-04")).knownComponents.earnedIncomeCents
                == 14716 + 425)
        #expect(preview.stamp.digest != base.stamp.digest)
        #expect(preview.stamp.manifest.shiftCount == base.stamp.manifest.shiftCount)

        // A brand-new draft is appended rather than replacing anything.
        let extra = ShiftInput(id: shiftID(9), workDay: day("2026-10-03"), minutesWorked: 60)
        let withExtra = try EarningsSnapshot.build(built.substituting(extra))
        #expect(withExtra.stamp.manifest.shiftCount == base.stamp.manifest.shiftCount + 1)
        #expect(withExtra.shift(shiftID(9)) != nil)
    }
}
