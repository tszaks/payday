import Foundation
import Testing
@testable import PaydayCore

/// The ledger, measured against the merged golden fixtures and against every
/// rule in the plan's "Design 1: CompensationLedger".
///
/// Every fixture assertion here drives the REAL
/// `CompensationLedger.value(_:rates:calendars:)` over inputs built by
/// `FixtureLoader`, never a helper that restates the arithmetic. The expected
/// numbers come out of the fixture JSON, so weakening one would have to
/// happen in the fixture, in the open.
@Suite("CompensationLedger")
struct CompensationLedgerTests {

    // MARK: Shared helpers

    /// Runs a fixture through the real ledger.
    static func run(_ id: String) throws -> (fixture: Fixture, output: CompensationLedger.Output) {
        let fixture = try FixtureLoader.load(id)
        let output = CompensationLedger.evaluate(
            fixture.toShiftInputs(),
            rates: fixture.toRatePolicies(),
            calendars: try fixture.toCalendarPolicies()
        )
        return (fixture, output)
    }

    /// `"YYYY-MM"`, the month key the fixtures use.
    static func monthKey(_ day: CivilDay) -> String {
        let month = YearMonth(day)
        return String(format: "%04d-%02d", month.year, month.month)
    }

    static func byID(_ valuations: [ShiftValuation]) -> [UUID: ShiftValuation] {
        Dictionary(uniqueKeysWithValues: valuations.map { ($0.id, $0) })
    }

    /// The 2026 Monday the W-series policies take effect on.
    static let policyStart = CivilDay(year: 2025, month: 12, day: 29)
    static let monday = CivilDay(year: 2026, month: 9, day: 28)

    static func rate(_ cents: Int, from day: CivilDay = policyStart, provenance: RateProvenance = .confirmed) -> PayRatePolicy {
        PayRatePolicy(
            id: FixtureLoader.deterministicUUID("test/rate/\(day.iso)/\(cents)/\(provenance.rawValue)"),
            effectiveFrom: day,
            hourlyRateCents: cents,
            provenance: provenance
        )
    }

    static func calendarPolicy(
        startingOn weekday: Int = 2,
        from day: CivilDay = policyStart,
        thresholdMinutes: Int = 2400,
        multiplierHundredths: Int = 150,
        zone: String = "America/New_York"
    ) -> PayrollCalendarPolicy {
        PayrollCalendarPolicy(
            id: FixtureLoader.deterministicUUID("test/calendar/\(day.iso)/\(weekday)/\(thresholdMinutes)/\(multiplierHundredths)/\(zone)"),
            effectiveFrom: day,
            workweekStartWeekday: weekday,
            overtimeThresholdMinutes: thresholdMinutes,
            overtimeMultiplierHundredths: multiplierHundredths,
            payrollTimeZone: TimeZone(identifier: zone)!
        )
    }

    static func shift(
        _ index: Int,
        _ day: CivilDay,
        minutes: Int?,
        period: ShiftPeriodTag? = .dinner,
        cash: Int = 0,
        credit: Int = 0,
        gratuity: Int = 0,
        tipOut: Int? = nil
    ) -> ShiftInput {
        ShiftInput(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            workDay: day,
            period: period,
            recordedAt: nil,
            voluntaryCashCents: cash,
            voluntaryCreditCents: credit,
            gratuityFeesCents: gratuity,
            tipOutCents: tipOut,
            minutesWorked: minutes
        )
    }

    /// The naive per-shift rounding the plan replaced: `roundCents` applied to
    /// one shift's own exact units. Used only to prove the deviation bound.
    static func naiveCents(rateCents: Int, minutes: Int, multiplierHundredths: Int = 100) -> Int {
        CompensationLedger.roundCents(rateCents * minutes * multiplierHundredths)
    }

    // MARK: W1 — worked example A

    @Test("W1: 255 + 330 minutes at 283c allocate 1203 and 1556, summing to 2759 and never 2760")
    func w1() throws {
        let (fixture, output) = try Self.run("W1")
        let expected = fixture.expected
        let perShift = try #require(expected["perShift"]?.arrayValue)
        #expect(perShift.count == 2)
        #expect(output.valuations.count == 2)

        let byID = Self.byID(output.valuations)
        for row in perShift {
            let id = try #require(row["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let valuation = try #require(byID[id])
            let wage = try #require({ () -> WageComponents? in
                guard case .valued(let components, let assumed) = valuation.wage else { return nil }
                #expect(assumed == (row["assumed"]?.boolValue ?? false))
                return components
            }())

            #expect(valuation.workDay.iso == row["workDay"]?.stringValue)
            #expect(valuation.minutesWorked == row["minutesWorked"]?.intValue)
            #expect(wage.regularMinutes == row["regularMinutes"]?.intValue)
            #expect(wage.overtimeMinutes == row["overtimeMinutes"]?.intValue)
            #expect(wage.regularWagesCents == row["regularWagesCents"]?.intValue)
            #expect(wage.overtimeWagesCents == row["overtimeWagesCents"]?.intValue)
            #expect(valuation.components.wagesCents == row["wagesCents"]?.intValue)
            #expect(valuation.components.nonWageEarningsCents == row["nonWageEarningsCents"]?.intValue)
            #expect(valuation.components.earnedIncomeCents == row["earnedIncomeCents"]?.intValue)

