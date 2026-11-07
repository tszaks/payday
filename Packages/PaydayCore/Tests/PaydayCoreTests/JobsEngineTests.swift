import Foundation
import Testing
@testable import PaydayCore

/// PR E2a: the engine prices and runs overtime per job. Nil-tagged shifts
/// and policies are the primary job; "Cafe" is a second job. Every money
/// figure is a made-up test value.
@Suite("Jobs: engine per job")
struct JobsEngineTests {
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func day(_ iso: String) -> CivilDay { CivilDay(iso: iso)! }

    static let zone = TimeZone(identifier: "America/New_York")!

    static let primaryRate = PayRatePolicy(
        id: uuid(1), effectiveFrom: day("2026-01-01"), hourlyRateCents: 1000, provenance: .confirmed)
    static let cafeRate = PayRatePolicy(
        id: uuid(2), effectiveFrom: day("2026-01-01"), hourlyRateCents: 1200, provenance: .confirmed,
        jobName: "Cafe")
    static let primaryCalendar = PayrollCalendarPolicy(
        id: uuid(3), effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone)
    static let cafeCalendar = PayrollCalendarPolicy(
        id: uuid(4), effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone,
        jobName: "Cafe")

    /// Mon 2026-01-05 to Fri 2026-01-09, one workweek, 10 h a day: three
    /// primary days (30 h) and two Cafe days (20 h).
    static func week(cafe: String? = "Cafe") -> [ShiftInput] {
        let primary = ["2026-01-05", "2026-01-06", "2026-01-07"].enumerated().map { i, d in
            ShiftInput(id: uuid(100 + i), workDay: day(d), voluntaryCashCents: 1000, minutesWorked: 600)
        }
        let second = ["2026-01-08", "2026-01-09"].enumerated().map { i, d in
            ShiftInput(id: uuid(200 + i), workDay: day(d), voluntaryCashCents: 1000, minutesWorked: 600, jobName: cafe)
        }
        return primary + second
    }

    static var primaryIDs: [UUID] { (0..<3).map { uuid(100 + $0) } }
    static var cafeIDs: [UUID] { (0..<2).map { uuid(200 + $0) } }

    static func overtime(_ valuations: [ShiftValuation]) -> Int {
        valuations.reduce(0) { $0 + ($1.overtimeMinutes ?? 0) }
    }

    @Test("Two jobs in one workweek, 30 h + 20 h: no overtime")
    func twoJobsNoOvertime() {
        let out = CompensationLedger.evaluate(
            Self.week(), rates: [Self.primaryRate, Self.cafeRate],
            calendars: [Self.primaryCalendar, Self.cafeCalendar])
        #expect(Self.overtime(out.valuations) == 0)
        #expect(out.valuations.allSatisfy { $0.wage.isValued })
        #expect(out.valuations.filter { $0.jobName == "Cafe" }.map(\.id) == Self.cafeIDs)
        #expect(out.diagnostics.isEmpty)
    }

    @Test("The same shifts on one job: 10 h overtime")
    func oneJobHasOvertime() {
        let out = CompensationLedger.evaluate(
            Self.week(cafe: nil), rates: [Self.primaryRate], calendars: [Self.primaryCalendar])
        #expect(Self.overtime(out.valuations) == 600)
        #expect(out.valuations.allSatisfy { $0.jobName == nil })
    }

