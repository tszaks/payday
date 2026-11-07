import Foundation
import PaydayCore
import SwiftData
import Testing
@testable import Payday

/// PR E3: a Dashboard card per job, Insights and the CSV by job.
/// Synthetic values throughout; no real payroll figures.
private let zone = PaydayTestZone.payroll
private let bistroID = UUID(uuidString: "00000000-0000-0000-0000-0000000000b3")!
private let cafeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

/// Biweekly, ending Sunday Oct 11 2026, paid five days later.
private let primarySchedule = PaySchedule(
    frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0), payDelayDays: 5, firstWeekday: nil)

/// Weekly, ending Wednesday Oct 7 2026, paid two days later.
private let cafeSchedule = PayScheduleInput(
    frequency: "weekly", anchorPeriodEnd: CivilDay(iso: "2026-10-07")!, payDelayDays: 2)

private let primaryCalendar = PayrollCalendarPolicy(
    id: PolicyMigration.deterministicID("jobsdashboard/calendar/primary"),
    effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: zone)
private let cafeCalendar = PayrollCalendarPolicy(
    id: PolicyMigration.deterministicID("jobsdashboard/calendar/cafe"),
    effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: zone, jobName: "Cafe")
private let primaryRate = PayRatePolicy(
    id: PolicyMigration.deterministicID("jobsdashboard/rate/primary"),
    effectiveFrom: .distantPast, hourlyRateCents: 1_000, provenance: .confirmed)
private let cafeRate = PayRatePolicy(
    id: PolicyMigration.deterministicID("jobsdashboard/rate/cafe"),
    effectiveFrom: .distantPast, hourlyRateCents: 1_200, provenance: .confirmed, jobName: "Cafe")

private func oneJob() -> CompensationPolicies {
    CompensationPolicies(rates: [primaryRate], calendars: [primaryCalendar])
}

private func twoJobs() -> CompensationPolicies {
    CompensationPolicies(
        rates: [primaryRate, cafeRate],
        calendars: [primaryCalendar, cafeCalendar],
        jobs: [
            JobPolicy(id: bistroID, name: "Bistro", schedule: nil, isPrimary: true),
            JobPolicy(id: cafeID, name: "Cafe", schedule: cafeSchedule, isPrimary: false),
        ])
}

private func shifts() -> [ShiftRecord] {
    [
        ShiftRecord(workDate: at(2026, 10, 5), creditTipsCents: 10_000, hoursWorked: 5, recordedAt: at(2026, 10, 5)),
        ShiftRecord(workDate: at(2026, 10, 6), creditTipsCents: 4_000, hoursWorked: 4, jobName: "Cafe",
                    recordedAt: at(2026, 10, 6)),
    ]
}

/// Two Cafe stubs with gross and net, so only Cafe has an after-tax model.
private func cafeStubs() -> [PaycheckRecord] {
    [(9, 16), (9, 23)].map { month, day in
        let check = PaycheckRecord(
            periodStart: at(2026, month, day - 6, hour: 0), periodEnd: at(2026, month, day, hour: 0),
            paidTipsCents: 3_000, grossPayCents: 50_000 + day * 100, netPayCents: 40_000 + day * 80)
        check.jobName = "Cafe"
        return check
    }
}

private let now = at(2026, 10, 6)

@MainActor
private func facts(_ datasets: [DashboardEarnings.Dataset], policies: CompensationPolicies) -> [DashboardFacts] {
    DashboardEarnings.facts(
        for: datasets, policies: policies, primarySchedule: primarySchedule, primaryZone: zone, now: now,
        forcedPaydayPhase: nil, dismissedClosedEnd: nil, dismissedCheckEnd: nil)
}

