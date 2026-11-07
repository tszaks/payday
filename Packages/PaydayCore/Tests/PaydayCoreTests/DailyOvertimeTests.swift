import Foundation
import Testing
@testable import PaydayCore

/// The optional daily overtime rule (`PayrollCalendarPolicy
/// .dailyOvertimeThresholdMinutes`): minutes past the daily threshold on one
/// payroll day are overtime, they never also count toward the weekly
/// threshold, and every overtime minute uses the one multiplier.
@Suite("Daily overtime")
struct DailyOvertimeTests {
    typealias L = CompensationLedgerTests

    static let monday = CivilDay(year: 2026, month: 10, day: 5)

    static func day(_ offset: Int) -> CivilDay { monday.adding(days: offset) }

    static func calendar(daily: Int?) -> PayrollCalendarPolicy {
        var policy = L.calendarPolicy()
        policy.dailyOvertimeThresholdMinutes = daily
        return policy
    }

    static func value(_ shifts: [ShiftInput], rates: [PayRatePolicy] = [L.rate(1500)], daily: Int? = 480) -> [ShiftValuation] {
        CompensationLedger.value(shifts, rates: rates, calendars: [calendar(daily: daily)])
    }

    static func split(_ v: ShiftValuation) -> (Int?, Int?) { (v.regularMinutes, v.overtimeMinutes) }

    @Test("A 10-hour day: 480 regular, 120 overtime")
    func tenHourDay() {
        let v = Self.value([L.shift(1, Self.monday, minutes: 600)])
        #expect(Self.split(v[0]) == (480, 120))
        #expect(v[0].components.regularWagesCents == 12000)
        #expect(v[0].components.overtimeWagesCents == 4500)
    }

    @Test("Five 10-hour days are 2400 regular + 600 daily overtime, then an 8-hour sixth day is all weekly overtime")
    func noPyramiding() {
        let shifts = (0..<5).map { L.shift($0 + 1, Self.day($0), minutes: 600) } + [L.shift(6, Self.day(5), minutes: 480)]
        let v = Self.value(shifts)
        for i in 0..<5 { #expect(Self.split(v[i]) == (480, 120)) }
        #expect(Self.split(v[5]) == (0, 480))
        #expect(v.map { $0.regularMinutes ?? 0 }.reduce(0, +) == 2400)
        #expect(v.map { $0.overtimeMinutes ?? 0 }.reduce(0, +) == 1080)
    }

    @Test("A 13-hour day is 480 regular + 300 overtime at the one multiplier (no double time)")
    func thirteenHourDay() {
        let v = Self.value([L.shift(1, Self.monday, minutes: 780)])
        #expect(Self.split(v[0]) == (480, 300))
        #expect(v[0].components.overtimeWagesCents == 11250)
    }

    @Test("Two shifts on one day share the daily threshold; the second carries the overtime")
    func twoShiftsOneDay() {
        let v = Self.value([
            L.shift(2, Self.monday, minutes: 300, period: .dinner),
            L.shift(1, Self.monday, minutes: 300, period: .lunch),
        ])
        let byID = L.byID(v)
        #expect(Self.split(byID[L.shift(1, Self.monday, minutes: 0).id]!) == (300, 0))
        #expect(Self.split(byID[L.shift(2, Self.monday, minutes: 0).id]!) == (180, 120))
    }

    @Test("Off: an overtime week values exactly as the weekly-only rule")
    func offIsIdentical() {
        let shifts = [615, 585, 630, 690, 360].enumerated().map { L.shift($0.offset + 1, Self.day($0.offset), minutes: $0.element) }
        let off = Self.value(shifts, rates: [L.rate(283)], daily: nil)
        let plain = CompensationLedger.value(shifts, rates: [L.rate(283)], calendars: [L.calendarPolicy()])
        #expect(off == plain)
        #expect(off.map(\.overtimeMinutes) == [0, 0, 0, 120, 360])
        #expect(off.map(\.components.regularWagesCents) == [2901, 2759, 2972, 2688, 0])
    }

    @Test("Σ shift cents == roundCents(Σ exact units) across daily and weekly overtime")
    func sumPropertyHolds() {
        let rate = 283
        let minutes = [615, 585, 630, 690, 360, 545]
        let shifts = minutes.enumerated().map { L.shift($0.offset + 1, Self.day($0.offset), minutes: $0.element) }
        let v = Self.value(shifts, rates: [L.rate(rate)])
        let regMin = v.map { $0.regularMinutes ?? 0 }.reduce(0, +)
        let otMin = v.map { $0.overtimeMinutes ?? 0 }.reduce(0, +)
        #expect(regMin + otMin == minutes.reduce(0, +))
        #expect(v.map(\.components.regularWagesCents).reduce(0, +)
                == CompensationLedger.roundCents(CompensationLedger.wageUnits(rateCents: rate, minutes: regMin, multiplierHundredths: 100)))
        #expect(v.map(\.components.overtimeWagesCents).reduce(0, +)
                == CompensationLedger.roundCents(CompensationLedger.wageUnits(rateCents: rate, minutes: otMin, multiplierHundredths: 150)))
    }

    @Test("A missing rate still splits the minutes; missing hours split nothing")
    func missingRateStillSplits() {
        let v = Self.value([L.shift(1, Self.monday, minutes: 600), L.shift(2, Self.day(1), minutes: nil)], rates: [])
        #expect(Self.split(v[0]) == (480, 120))
        #expect(v[0].wage == .unavailable(.rateNotSet))
        #expect(Self.split(v[1]) == (nil, nil))
    }

    @Test("A mid-week rate change prices each shift at its own rate under one daily+weekly split")
    func midWeekRateChange() {
        let rates = [L.rate(1500), L.rate(1800, from: Self.day(3))]
        let shifts = (0..<5).map { L.shift($0 + 1, Self.day($0), minutes: 600) }
        let v = Self.value(shifts, rates: rates)
        for i in 0..<5 { #expect(Self.split(v[i]) == (480, 120)) }
        #expect(v[0].components.regularWagesCents == 12000)
        #expect(v[0].components.overtimeWagesCents == 4500)
        // Thursday onwards at 1800c: 480 * 30 = 14400 regular, 120 * 45 = 5400 overtime.
        #expect(v[3].components.regularWagesCents == 14400)
        #expect(v[3].components.overtimeWagesCents == 5400)
    }
}