    @Test("A job-tagged rate prices only that job's shifts")
    func jobRatePricesOnlyItsJob() {
        let out = CompensationLedger.evaluate(
            Self.week(), rates: [Self.primaryRate, Self.cafeRate],
            calendars: [Self.primaryCalendar, Self.cafeCalendar])
        for v in out.valuations {
            #expect(v.ratePolicyID == (Self.cafeIDs.contains(v.id) ? Self.cafeRate.id : Self.primaryRate.id))
        }
        // 10 h at the made-up 1200c Cafe rate, straight time.
        #expect(out.valuations.first { $0.id == Self.cafeIDs[0] }?.components.regularWagesCents == 12000)

        // Without a Cafe rate, Cafe shifts are not priced at the primary's.
        let noCafeRate = CompensationLedger.evaluate(
            Self.week(), rates: [Self.primaryRate], calendars: [Self.primaryCalendar, Self.cafeCalendar])
        for v in noCafeRate.valuations where Self.cafeIDs.contains(v.id) {
            #expect(v.wage == .unavailable(.rateNotSet))
        }
        // And without a Cafe calendar there is no Cafe workweek.
        let noCafeCalendar = CompensationLedger.evaluate(
            Self.week(), rates: [Self.primaryRate, Self.cafeRate], calendars: [Self.primaryCalendar])
        for v in noCafeCalendar.valuations where Self.cafeIDs.contains(v.id) {
            #expect(v.wage == .unavailable(.noCalendarPolicy))
        }
    }

    @Test("A daily-overtime calendar tagged to one job applies to that job only")
    func dailyOvertimePerJob() {
        var cafeDaily = Self.cafeCalendar
        cafeDaily.dailyOvertimeThresholdMinutes = 480
        let out = CompensationLedger.evaluate(
            Self.week(), rates: [Self.primaryRate, Self.cafeRate],
            calendars: [Self.primaryCalendar, cafeDaily])
        for v in out.valuations {
            #expect(v.overtimeMinutes == (Self.cafeIDs.contains(v.id) ? 120 : 0))
        }
    }

    static func snapshot(paychecks: [PaycheckInput] = []) throws -> EarningsSnapshot {
        try EarningsSnapshot.build(EarningsInputs(
            shifts: week(), paychecks: paychecks,
            rates: [primaryRate, cafeRate], calendars: [primaryCalendar, cafeCalendar],
            asOf: day("2026-12-31")))
    }

    @Test("The job scope on range returns only that job's shifts and shiftIDs")
    func rangeJobScope() throws {
        let snap = try Self.snapshot()
        let span = DayRange(start: Self.day("2026-01-01"), end: Self.day("2026-01-31"))
        let all = snap.range(span)
        let cafe = snap.range(span, job: .job(" cafe "))
        let primary = snap.range(span, job: .job(nil))
        #expect(all.shiftIDs == Self.primaryIDs + Self.cafeIDs)
        #expect(cafe.shiftIDs == Self.cafeIDs)
        #expect(primary.shiftIDs == Self.primaryIDs)
        #expect(cafe.minutes == 1200)
        #expect(cafe.completeness.totalShifts == 2)
        #expect(cafe.knownComponents + primary.knownComponents == all.knownComponents)
        #expect(snap.valuations(in: span, job: .job("Cafe")).map(\.id) == Self.cafeIDs)
        #expect(snap.days(in: span, job: .job("Cafe")).flatMap(\.shiftIDs) == Self.cafeIDs)
        #expect(snap.month(YearMonth(year: 2026, month: 1), job: .job("Cafe")).shiftIDs == Self.cafeIDs)
        #expect(snap.day(Self.day("2026-01-05"), job: .job("Cafe")).shiftIDs.isEmpty)
    }

    @Test("A paycheck tagged to a job reconciles against that job's shifts only")
    func paycheckPerJob() throws {
        let cafeCheck = PaycheckInput(
            id: Self.uuid(300), periodStart: Self.day("2026-01-05"), periodEnd: Self.day("2026-01-11"),
            paidTipsCents: 0, jobName: "Cafe")
        let primaryCheck = PaycheckInput(
            id: Self.uuid(301), periodStart: Self.day("2026-01-05"), periodEnd: Self.day("2026-01-10"),
            paidTipsCents: 0)
        let snap = try Self.snapshot(paychecks: [cafeCheck, primaryCheck])
        #expect(snap.paycheck(periodEnd: Self.day("2026-01-11"))?.expected.shiftIDs == Self.cafeIDs)
        #expect(snap.paycheck(periodEnd: Self.day("2026-01-10"))?.expected.shiftIDs == Self.primaryIDs)
        let byID = Dictionary(uniqueKeysWithValues: snap.paycheckReconciliations.map { ($0.paycheck.id, $0) })
        #expect(byID[cafeCheck.id]?.expected.shiftIDs == Self.cafeIDs)
        #expect(byID[primaryCheck.id]?.expected.shiftIDs == Self.primaryIDs)
    }