@Suite("Jobs dashboard: one card per job")
@MainActor
struct JobsDashboardCardsTests {
    @Test("two jobs, two schedules: two cards, primary first, each on its own current period")
    func twoCards() throws {
        let records = shifts()
        let policies = twoJobs()
        let datasets = DashboardEarnings.buildPerJob(
            records: records, policies: policies, payrollTimeZone: zone, paychecks: cafeStubs())
        #expect(datasets.map(\.job) == [.job(nil), .job("Cafe")])
        // ONE snapshot for every card.
        let digests = datasets.map { $0.snapshot?.stamp.digest }
        #expect(digests[0] != nil && digests[0] == digests[1])

        let cards = facts(datasets, policies: policies)
        #expect(cards.count == 2)
        let bistro = cards[0], cafe = cards[1]
        // Biweekly Sep 28 – Oct 11 against weekly Oct 1 – Oct 7.
        #expect(bistro.heroPeriod != cafe.heroPeriod)
        #expect(CivilDay(bistro.heroPeriod.end, in: zone) == CivilDay(iso: "2026-10-11"))
        #expect(CivilDay(cafe.heroPeriod.end, in: zone) == CivilDay(iso: "2026-10-07"))

        // No cross-job figure: each card's rows and hero are its own job's.
        #expect(bistro.shiftRecordDays.map(\.id) == [records[0].id])
        #expect(cafe.shiftRecordDays.map(\.id) == [records[1].id])
        let snapshot = try #require(datasets[0].snapshot)
        let today = CivilDay(now, in: zone)
        func hero(_ card: DashboardFacts, _ job: JobScope) -> Int {
            snapshot.range(
                DayRange(start: CivilDay(card.heroPeriod.start, in: zone), end: CivilDay(card.heroPeriod.end, in: zone)),
                asOf: today, job: job).knownComponents.earnedIncomeCents
        }
        #expect(bistro.hero.cents == hero(bistro, .job(nil)))
        #expect(cafe.hero.cents == hero(cafe, .job("Cafe")))
        #expect(bistro.hero.cents != cafe.hero.cents)
    }

    @Test("the second job's after-tax model comes from its own checks only")
    func ownChecks() {
        let datasets = DashboardEarnings.buildPerJob(
            records: shifts(), policies: twoJobs(), payrollTimeZone: zone, paychecks: cafeStubs())
        #expect(datasets[0].withholdingModel == nil)
        #expect(datasets[1].withholdingModel != nil)
        #expect(datasets[1].withholdingModel == WithholdingModelAdapter.model(from: cafeStubs()))
    }

    @Test("one job: exactly one card, identical to the Dashboard before jobs")
    func oneJobParity() {
        let records = [shifts()[0]]
        let datasets = DashboardEarnings.buildPerJob(records: records, policies: oneJob(), payrollTimeZone: zone)
        #expect(datasets.count == 1)
        #expect(datasets[0].job == .all)
        let before = DashboardEarnings.build(records: records, policies: oneJob(), payrollTimeZone: zone)
        #expect(datasets[0].snapshot?.stamp.digest == before.snapshot?.stamp.digest)
        let after = facts(datasets, policies: oneJob())
        #expect(after.count == 1)
        let today = DashboardFacts(
            snapshot: before.snapshot, allShiftRecords: before.shiftRecordDays, allTipRecords: before.tipRecords,
            withholdingModel: before.withholdingModel, schedule: primarySchedule, now: now,
            forcedPaydayPhase: nil, dismissedClosedEnd: nil, dismissedCheckEnd: nil, payrollTimeZone: zone)
        #expect(after[0].hero == today.hero)
        #expect(after[0].heroPeriod == today.heroPeriod)
        #expect(after[0].shiftCount == today.shiftCount)
        #expect(after[0].predictedPaycheckNet == today.predictedPaycheckNet)
        #expect(after[0].heroCheckGross == today.heroCheckGross)
        #expect(after[0].heroCheckNet == today.heroCheckNet)
        #expect(after[0].shiftRecordDays.map(\.id) == today.shiftRecordDays.map(\.id))
    }

    @Test("See all on a second job's card lands on that job's current period; the primary's as before")
    func seeAllLanding() {
        #expect(DashboardView.seeAllLanding(for: .all) == .currentDetail)
        #expect(DashboardView.seeAllLanding(for: .job(nil)) == .currentDetail)
        #expect(DashboardView.seeAllLanding(for: .job("Cafe")) == .jobCurrentDetail(job: "Cafe"))
    }