            // The exact numerators the fixture spells out, straight off the
            // arithmetic the ledger uses.
            if let exact = row["exactRegularNumerator"]?.intValue {
                #expect(CompensationLedger.wageUnits(
                    rateCents: 283, minutes: wage.regularMinutes, multiplierHundredths: 100) == exact)
            }
            // `roundCents` of the fixture's stated cumulative numerator is the
            // running total this shift's cents telescope out of, so the
            // allocation and the fixture's own arithmetic have to agree.
            if let cumulative = row["cumulativeRegularNumerator"]?.intValue {
                let allocatedThroughHere = perShift
                    .prefix { ($0["id"]?.stringValue).map { UUID(uuidString: $0) } != id }
                    .compactMap { $0["regularWagesCents"]?.intValue }
                    .reduce(0, +)
                #expect(CompensationLedger.roundCents(cumulative) == allocatedThroughHere + wage.regularWagesCents)
            }
        }

        let week = try #require(expected["week"]?.objectValue)
        let total = output.totalComponents
        #expect(total.regularWagesCents == week["regularWagesCents"]?.intValue)
        #expect(total.overtimeWagesCents == week["overtimeWagesCents"]?.intValue)
        #expect(total.wagesCents == week["wagesCents"]?.intValue)
        #expect(total.earnedIncomeCents == week["earnedIncomeCents"]?.intValue)
        #expect(output.valuations.compactMap(\.minutesWorked).reduce(0, +) == week["minutes"]?.intValue)
        #expect(total.wagesCents == 2759)

        // The superseded per-shift path, asserted wrong.
        let wrong = fixture.wrongAnswers
        #expect(wrong["perShiftRoundingWeekTotal"]?.intValue == 2760)
        #expect(total.wagesCents != 2760)
        let naive = Self.naiveCents(rateCents: 283, minutes: 255) + Self.naiveCents(rateCents: 283, minutes: 330)
        #expect(naive == 2760, "the naive path really does produce the wrong number")
        #expect(Self.naiveCents(rateCents: 283, minutes: 330) == wrong["perShiftRoundingShiftB"]?.intValue)

        #expect(output.completeness.state == .complete)
        #expect(output.valuations.allSatisfy { $0.workweekStart?.iso == expected["workweekStart"]?.stringValue })
    }

    @Test("W1: the week total is roundCents of the exact sum, and each shift is within 1c of its naive rounding")
    func w1Telescopes() throws {
        let (fixture, output) = try Self.run("W1")
        let week = try #require(fixture.expected["week"]?.objectValue)
        let exactSum = 283 * 255 * 100 + 283 * 330 * 100
        #expect(CompensationLedger.roundCents(exactSum) == week["roundCentsOfExactSum"]?.intValue)
        #expect(output.totalComponents.wagesCents == CompensationLedger.roundCents(exactSum))

        let byID = Self.byID(output.valuations)
        for (index, minutes) in [(1, 255), (2, 330)] {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            let allocated = try #require(byID[id]).components.regularWagesCents
            #expect(abs(allocated - Self.naiveCents(rateCents: 283, minutes: minutes)) <= 1)
        }
    }

    // MARK: W2 — worked example B, the month boundary

    @Test("W2: regular 2901/2759/2972/2688/0 = 11320 and overtime 0/0/0/849/2547 = 3396")
    func w2PerShift() throws {
        let (fixture, output) = try Self.run("W2")
        let perShift = try #require(fixture.expected["perShift"]?.arrayValue)
        let byID = Self.byID(output.valuations)
        #expect(output.valuations.count == 5)

        var regulars: [Int] = []
        var overtimes: [Int] = []
        for row in perShift {
            let id = try #require(row["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let valuation = try #require(byID[id])
            guard case .valued(let wage, let assumed) = valuation.wage else {
                Issue.record("shift \(id) was not valued: \(valuation.wage)")
                continue
            }
            #expect(assumed == false)
            #expect(valuation.workDay.iso == row["workDay"]?.stringValue)
            #expect(valuation.minutesWorked == row["minutesWorked"]?.intValue)
            #expect(wage.regularMinutes == row["regularMinutes"]?.intValue)
            #expect(wage.overtimeMinutes == row["overtimeMinutes"]?.intValue)
            #expect(wage.regularWagesCents == row["regularWagesCents"]?.intValue)
            #expect(wage.overtimeWagesCents == row["overtimeWagesCents"]?.intValue)
            #expect(valuation.components.wagesCents == row["wagesCents"]?.intValue)
            #expect(valuation.components.earnedIncomeCents == row["earnedIncomeCents"]?.intValue)
            regulars.append(wage.regularWagesCents)
            overtimes.append(wage.overtimeWagesCents)
        }

        #expect(regulars == [2901, 2759, 2972, 2688, 0])
        #expect(overtimes == [0, 0, 0, 849, 2547])
        let totalRegular: Int = regulars.reduce(0, +)
        let totalOvertime: Int = overtimes.reduce(0, +)
        #expect(totalRegular == 11320)
        #expect(totalOvertime == 3396)
        // 40h and 8h at 283c and 424.5c, to the cent.
        let fortyHoursAt283: Int = 283 * 40
        let eightOvertimeHoursAt283: Int = 283 * 8 * 150 / 100
        #expect(totalRegular == fortyHoursAt283)
        #expect(totalOvertime == eightOvertimeHoursAt283)
    }

    @Test("W2: the week is 14716, the months are 8632 and 6084, and the month-first answer 13585 is wrong")
    func w2Months() throws {
        let (fixture, output) = try Self.run("W2")
        let expectedWeek = try #require(fixture.expected["week"]?.objectValue)
        let total = output.totalComponents
        #expect(total.regularWagesCents == expectedWeek["regularWagesCents"]?.intValue)
        #expect(total.overtimeWagesCents == expectedWeek["overtimeWagesCents"]?.intValue)
        #expect(total.earnedIncomeCents == expectedWeek["earnedIncomeCents"]?.intValue)
        #expect(total.wagesCents == 14716)
        #expect(output.valuations.compactMap(\.minutesWorked).reduce(0, +) == 2880)

        // Every aggregate is Σ components over the selected shifts, so a
        // month is the sum of its days and nothing recomputes a threshold.
        let months = try #require(fixture.expected["months"]?.objectValue)
        var monthTotals: [String: EarningsComponents] = [:]
        for valuation in output.valuations {
            let key = Self.monthKey(valuation.workDay)
            monthTotals[key, default: .zero] = monthTotals[key, default: .zero] + valuation.components
        }

        for (key, expectedMonth) in months {
            let expectedObject = try #require(expectedMonth.objectValue)
            let measured = try #require(monthTotals[key], "no valuations landed in \(key)")
            #expect(measured.regularWagesCents == expectedObject["regularWagesCents"]?.intValue, "\(key) regular")
            #expect(measured.overtimeWagesCents == expectedObject["overtimeWagesCents"]?.intValue, "\(key) overtime")
            #expect(measured.earnedIncomeCents == expectedObject["earnedIncomeCents"]?.intValue, "\(key) earned income")

            let expectedIDs = try #require(expectedObject["shiftIDs"]?.arrayValue).compactMap { $0.stringValue }
            let measuredIDs = output.valuations
                .filter { Self.monthKey($0.workDay) == key }
                .map { $0.id.uuidString.lowercased() }
            #expect(measuredIDs == expectedIDs.map { $0.lowercased() }, "\(key) shift ids")
        }

        #expect(monthTotals["2026-09"]?.earnedIncomeCents == 8632)
        #expect(monthTotals["2026-10"]?.earnedIncomeCents == 6084)
        let sum = monthTotals.values.reduce(EarningsComponents.zero, +).earnedIncomeCents
        #expect(sum == fixture.expected["monthsSumEarnedIncomeCents"]?.intValue)
        #expect(sum == 14716)

        // The wrong answer, computed the wrong way on purpose: valuing
        // October's 1050 minutes in isolation loses the overtime premium.
        let wrong = fixture.wrongAnswers
        let octoberAlone = CompensationLedger.value(
            output.valuations
                .filter { $0.workDay >= CivilDay(year: 2026, month: 10, day: 1) }
                .compactMap { valuation in fixture.toShiftInputs().first { $0.id == valuation.id } },
            rates: fixture.toRatePolicies(),
            calendars: try fixture.toCalendarPolicies()
        ).reduce(EarningsComponents.zero) { $0 + $1.components }
        #expect(octoberAlone.earnedIncomeCents == wrong["monthFirstOctoberEarnedIncomeCents"]?.intValue)
        #expect(octoberAlone.earnedIncomeCents == 4953)
        #expect(8632 + octoberAlone.earnedIncomeCents == wrong["monthFirstTotalEarnedIncomeCents"]?.intValue)
        #expect(8632 + octoberAlone.earnedIncomeCents == 13585)
        #expect(sum - (8632 + octoberAlone.earnedIncomeCents) == wrong["overtimeLostByMonthFirstCents"]?.intValue)
        #expect(sum != 13585)
    }

    @Test("W2: the threshold is split over the complete workweek no matter what range the caller asks for")
    func w2ThresholdIgnoresCallerRange() throws {
        let (fixture, output) = try Self.run("W2")
        let all = fixture.toShiftInputs()
        let byID = Self.byID(output.valuations)

        // Value ONLY Friday, as a caller asking for "October" would. The
        // shift is the same shift, so the cents must be the same cents: the
        // ledger's week bucket is never the caller's range... which is
        // exactly why a caller must hand the ledger every shift, and why
        // valuing a subset is a different (wrong) question.
        let friday = try #require(all.first { $0.workDay == CivilDay(year: 2026, month: 10, day: 2) })
        let subset = CompensationLedger.value([friday], rates: fixture.toRatePolicies(), calendars: try fixture.toCalendarPolicies())
        #expect(subset.count == 1)
        #expect(subset[0].components.overtimeWagesCents == 0, "in isolation Friday looks like regular time")
        #expect(try #require(byID[friday.id]).components.overtimeWagesCents == 2547,
                "over the complete week Friday is entirely overtime")
    }

    // MARK: W3 — the calendar grid owns nothing

    @Test("W3: flipping PaySchedule.firstWeekday changes no valuation")
    func w3() throws {
        let (w2Fixture, w2) = try Self.run("W2")
        let (w3Fixture, w3) = try Self.run("W3")
        #expect(w2Fixture.toScheduleInput()?.firstWeekday == 2)
        #expect(w3Fixture.toScheduleInput()?.firstWeekday == 1)
        #expect(w3.valuations == w2.valuations, "firstWeekday is grid-only")
        #expect(w3.totalComponents == w2.totalComponents)
        #expect(w3.totalComponents.wagesCents == 14716)
        #expect(w3.valuations.allSatisfy { $0.workweekStart == Self.monday })
    }

    // MARK: Z1 — the wage-only shift

    @Test("Z1: a 300-minute shift with no tips is worth 1415c")
    func z1() throws {
        let (fixture, output) = try Self.run("Z1")
        let expectedValuations = try #require(fixture.expected["valuations"]?.arrayValue)
        #expect(output.valuations.count == fixture.expected["shiftCount"]?.intValue)

        let byID = Self.byID(output.valuations)
        for row in expectedValuations {
            let id = try #require(row["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let valuation = try #require(byID[id])
            guard case .valued(let wage, let assumed) = valuation.wage else {
                Issue.record("Z1 shift was not valued: \(valuation.wage)")
                continue
            }
            #expect(assumed == row["assumed"]?.boolValue)
            #expect(valuation.workweekStart?.iso == row["workweekStart"]?.stringValue)
            #expect(wage.regularMinutes == row["regularMinutes"]?.intValue)
            #expect(wage.overtimeMinutes == row["overtimeMinutes"]?.intValue)

            let components = try #require(row["components"]?.objectValue)
            #expect(valuation.components.regularWagesCents == components["regularWagesCents"]?.intValue)
            #expect(valuation.components.overtimeWagesCents == components["overtimeWagesCents"]?.intValue)
            #expect(valuation.components.nonWageEarningsCents == components["nonWageEarningsCents"]?.intValue)
            #expect(valuation.components.wagesCents == components["wagesCents"]?.intValue)
            #expect(valuation.components.earnedIncomeCents == components["earnedIncomeCents"]?.intValue)
            #expect(valuation.components.regularWagesCents == 1415)
        }

        let day = try #require(fixture.expected["day"]?.objectValue)
        #expect(output.totalComponents.earnedIncomeCents == day["earnedIncomeCents"]?.intValue)
        let month = try #require(fixture.expected["month"]?.objectValue)
        #expect(output.totalComponents.regularWagesCents == month["regularWagesCents"]?.intValue)

        let completeness = try #require(fixture.expected["completeness"]?.objectValue)
        let measured = output.completeness
        #expect(measured.totalShifts == completeness["totalShifts"]?.intValue)
        #expect(measured.shiftsWithHours == completeness["shiftsWithHours"]?.intValue)
        #expect(measured.shiftsWageValued == completeness["shiftsWageValued"]?.intValue)
        #expect(measured.shiftsWageAssumed == completeness["shiftsWageAssumed"]?.intValue)
        #expect(measured.wageFeatureEnabled == completeness["wageFeatureEnabled"]?.boolValue)
        #expect(measured.state == .complete)

        let wrong = fixture.wrongAnswers
        #expect(wrong["todayShiftNotPersistedEarnedIncomeCents"]?.intValue == 0)
        #expect(output.totalComponents.earnedIncomeCents != 0)
    }

    // MARK: The threshold

    @Test("Exactly 40 hours in a week is all regular time")
    func exactlyFortyHours() {
        let shifts = (1...5).map { index in
            Self.shift(index, Self.monday.adding(days: index - 1), minutes: 480)
        }
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy()])
        let total = output.totalComponents
        #expect(output.valuations.allSatisfy { $0.wage.components.overtimeMinutes == 0 })
        #expect(total.overtimeWagesCents == 0)
        #expect(total.regularWagesCents == 283 * 40)
        #expect(total.regularWagesCents == 11320)
    }

    @Test("45 hours in a week gives 5 hours of overtime")
    func fortyFiveHours() {
        let shifts = (1...5).map { index in
            Self.shift(index, Self.monday.adding(days: index - 1), minutes: 540)
        }
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy()])
        let total = output.totalComponents
        #expect(output.valuations.reduce(0) { $0 + $1.wage.components.overtimeMinutes } == 300)
        #expect(output.valuations.reduce(0) { $0 + $1.wage.components.regularMinutes } == 2400)
        #expect(total.regularWagesCents == 283 * 40)
        // 5h at 1.5x: 283 * 300 minutes * 150 = 12,735,000 units = 2122.5c, half-up 2123.
        #expect(total.overtimeWagesCents == 2123)
    }

    @Test("A shift straddling the threshold splits 570 regular and 120 overtime minutes")
    func straddlingShift() throws {
        let shifts = [
            Self.shift(1, Self.monday, minutes: 615),
            Self.shift(2, Self.monday.adding(days: 1), minutes: 585),
            Self.shift(3, Self.monday.adding(days: 2), minutes: 630),
            Self.shift(4, Self.monday.adding(days: 3), minutes: 690)
        ]
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy()])
        let thursday = try #require(Self.byID(output.valuations)[shifts[3].id])
        #expect(thursday.wage.components.regularMinutes == 570)
        #expect(thursday.wage.components.overtimeMinutes == 120)
        #expect(thursday.wage.components.regularWagesCents == 2688)
        #expect(thursday.wage.components.overtimeWagesCents == 849)
    }

    @Test("Two weeks bucket independently: 30 hours in each week is never overtime")
    func twoWeeksAreIndependent() {
        let firstWeek = (1...3).map { Self.shift($0, Self.monday.adding(days: $0 - 1), minutes: 600) }
        let secondWeek = (4...6).map { Self.shift($0, Self.monday.adding(days: 7 + $0 - 4), minutes: 600) }
        let output = CompensationLedger.evaluate(
            firstWeek + secondWeek,
            rates: [Self.rate(283)],
            calendars: [Self.calendarPolicy()]
        )
        #expect(output.totalComponents.overtimeWagesCents == 0)
        #expect(Set(output.valuations.compactMap(\.workweekStart)).count == 2)
        // 60 hours across two weeks, each under the threshold.
        #expect(output.totalComponents.regularWagesCents == 283 * 60)
    }

    @Test("The workweek start decides the bucketing: Sat+Sun 25h each is 10h overtime Monday-start and none Sunday-start")
    func workweekStartDrivesBucketing() {
        // Sat 2026-10-03 and Sun 2026-10-04: one Monday-start week, two
        // Sunday-start weeks.
        let saturday = CivilDay(year: 2026, month: 10, day: 3)
        let sunday = CivilDay(year: 2026, month: 10, day: 4)
        let shifts = [
            Self.shift(1, saturday, minutes: 1500),
            Self.shift(2, sunday, minutes: 1500)
        ]

        let mondayStart = CompensationLedger.evaluate(
            shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy(startingOn: 2)]
        )
        #expect(Set(mondayStart.valuations.compactMap(\.workweekStart)).count == 1)
        #expect(mondayStart.valuations.reduce(0) { $0 + $1.wage.components.overtimeMinutes } == 600)

        // A Sunday-start policy has to take effect on a Sunday to be a valid
        // first policy boundary for the following weeks; the first policy in a
        // list is accepted as written either way.
        let sundayStart = CompensationLedger.evaluate(
            shifts,
            rates: [Self.rate(283, from: CivilDay(year: 2025, month: 12, day: 28))],
            calendars: [Self.calendarPolicy(startingOn: 1, from: CivilDay(year: 2025, month: 12, day: 28))]
        )
        #expect(Set(sundayStart.valuations.compactMap(\.workweekStart)).count == 2)
        #expect(sundayStart.valuations.reduce(0) { $0 + $1.wage.components.overtimeMinutes } == 0)
        #expect(sundayStart.totalComponents.overtimeWagesCents == 0)
    }

    @Test("383/60 hours is 383 minutes and 1806c")
    func exactHours() {
        #expect(WorkedMinutes.minutes(fromHours: 383.0 / 60.0) == 383)
        let shifts = [Self.shift(1, Self.monday, minutes: WorkedMinutes.minutes(fromHours: 383.0 / 60.0))]
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy()])
        #expect(output.valuations[0].minutesWorked == 383)
        #expect(output.totalComponents.regularWagesCents == 1806)
        #expect(WorkedMinutes.hoursLabel(minutes: 383) == "6h 23m")
    }

    // MARK: Rounding

    @Test("Rounding is half-up at the cumulative step, not per shift")
    func halfUpAtTheCumulativeStep() {
        // 30 minutes at 1c/h is exactly half a cent: 1 * 30 * 100 = 3000
        // units = 0.5c. Half-up on the cumulative gives the first shift 1c
        // and the second 0c, and two of them are exactly 1c together.
        let shifts = [
            Self.shift(1, Self.monday, minutes: 30),
            Self.shift(2, Self.monday.adding(days: 1), minutes: 30)
        ]
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(1)], calendars: [Self.calendarPolicy()])
        let allocated = output.valuations.map(\.components.regularWagesCents)
        #expect(allocated == [1, 0])
        #expect(allocated.reduce(0, +) == 1)
        #expect(CompensationLedger.roundCents(3000) == 1, "half a cent rounds up")
        #expect(CompensationLedger.roundCents(6000) == 1)
        #expect(CompensationLedger.roundCents(2999) == 0)
        #expect(CompensationLedger.roundCents(0) == 0)
    }

    @Test("Appending a later shift never changes an earlier shift's cents")
    func appendingNeverMovesEarlierShifts() {
        var shifts = [Self.shift(1, Self.monday, minutes: 255)]
        let rates = [Self.rate(283)]
        let calendars = [Self.calendarPolicy()]
        var history: [UUID: Int] = [:]

        // Days increase monotonically, so each appended shift really is
        // LATER in the engine's canonical order (and days 8 onward land in
        // the following workweek, which is the other half of the rule).
        for index in 2...12 {
            let output = CompensationLedger.evaluate(shifts, rates: rates, calendars: calendars)
            for valuation in output.valuations {
                if let previous = history[valuation.id] {
                    #expect(previous == valuation.components.wagesCents,
                            "shift \(valuation.id) moved from \(previous) to \(valuation.components.wagesCents) after appending")
                }
                history[valuation.id] = valuation.components.wagesCents
            }
            shifts.append(Self.shift(index, Self.monday.adding(days: index - 1), minutes: 420 + index * 11))
        }
        #expect(history.count == 11)
        // The run really did cross a threshold and a week boundary, so the
        // rule was exercised against overtime rather than a flat week.
        let final = CompensationLedger.evaluate(shifts, rates: rates, calendars: calendars)
        #expect(final.valuations.contains { $0.wage.components.overtimeMinutes > 0 })
        #expect(Set(final.valuations.compactMap(\.workweekStart)).count == 2)
    }

    @Test("200 seeded-random weeks: per-shift cents telescope to the week total and each is within 1c of naive")
    func seededRandomWeeksTelescope() {
        var generator = SplitMix64(seed: 0x5EED_1234_ABCD_0001)
        var weeksChecked = 0

        for week in 0..<200 {
            let rateCents = Int(generator.next(upperBound: 4000)) + 1
            let shiftCount = Int(generator.next(upperBound: 9)) + 1
            let weekStart = Self.monday.adding(days: 7 * week)
            var shifts: [ShiftInput] = []
            for index in 0..<shiftCount {
                let minutes = Int(generator.next(upperBound: 780)) + 1
                shifts.append(Self.shift(
                    week * 100 + index + 1,
                    weekStart.adding(days: index % 7),
                    minutes: minutes,
                    period: index % 2 == 0 ? .lunch : .dinner
                ))
            }

            let policy = Self.calendarPolicy()
            let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(rateCents)], calendars: [policy])
            #expect(output.valuations.count == shifts.count)

            // Recompute the exact cumulative units independently of the
            // ledger's allocation and check the sum telescopes to it.
            var cumulativeMinutes = 0
            var regularUnits = 0
            var overtimeUnits = 0
            for shift in shifts.sorted(by: CompensationLedger.canonicalOrder) {
                let minutes = shift.minutesWorked ?? 0
                let regular = min(max(0, policy.overtimeThresholdMinutes - cumulativeMinutes), minutes)
                let overtime = minutes - regular
                cumulativeMinutes += minutes
                regularUnits += rateCents * regular * 100
                overtimeUnits += rateCents * overtime * 150
            }

            let allocatedRegular = output.valuations.reduce(0) { $0 + $1.components.regularWagesCents }
            let allocatedOvertime = output.valuations.reduce(0) { $0 + $1.components.overtimeWagesCents }
            #expect(allocatedRegular == CompensationLedger.roundCents(regularUnits), "week \(week) regular")
            #expect(allocatedOvertime == CompensationLedger.roundCents(overtimeUnits), "week \(week) overtime")

            for valuation in output.valuations {
                let wage = valuation.wage.components
                let naiveRegular = Self.naiveCents(rateCents: rateCents, minutes: wage.regularMinutes)
                let naiveOvertime = Self.naiveCents(rateCents: rateCents, minutes: wage.overtimeMinutes, multiplierHundredths: 150)
                #expect(abs(wage.regularWagesCents - naiveRegular) <= 1, "week \(week) shift \(valuation.id) regular deviation")
                #expect(abs(wage.overtimeWagesCents - naiveOvertime) <= 1, "week \(week) shift \(valuation.id) overtime deviation")
            }
            weeksChecked += 1
        }

        #expect(weeksChecked == 200)
    }

    // MARK: Order independence

    @Test("Shuffled input produces identical output")
    func shuffledInputIsIdentical() {
        let shifts = (1...9).map { index in
            Self.shift(
                index,
                Self.monday.adding(days: (index - 1) % 7),
                minutes: 120 + index * 37,
                period: index % 3 == 0 ? nil : (index % 2 == 0 ? .lunch : .dinner)
            )
        }
        let rates = [Self.rate(283)]
        let calendars = [Self.calendarPolicy()]
        let reference = CompensationLedger.value(shifts, rates: rates, calendars: calendars)

        var generator = SplitMix64(seed: 0xA11CE)
        for _ in 0..<25 {
            var shuffled = shifts
            // Fisher-Yates with the seeded generator: deterministic shuffles.
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                let j = Int(generator.next(upperBound: UInt64(i + 1)))
                shuffled.swapAt(i, j)
            }
            #expect(CompensationLedger.value(shuffled, rates: rates, calendars: calendars) == reference)
        }

        // Policy order must not matter either.
        #expect(CompensationLedger.value(shifts, rates: rates.reversed(), calendars: calendars.reversed()) == reference)
    }

    // MARK: Rate policies

    @Test("A rate change mid-week keeps the overtime threshold continuous")
    func rateChangeMidWeek() throws {
        // 48 hours Monday to Friday, with the rate rising on Wednesday. The
        // threshold still falls mid-Thursday: it counts minutes, not money.
        let minutes = [615, 585, 630, 690, 360]
        let shifts = minutes.enumerated().map { index, m in
            Self.shift(index + 1, Self.monday.adding(days: index), minutes: m)
        }
        let rates = [
            Self.rate(283),
            Self.rate(400, from: Self.monday.adding(days: 2))
        ]
        let output = CompensationLedger.evaluate(shifts, rates: rates, calendars: [Self.calendarPolicy()])
        let byID = Self.byID(output.valuations)

        // Same split as W2: the threshold is minute-based and rate-blind.
        #expect(try #require(byID[shifts[3].id]).wage.components.regularMinutes == 570)
        #expect(try #require(byID[shifts[3].id]).wage.components.overtimeMinutes == 120)
        #expect(try #require(byID[shifts[4].id]).wage.components.overtimeMinutes == 360)

        // Monday and Tuesday at 283c, Wednesday onward at 400c.
        #expect(try #require(byID[shifts[0].id]).ratePolicyID == rates[0].id)
        #expect(try #require(byID[shifts[2].id]).ratePolicyID == rates[1].id)

        // Regular: 283*(615+585) + 400*570... measured on the cumulative.
        let exactRegular = 283 * 615 * 100 + 283 * 585 * 100 + 400 * 630 * 100 + 400 * 570 * 100
        let exactOvertime = 400 * 120 * 150 + 400 * 360 * 150
        #expect(output.totalComponents.regularWagesCents == CompensationLedger.roundCents(exactRegular))
        #expect(output.totalComponents.overtimeWagesCents == CompensationLedger.roundCents(exactOvertime))
    }

    @Test("A rate change on date X reprices only the shifts on or after X")
    func rateChangeRepricesForward() {
        let shifts = [
            Self.shift(1, Self.monday, minutes: 300),
            Self.shift(2, Self.monday.adding(days: 7), minutes: 300)
        ]
        let before = CompensationLedger.value(shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy()])
        let after = CompensationLedger.value(
            shifts,
            rates: [Self.rate(283), Self.rate(500, from: Self.monday.adding(days: 7))],
            calendars: [Self.calendarPolicy()]
        )
        #expect(before[0].components == after[0].components, "the earlier week did not move")
        #expect(before[1].components.regularWagesCents == 1415)
        #expect(after[1].components.regularWagesCents == 2500)
    }

    @Test("A shift with no rate policy in effect counts its minutes toward the threshold and reports rateNotSet")
    func nilRateStillConsumesTheThreshold() throws {
        // Monday's 2400 minutes have no rate (the rate starts Tuesday), so
        // Tuesday's shift is entirely overtime even though Monday is
        // unvalued.
        let shifts = [
            Self.shift(1, Self.monday, minutes: 2400),
            Self.shift(2, Self.monday.adding(days: 1), minutes: 300)
        ]
        let output = CompensationLedger.evaluate(
            shifts,
            rates: [Self.rate(283, from: Self.monday.adding(days: 1))],
            calendars: [Self.calendarPolicy()]
        )
        let byID = Self.byID(output.valuations)
        let unvalued = try #require(byID[shifts[0].id])
        #expect(unvalued.wage == .unavailable(.rateNotSet))
        #expect(unvalued.minutesWorked == 2400)
        #expect(unvalued.ratePolicyID == nil)
        #expect(unvalued.components.wagesCents == 0)

        let valued = try #require(byID[shifts[1].id])
        #expect(valued.wage.components.regularMinutes == 0)
        #expect(valued.wage.components.overtimeMinutes == 300)
        #expect(valued.components.overtimeWagesCents == CompensationLedger.roundCents(283 * 300 * 150))

        #expect(output.completeness.state == .partial(missingHours: 0, missingRate: 1))
    }

    @Test("A shift with no hours reports hoursMissing, keeps its tips, and consumes no threshold")
    func missingHours() throws {
        let shifts = [
            Self.shift(1, Self.monday, minutes: nil, cash: 4000, credit: 2500, tipOut: 500),
            Self.shift(2, Self.monday.adding(days: 1), minutes: 2400)
        ]
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy()])
        let byID = Self.byID(output.valuations)
        let hoursless = try #require(byID[shifts[0].id])
        #expect(hoursless.wage == .unavailable(.hoursMissing))
        #expect(hoursless.minutesWorked == nil)
        #expect(hoursless.components.nonWageEarningsCents == 4000 + 2500 - 500)
        #expect(hoursless.components.wagesCents == 0)

        let full = try #require(byID[shifts[1].id])
        #expect(full.wage.components.overtimeMinutes == 0, "the hoursless shift consumed none of the threshold")
        #expect(full.components.regularWagesCents == 283 * 40)

        #expect(output.completeness.state == .partial(missingHours: 1, missingRate: 0))
    }

    @Test("Assumed rate provenance propagates as assumed: true and reads as estimated")
    func assumedProvenancePropagates() {
        let shifts = [Self.shift(1, Self.monday, minutes: 300)]
        let output = CompensationLedger.evaluate(
            shifts,
            rates: [Self.rate(283, provenance: .assumedFromLegacySetting)],
            calendars: [Self.calendarPolicy()]
        )
        #expect(output.valuations[0].wage == .valued(
            WageComponents(regularMinutes: 300, overtimeMinutes: 0, regularWagesCents: 1415, overtimeWagesCents: 0),
            assumed: true
        ))
        #expect(output.valuations[0].wage.isAssumed)
        #expect(output.completeness.state == .estimated)
        // The cents are unchanged by the provenance: only the label moves.
        #expect(output.totalComponents.regularWagesCents == 1415)
    }

    @Test("With no rate policy at all the wage feature is off and every wage is rateNotSet")
    func noRatePolicyAtAll() {
        let shifts = [Self.shift(1, Self.monday, minutes: 300, cash: 9000)]
        let output = CompensationLedger.evaluate(shifts, rates: [], calendars: [Self.calendarPolicy()])
        #expect(output.valuations[0].wage == .unavailable(.rateNotSet))
        #expect(output.wageFeatureEnabled == false)
        #expect(output.completeness.state == .off)
        #expect(output.totalComponents.earnedIncomeCents == 9000)
    }

    // MARK: Calendar policies

    @Test("A shift before the earliest calendar policy reports noCalendarPolicy and carries tips only")
    func shiftBeforeAnyCalendarPolicy() {
        let shifts = [Self.shift(1, CivilDay(year: 2024, month: 5, day: 6), minutes: 300, cash: 5000)]
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy()])
        #expect(output.valuations[0].wage == .unavailable(.noCalendarPolicy))
        #expect(output.valuations[0].workweekStart == nil)
        #expect(output.valuations[0].calendarPolicyID == nil)
        #expect(output.valuations[0].components.nonWageEarningsCents == 5000)
        #expect(output.valuations[0].components.wagesCents == 0)
    }

    @Test("A calendar policy that does not take effect on a workweek boundary is rejected with a diagnostic")
    func offBoundaryCalendarPolicyIsRejected() {
        // The first policy is Monday-start from Mon 2025-12-29. A second
        // policy taking effect on Wed 2026-09-30 is not a Monday, so it is
        // not a workweek start under the policy it would replace.
        let good = Self.calendarPolicy(startingOn: 2)
        let offBoundary = Self.calendarPolicy(startingOn: 1, from: CivilDay(year: 2026, month: 9, day: 30))
        let shifts = [Self.shift(1, CivilDay(year: 2026, month: 10, day: 3), minutes: 1500),
                      Self.shift(2, CivilDay(year: 2026, month: 10, day: 4), minutes: 1500)]

        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [good, offBoundary])
        #expect(output.acceptedCalendarPolicies.map(\.id) == [good.id])
        #expect(output.diagnostics.count == 1)
        #expect(output.diagnostics.first?.kind == .calendarPolicyOffWorkweekBoundary)
        #expect(output.diagnostics.first?.policyID == offBoundary.id)
        // The previous policy stays in effect, so Sat+Sun are still one
        // Monday-start week and the overtime is still there.
        #expect(output.valuations.allSatisfy { $0.calendarPolicyID == good.id })
        #expect(Set(output.valuations.compactMap(\.workweekStart)).count == 1)
        #expect(output.valuations.reduce(0) { $0 + $1.wage.components.overtimeMinutes } == 600)

        // And the clean pair raises nothing.
        let onBoundary = Self.calendarPolicy(startingOn: 1, from: CivilDay(year: 2026, month: 9, day: 28))
        let clean = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [good, onBoundary])
        #expect(clean.diagnostics.isEmpty)
        #expect(clean.acceptedCalendarPolicies.map(\.id) == [good.id, onBoundary.id])
    }

    @Test("An accepted second calendar policy takes over from its effective date")
    func secondCalendarPolicyTakesOver() throws {
        let first = Self.calendarPolicy(startingOn: 2)
        // Mon 2026-09-28 is a workweek start under `first`, so a Sunday-start
        // policy may begin there.
        let second = Self.calendarPolicy(startingOn: 1, from: Self.monday)
        let shifts = [
            Self.shift(1, Self.monday.adding(days: -2), minutes: 300),
            Self.shift(2, Self.monday.adding(days: 6), minutes: 300)
        ]
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [first, second])
        let byID = Self.byID(output.valuations)
        #expect(try #require(byID[shifts[0].id]).calendarPolicyID == first.id)
        #expect(try #require(byID[shifts[1].id]).calendarPolicyID == second.id)
        // Sun 2026-10-04 under a Sunday-start policy begins its own week.
        #expect(try #require(byID[shifts[1].id]).workweekStart == CivilDay(year: 2026, month: 10, day: 4))
    }

    @Test("A different threshold and multiplier are honoured")
    func customThresholdAndMultiplier() {
        let policy = Self.calendarPolicy(thresholdMinutes: 2700, multiplierHundredths: 200)
        let shifts = [Self.shift(1, Self.monday, minutes: 3000)]
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [policy])
        let wage = output.valuations[0].wage.components
        #expect(wage.regularMinutes == 2700)
        #expect(wage.overtimeMinutes == 300)
        #expect(wage.regularWagesCents == CompensationLedger.roundCents(283 * 2700 * 100))
        #expect(wage.overtimeWagesCents == CompensationLedger.roundCents(283 * 300 * 200))
    }

    // MARK: Work-day attribution

    @Test("An overnight shift stays whole on its work day and never splits across a workweek boundary")
    func overnightShiftStaysOnItsWorkDay() throws {
        // Sunday 2026-10-04 is the last day of the Monday-start week. A shift
        // clocked in that night and out after midnight is one shift, on
        // Sunday, entirely inside that week.
        let sunday = CivilDay(year: 2026, month: 10, day: 4)
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let clockIn = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 18, minute: 0))!
        let clockOut = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 2, minute: 30))!
        let minutes = Int(clockOut.timeIntervalSince(clockIn) / 60)
        #expect(minutes == 510)
        // The work day is the civil day of the CLOCK-IN in the payroll zone,
        // which is what the adapter writes onto the record.
        #expect(CivilDay(clockIn, in: zone) == sunday)
        #expect(CivilDay(clockOut, in: zone) == sunday.adding(days: 1))

        let shifts = [
            Self.shift(1, Self.monday, minutes: 2400),
            Self.shift(2, sunday, minutes: minutes)
        ]
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy()])
        let overnight = try #require(Self.byID(output.valuations)[shifts[1].id])
        #expect(overnight.workDay == sunday)
        #expect(overnight.workweekStart == Self.monday)
        #expect(overnight.wage.components.regularMinutes == 0)
        #expect(overnight.wage.components.overtimeMinutes == 510, "all 510 minutes land in the same week, none in the next")
        #expect(output.valuations.count == 2)
    }

    // MARK: Diagnostics

    @Test("Negative minutes are clamped to zero with a diagnostic rather than running the threshold backwards")
    func negativeMinutesAreClamped() {
        let shifts = [
            Self.shift(1, Self.monday, minutes: -60),
            Self.shift(2, Self.monday.adding(days: 1), minutes: 300)
        ]
        let output = CompensationLedger.evaluate(shifts, rates: [Self.rate(283)], calendars: [Self.calendarPolicy()])
        #expect(output.diagnostics.contains { $0.kind == .negativeMinutesClamped && $0.shiftID == shifts[0].id })
        #expect(output.valuations[0].minutesWorked == 0)
        #expect(output.totalComponents.regularWagesCents == 1415)
    }
}