    @Test("Two jobs paid on the same day: the job scope finds each job's own check")
    func sharedPaydayPerJob() throws {
        let end = Self.day("2026-01-11")
        let cafeCheck = PaycheckInput(
            id: Self.uuid(310), periodStart: Self.day("2026-01-05"), periodEnd: end,
            paidTipsCents: 0, jobName: "Cafe")
        let primaryCheck = PaycheckInput(
            id: Self.uuid(311), periodStart: Self.day("2026-01-05"), periodEnd: end,
            paidTipsCents: 0)
        let snap = try Self.snapshot(paychecks: [cafeCheck, primaryCheck])
        #expect(snap.paycheck(periodEnd: end, job: .job("Cafe"))?.paycheck.id == cafeCheck.id)
        #expect(snap.paycheck(periodEnd: end, job: .job("Cafe"))?.expected.shiftIDs == Self.cafeIDs)
        #expect(snap.paycheck(periodEnd: end, job: .job(nil))?.paycheck.id == primaryCheck.id)
        #expect(snap.paycheck(periodEnd: end, job: .job(nil))?.expected.shiftIDs == Self.primaryIDs)
        // `.all` keeps the pre-jobs rule: the first in canonical order.
        #expect(snap.paycheck(periodEnd: end)?.paycheck.id == cafeCheck.id)
        #expect(snap.paycheck(periodEnd: end, job: .job("Nowhere")) == nil)
    }

    @Test("A job tag changes the manifest digest; no tag leaves the line as before")
    func manifestCarriesJob() throws {
        let untagged = try EarningsInputs(shifts: Self.week(cafe: nil), asOf: Self.day("2026-12-31")).manifest()
        let tagged = try EarningsInputs(shifts: Self.week(), asOf: Self.day("2026-12-31")).manifest()
        #expect(untagged.digest != tagged.digest)
        #expect(try !InputManifest.canonicalText(shifts: Self.week(cafe: nil)).contains("|job="))
        #expect(try InputManifest.canonicalText(shifts: Self.week()).contains("|job=Cafe"))
    }

    /// The one-job proof: every golden fixture, run with every shift and
    /// policy tagged to one job, values exactly as it does untagged (the
    /// pinned fixture totals, which the fixture gates still check on engine
    /// 3). Only `jobName` differs.
    @Test("One job: every fixture values identically, tagged or not", arguments: FixtureLoader.availableIDs())
    func oneJobUnchanged(id: String) throws {
        let fixture = try FixtureLoader.load(id)
        let shifts = fixture.toShiftInputs()
        let rates = fixture.toRatePolicies()
        let calendars = try fixture.toCalendarPolicies()
        let plain = CompensationLedger.evaluate(shifts, rates: rates, calendars: calendars)
        let solo = CompensationLedger.evaluate(
            shifts.map { var s = $0; s.jobName = "Solo"; return s },
            rates: rates.map { var r = $0; r.jobName = "Solo"; return r },
            calendars: calendars.map { var c = $0; c.jobName = "Solo"; return c })
        #expect(plain.valuations.allSatisfy { $0.jobName == nil })
        #expect(solo.valuations.map { var v = $0; v.jobName = nil; return v } == plain.valuations)
        #expect(solo.diagnostics == plain.diagnostics)
        #expect(solo.wageFeatureEnabled == plain.wageFeatureEnabled)
    }
}