    @Test("a card's payday is written on its own payroll calendar, not the device's")
    func paydayOnItsOwnCalendar() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        // Midnight Friday Nov 13 in New York is Thursday evening in Los Angeles.
        let payday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 13)))
        let locale = Locale(identifier: "en_US")
        #expect(DashboardView.paydayLabel(payday, in: newYork, locale: locale) == "Fri, Nov 13")
        #expect(DashboardView.paydayLabel(payday, in: losAngeles, locale: locale) == "Thu, Nov 12")
    }

    @Test("each card's own civil day is in the cache key: a job in Tokyo turns the day before New York does")
    func ownDayInTheKey() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        // Tuesday Oct 6, 20:00 in New York is already Wednesday Oct 7, 09:00 in Tokyo.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 20)))
        let zones: (String?) -> TimeZone = { $0 == nil ? newYork : tokyo }
        let days = DashboardView.jobDays(twoJobs().jobs, now: now, zoneForJob: zones)
        #expect(days.count == 2)
        #expect(CivilDay(days[0], in: newYork) == CivilDay(iso: "2026-10-06"))
        #expect(CivilDay(days[1], in: tokyo) == CivilDay(iso: "2026-10-07"))
        // One job: the key is exactly what it was.
        #expect(DashboardView.jobDays(oneJob().jobs, now: now, zoneForJob: zones).isEmpty)
    }
}

@Suite("Jobs dashboard: Insights by job")
@MainActor
struct JobsInsightsScopeTests {
    /// 30 h at the Bistro and 20 h at the Cafe in one workweek (Sun Oct 4 –
    /// Sat Oct 10): 50 h in all, but no job passes 40 h.
    private func week() -> [ShiftRecord] {
        let bistro = (4...6).map { day in
            ShiftRecord(workDate: at(2026, 10, day), creditTipsCents: 5_000, hoursWorked: 10, recordedAt: at(2026, 10, day))
        }
        let cafe = (7...8).map { day in
            ShiftRecord(workDate: at(2026, 10, day), creditTipsCents: 2_000, hoursWorked: 10, jobName: "Cafe",
                        recordedAt: at(2026, 10, day))
        }
        return bistro + cafe
    }

    private let weekRange = DayRange(start: CivilDay(iso: "2026-10-04")!, end: CivilDay(iso: "2026-10-10")!)

    @Test("a job scope reports only that job's shifts; 30 h + 20 h in two jobs is no overtime in any scope")
    func jobScope() throws {
        let records = week()
        for (job, expected) in [(JobScope.job(nil), Array(records[0..<3])), (.job("Cafe"), Array(records[3..<5]))] {
            let dataset = InsightsEarnings.build(records: records, policies: twoJobs(), payrollTimeZone: zone, job: job)
            #expect(dataset.shiftIDs == expected.map(\.id))
            #expect(dataset.tipRecords.count == expected.count)
            let result = try #require(dataset.snapshot).range(weekRange, asOf: .distantFuture)
            #expect(result.completeness.totalShifts == expected.count)
            #expect(result.knownComponents.overtimeWagesCents == 0)
        }
        let all = try #require(InsightsEarnings.build(records: records, policies: twoJobs(), payrollTimeZone: zone).snapshot)
        #expect(all.range(weekRange, asOf: .distantFuture).knownComponents.overtimeWagesCents == 0)
    }

    @Test("a job and a role together report the shifts matching both")
    func jobAndRole() {
        var records = week()
        records[0].roleName = "Bar"
        records[3].roleName = "Bar"
        let dataset = InsightsEarnings.build(
            records: records, policies: twoJobs(), payrollTimeZone: zone, role: "Bar", job: .job("Cafe"))
        #expect(dataset.shiftIDs == [records[3].id])
    }

    @Test("under a picked job the role switch lists that job's roles only")
    func rolesFollowTheJob() {
        var records = week()
        records[0].roleName = "Floor"
        records[1].roleName = "Floor"
        records[2].roleName = "Bar"
        records[3].roleName = "Host"
        records[4].roleName = "Host"
        #expect(Set(InsightsEarnings.roleOptions(records: records)) == ["Floor", "Bar", "Host"])
        #expect(InsightsEarnings.roleOptions(records: records, job: .job(nil)) == ["Floor", "Bar"])
        // One role at the Cafe: no role switch there, the page as it is.
        #expect(InsightsEarnings.roleOptions(records: records, job: .job("Cafe")).isEmpty)
        #expect(Set(InsightsEarnings.roleOptions(records: records, job: .all)) == ["Floor", "Bar", "Host"])
    }