/// The ledger reads no time zone at all, so proving "a device time zone
/// change alters no valuation" means actually moving the process's zone.
/// `NSTimeZone.default` does that; the suite is serialized because it is
/// process-global state.
@Suite("CompensationLedger device time zone", .serialized)
struct CompensationLedgerTimeZoneTests {

    /// Runs `body` with the process time zone genuinely moved to
    /// `identifier`, restoring whatever was there before.
    ///
    /// Measured on macOS 26 / Xcode 26.6, not assumed: setting
    /// `NSTimeZone.default` alone moves `Calendar.current.timeZone` but
    /// leaves `TimeZone.current` where it was, so a test that only set it
    /// would pass while `TimeZone.current` never actually changed. `TZ` plus
    /// `NSTimeZone.resetSystemTimeZone()` moves `TimeZone.current`; both are
    /// set here so either read path a caller might use really is somewhere
    /// else, and the two assertions below prove it before `body` runs.
    static func withDeviceTimeZone<T>(_ identifier: String, _ body: () throws -> T) throws -> T {
        let zone = try #require(TimeZone(identifier: identifier))
        let previousDefault = NSTimeZone.default
        let previousTZ = ProcessInfo.processInfo.environment["TZ"]

        setenv("TZ", identifier, 1)
        NSTimeZone.resetSystemTimeZone()
        NSTimeZone.default = zone
        defer {
            if let previousTZ {
                setenv("TZ", previousTZ, 1)
            } else {
                unsetenv("TZ")
            }
            NSTimeZone.resetSystemTimeZone()
            NSTimeZone.default = previousDefault
        }

        #expect(TimeZone.current.identifier == identifier, "TimeZone.current did not move")
        #expect(Calendar.current.timeZone.identifier == identifier, "Calendar.current.timeZone did not move")
        return try body()
    }