    @Test("the switch is offered only with two or more jobs, primary first")
    func options() {
        #expect(InsightsEarnings.jobOptions(oneJob().jobs).isEmpty)
        #expect(InsightsEarnings.jobOptions([JobPolicy(id: bistroID, name: "Bistro", schedule: nil, isPrimary: true)]).isEmpty)
        #expect(InsightsEarnings.jobOptions(twoJobs().jobs).map(\.name) == ["Bistro", "Cafe"])
    }

    @Test("one job: the page is exactly the page before jobs")
    func oneJobParity() {
        let records = week().map { record -> ShiftRecord in record.jobName = nil; return record }
        let before = InsightsEarnings.build(records: records, policies: oneJob(), payrollTimeZone: zone)
        let after = InsightsEarnings.build(records: records, policies: oneJob(), payrollTimeZone: zone, job: .all)
        #expect(after.snapshot?.stamp.digest == before.snapshot?.stamp.digest)
        #expect(after.shiftIDs == before.shiftIDs)
        #expect(after.tipRecords.count == before.tipRecords.count)
    }
}

@Suite("Jobs dashboard: the CSV by job")
@MainActor
struct JobsCSVFilterTests {
    private let store: PolicyStore = {
        let suiteName = "com.szakacsmedia.payday.jobsdashboard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PolicyStore(defaults: defaults)
        store.apply(twoJobs())
        return store
    }()

    private func calculatorForJob(_ tag: String?) -> PayPeriodCalculator {
        store.calculator(forJob: tag, primarySchedule: primarySchedule)
    }

    @Test("a job filter keeps only that job's rows")
    func filter() {
        let records = shifts()
        let cafe = CSVExporter.export(
            records: records, paycheckRecords: [], calculatorForJob: calculatorForJob, job: .job("Cafe"))
            .split(separator: "\n").map(String.init)
        #expect(cafe.count == 2)
        #expect(cafe[1].hasPrefix("2026-10-06,"))
        #expect(cafe[1].hasSuffix(",Cafe"))
        let bistro = CSVExporter.export(
            records: records, paycheckRecords: [], calculatorForJob: calculatorForJob, job: .job(nil))
            .split(separator: "\n").map(String.init)
        #expect(bistro.count == 2)
        #expect(bistro[1].hasPrefix("2026-10-05,"))
        let all = CSVExporter.export(records: records, paycheckRecords: [], calculatorForJob: calculatorForJob)
        #expect(all.split(separator: "\n").count == 3)
    }

    @Test("a second job's shift is filed under its own job's period and matched to its own check")
    func ownPeriod() {
        let check = PaycheckRecord(periodStart: at(2026, 10, 1, hour: 0), periodEnd: at(2026, 10, 7, hour: 0), paidTipsCents: 4_321)
        check.jobName = "Cafe"
        let lines = CSVExporter.export(
            records: shifts(), paycheckRecords: [check], calculatorForJob: calculatorForJob)
            .split(separator: "\n").map(String.init)
        // Bistro: biweekly Sep 28 – Oct 11. Cafe: weekly Oct 1 – Oct 7.
        #expect(lines[1].contains("2026-09-28 to 2026-10-11"))
        #expect(lines[2].contains("2026-10-01 to 2026-10-07"))
        #expect(lines[2].contains("43.21"))
        #expect(!lines[1].contains("43.21"))
    }

    @Test("one job: the per-job export is the export before jobs, byte for byte")
    func oneJobParity() {
        let calculator = PayPeriodCalculator(payrollTimeZone: zone, schedule: primarySchedule)
        let records = [shifts()[0], ShiftRecord(workDate: at(2026, 10, 9), cashTipsCents: 2_500)]
        let check = PaycheckRecord(periodStart: at(2026, 9, 28, hour: 0), periodEnd: at(2026, 10, 11, hour: 0), paidTipsCents: 9_000)
        let before = CSVExporter.export(records: records, paycheckRecords: [check], calculator: calculator)
        let after = CSVExporter.export(records: records, paycheckRecords: [check], calculatorForJob: { _ in calculator })
        #expect(before == after)
    }
}