    @Test("T1: valuing W2 in America/New_York and in Pacific/Honolulu gives byte-identical results")
    func t1() throws {
        let fixture = try FixtureLoader.load("T1")
        let expected = fixture.expected
        #expect(expected["payrollTimeZoneUsed"]?.stringValue == "America/New_York")
        #expect(fixture.deviceTimeZone == "Pacific/Honolulu")
        let zones = try #require(expected["deviceTimeZonesEvaluated"]?.arrayValue).compactMap(\.stringValue)
        #expect(zones == ["America/New_York", "Pacific/Honolulu"])

        var runs: [String: [ShiftValuation]] = [:]
        for zone in zones {
            runs[zone] = try Self.withDeviceTimeZone(zone) {
                CompensationLedger.value(
                    fixture.toShiftInputs(),
                    rates: fixture.toRatePolicies(),
                    calendars: try fixture.toCalendarPolicies()
                )
            }
        }
        let first = try #require(runs["America/New_York"])
        let second = try #require(runs["Pacific/Honolulu"])
        #expect(first == second, "a device time zone change moved money")
        #expect(expected["valuationsIdenticalAcrossDeviceTimeZones"]?.boolValue == true)

        // And identical to W2, whose inputs T1 copies.
        let w2 = try FixtureLoader.load("W2")
        let w2Valuations = CompensationLedger.value(
            w2.toShiftInputs(), rates: w2.toRatePolicies(), calendars: try w2.toCalendarPolicies()
        )
        #expect(first == w2Valuations)
        #expect(expected["valuationsIdenticalToFixture"]?.stringValue == "W2")

        // The per-shift numbers T1 spells out, measured under Honolulu.
        let perShift = try #require(expected["perShift"]?.arrayValue)
        let byID = Dictionary(uniqueKeysWithValues: second.map { ($0.id, $0) })
        for row in perShift {
            let id = try #require(row["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let valuation = try #require(byID[id])
            #expect(valuation.workDay.iso == row["workDay"]?.stringValue)
            #expect(valuation.workweekStart?.iso == row["workweekStart"]?.stringValue)
            #expect(valuation.wage.components.regularWagesCents == row["regularWagesCents"]?.intValue)
            #expect(valuation.wage.components.overtimeWagesCents == row["overtimeWagesCents"]?.intValue)
            #expect(valuation.components.earnedIncomeCents == row["earnedIncomeCents"]?.intValue)
        }
        #expect(second.reduce(EarningsComponents.zero) { $0 + $1.components }.wagesCents == 14716)
    }

    @Test("The civil day a shift is attributed to comes from the frozen payroll zone, not the device")
    func payrollZoneIsFrozen() throws {
        // 2026-10-05 00:30 in New York is still 2026-10-04 in Honolulu. The
        // work day the adapter writes must come from the POLICY's zone, so
        // the same instant lands on the same day whatever the device says.
        let instant = ISO8601DateFormatter().date(from: "2026-10-05T00:30:00Z")!
        let payrollZone = TimeZone(identifier: "America/New_York")!

        for deviceZone in ["America/New_York", "Pacific/Honolulu", "Asia/Tokyo"] {
            let day = try Self.withDeviceTimeZone(deviceZone) {
                CivilDay(instant, in: payrollZone)
            }
            #expect(day == CivilDay(year: 2026, month: 10, day: 4),
                    "device zone \(deviceZone) changed the payroll civil day")
        }
    }
}

/// A small deterministic generator, so the 200-week property test runs the
/// same weeks on every machine and in every CI run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<upperBound` by rejection, so the sequence is not
    /// biased by a modulo.
    mutating func next(upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0)
        let limit = UInt64.max - (UInt64.max % upperBound)
        var value = next()
        while value >= limit { value = next() }
        return value % upperBound
    }
}
