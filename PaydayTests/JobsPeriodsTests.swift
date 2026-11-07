import Foundation
import PaydayCore
import SwiftData
import Testing
@testable import Payday

/// PR E2b: each job on its own calendar, wage and payday reminder.
/// Synthetic values throughout; no real payroll figures.
private let zone = PaydayTestZone.payroll
private let bistroID = UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!
private let cafeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!

private func at(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, in tz: TimeZone = zone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tz
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func freshDefaults() -> UserDefaults {
    let suiteName = "com.szakacsmedia.payday.jobsperiods.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

/// Biweekly, ending Sunday Oct 11 2026, paid five days later.
private let primarySchedule = PaySchedule(
    frequency: .biweekly, anchorPeriodEnd: at(2026, 10, 11, hour: 0), payDelayDays: 5, firstWeekday: nil)

/// Weekly, ending Wednesday Oct 7 2026, paid two days later.
private let cafeSchedule = PayScheduleInput(
    frequency: "weekly", anchorPeriodEnd: CivilDay(iso: "2026-10-07")!, payDelayDays: 2)

private let primaryCalendar = PayrollCalendarPolicy(
    id: PolicyMigration.deterministicID("jobsperiods/calendar/primary"),
    effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: zone)
private let cafeCalendar = PayrollCalendarPolicy(
    id: PolicyMigration.deterministicID("jobsperiods/calendar/cafe"),
    effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: zone, jobName: "Cafe")
private let primaryRate = PayRatePolicy(
    id: PolicyMigration.deterministicID("jobsperiods/rate/primary"),
    effectiveFrom: .distantPast, hourlyRateCents: 1_000, provenance: .confirmed)
private let cafeRate = PayRatePolicy(
    id: PolicyMigration.deterministicID("jobsperiods/rate/cafe"),
    effectiveFrom: .distantPast, hourlyRateCents: 1_200, provenance: .confirmed, jobName: "Cafe")

private func oneJob() -> CompensationPolicies {
    CompensationPolicies(rates: [primaryRate], calendars: [primaryCalendar])
}

private func twoJobs(cafeHasSchedule: Bool = true) -> CompensationPolicies {
    CompensationPolicies(
        rates: [primaryRate, cafeRate],
        calendars: [primaryCalendar, cafeCalendar],
        jobs: [
            JobPolicy(id: bistroID, name: "Bistro", schedule: nil, isPrimary: true),
            JobPolicy(id: cafeID, name: "Cafe", schedule: cafeHasSchedule ? cafeSchedule : nil, isPrimary: false),
        ])
}

private func shifts() -> [ShiftRecord] {
    [
        ShiftRecord(workDate: at(2026, 10, 5), creditTipsCents: 10_000, hoursWorked: 5, recordedAt: at(2026, 10, 5)),
        ShiftRecord(workDate: at(2026, 10, 6), creditTipsCents: 4_000, hoursWorked: 4, jobName: "Cafe",
                    recordedAt: at(2026, 10, 6)),
    ]
}

@Suite("Jobs periods: one calculator per job")
@MainActor
struct JobCalculatorTests {
    @Test("the primary's calculator is today's calculator exactly")
    func primaryIsToday() {
        let store = PolicyStore(defaults: freshDefaults())
        store.apply(twoJobs())
        let calculator = store.calculator(forJob: nil, primarySchedule: primarySchedule)
        let today = PayPeriodCalculator(payrollTimeZone: store.payrollTimeZone, schedule: primarySchedule)
        #expect(calculator.schedule == today.schedule)
        #expect(calculator.payrollTimeZone == today.payrollTimeZone)
        #expect(calculator.period(containing: at(2026, 10, 6)) == today.period(containing: at(2026, 10, 6)))
    }

    @Test("a job with its own schedule gets its own periods")
    func jobSchedule() {
        let store = PolicyStore(defaults: freshDefaults())
        store.apply(twoJobs())
        let cafe = store.calculator(forJob: "Cafe", primarySchedule: primarySchedule)
        let period = cafe.period(containing: at(2026, 10, 6))
        #expect(period.start == at(2026, 10, 1, hour: 0))
        #expect(period.end == at(2026, 10, 7, hour: 0))
        #expect(cafe.payDate(for: period) == at(2026, 10, 9, hour: 0))
        let bistro = store.calculator(forJob: nil, primarySchedule: primarySchedule).period(containing: at(2026, 10, 6))
        #expect(bistro != period)
    }

    @Test("a job without its own schedule follows the primary's")
    func jobWithoutSchedule() {
        let store = PolicyStore(defaults: freshDefaults())
        store.apply(twoJobs(cafeHasSchedule: false))
        let cafe = store.calculator(forJob: "cafe", primarySchedule: primarySchedule)
        let bistro = store.calculator(forJob: nil, primarySchedule: primarySchedule)
        #expect(cafe.period(containing: at(2026, 10, 6)) == bistro.period(containing: at(2026, 10, 6)))
    }
}

@Suite("Jobs periods: Periods rows per job")
@MainActor
struct JobPeriodsRowsTests {
    @Test("two jobs, two schedules: each job's rows are its own periods, shifts and checks")
    func rowsPerJob() throws {
        let policies = twoJobs()
        let store = PolicyStore(defaults: freshDefaults())
        store.apply(policies)
        let records = shifts()
        let snapshot = HistoryEarnings.build(records: records, policies: policies, payrollTimeZone: zone).snapshot
        let cafeCheck = PaycheckRecord(periodStart: at(2026, 10, 1, hour: 0), periodEnd: at(2026, 10, 7, hour: 0), paidTipsCents: 4_000)
        cafeCheck.jobName = "Cafe"
        let now = at(2026, 10, 6)

        let bistroCalc = store.calculator(forJob: nil, primarySchedule: primarySchedule)
        let bistro = PeriodsPageFacts(
            snapshot: snapshot, paycheckRecords: [cafeCheck], schedule: bistroCalc.schedule,
            payrollTimeZone: bistroCalc.payrollTimeZone, job: .job(nil), now: now)
        let cafeCalc = store.calculator(forJob: "Cafe", primarySchedule: primarySchedule)
        let cafe = PeriodsPageFacts(
            snapshot: snapshot, paycheckRecords: [cafeCheck], schedule: cafeCalc.schedule,
            payrollTimeZone: cafeCalc.payrollTimeZone, job: .job("Cafe"), now: now)

        #expect(bistro.rows.first?.period == PayPeriod(start: at(2026, 9, 28, hour: 0), end: at(2026, 10, 11, hour: 0)))
        #expect(cafe.rows.first?.period == PayPeriod(start: at(2026, 10, 1, hour: 0), end: at(2026, 10, 7, hour: 0)))
        // Each job's row holds only its own shift.
        #expect(bistro.rows.first?.result?.shiftIDs == [records[0].id])
        #expect(cafe.rows.first?.result?.shiftIDs == [records[1].id])
        // Another job's check is never this job's.
        #expect(bistro.rows.allSatisfy { $0.paycheck == nil })
        #expect(cafe.rows.first?.paycheck?.id == cafeCheck.id)
    }

    @Test("one job: the rows are exactly the rows before jobs")
    func oneJobParity() throws {
        let policies = oneJob()
        let records = [shifts()[0]]
        let snapshot = HistoryEarnings.build(records: records, policies: policies, payrollTimeZone: zone).snapshot
        let check = PaycheckRecord(periodStart: at(2026, 9, 28, hour: 0), periodEnd: at(2026, 10, 11, hour: 0), paidTipsCents: 9_000)
        let before = PeriodsPageFacts(
            snapshot: snapshot, paycheckRecords: [check], schedule: primarySchedule,
            payrollTimeZone: zone, now: at(2026, 10, 6))
        let store = PolicyStore(defaults: freshDefaults())
        store.apply(policies)
        let calc = store.calculator(forJob: nil, primarySchedule: primarySchedule)
        let after = PeriodsPageFacts(
            snapshot: snapshot, paycheckRecords: [check], schedule: calc.schedule,
            payrollTimeZone: calc.payrollTimeZone, job: .picked(nil, jobCount: policies.jobs.count), now: at(2026, 10, 6))
        #expect(JobScope.picked(nil, jobCount: 0) == .all)
        #expect(before.rows.map(\.period) == after.rows.map(\.period))
        #expect(before.rows.map(\.payDate) == after.rows.map(\.payDate))
        #expect(before.rows.map { $0.result } == after.rows.map { $0.result })
        #expect(before.rows.map { $0.paycheck?.id } == after.rows.map { $0.paycheck?.id })
        #expect(before.rows.map { $0.checked } == after.rows.map { $0.checked })
        #expect(before.yearToDate == after.yearToDate)
    }
}

@Suite("Jobs periods: payday push per job")
@MainActor
struct JobPushIdentifierTests {
    private func requests(_ policies: CompensationPolicies, records: [ShiftRecord]) -> [PaydayPushScheduler.PendingRequest] {
        PaydayPushScheduler.pendingRequests(
            now: at(2026, 10, 6),
            policies: policies,
            primarySchedule: primarySchedule,
            shiftInputs: ShiftInputAdapter.adapt(records, calendars: policies.calendars),
            paycheckRecords: [],
            isReminderEnabled: true)
    }

    @Test("one job: the same pair, the same identifiers and periods as before jobs")
    func oneJobUnchanged() throws {
        let policies = oneJob()
        let records = [shifts()[0]]
        let pending = requests(policies, records: records)
        #expect(pending.map(\.identifier) == ["payday-moment", "payday-stub-nudge"])
        #expect(pending.allSatisfy { $0.job == nil })
        let calculator = PayPeriodCalculator(payrollTimeZone: zone, schedule: primarySchedule)
        let decision = try #require(PaydayPushScheduler.decision(
            now: at(2026, 10, 6), calculator: calculator,
            shiftInputs: ShiftInputAdapter.adapt(records, calendars: policies.calendars),
            paycheckRecords: [], isReminderEnabled: true, policies: policies, payrollTimeZone: zone))
        #expect(pending[0].fireDate == decision.fireDate)
        #expect(pending[0].body == decision.body)
        #expect(pending[0].periodStart == decision.periodStart)
        #expect(PaydayPushScheduler.userInfo(for: pending[0])[PaydayPushScheduler.jobKey] == nil)
    }

    @Test("two jobs: four requests; the primary keeps its identifiers, the other job's carry its id")
    func twoJobsFourRequests() throws {
        let pending = requests(twoJobs(), records: shifts())
        #expect(pending.map(\.identifier) == [
            "payday-moment", "payday-stub-nudge",
            "payday-moment-\(cafeID.uuidString)", "payday-stub-nudge-\(cafeID.uuidString)",
        ])
        #expect(pending.allSatisfy { PaydayPushScheduler.isPaydayIdentifier($0.identifier) })
        let cafe = pending[2]
        #expect(cafe.job == "Cafe")
        #expect(cafe.periodStart == at(2026, 10, 1, hour: 0))
        #expect(cafe.periodEnd == at(2026, 10, 7, hour: 0))
        // The primary's figure is its own shift only.
        #expect(pending[0].body.contains(Money.string(fromCents: 15_000)))
        #expect(!pending[0].body.contains(Money.string(fromCents: 19_000)))
        // The tap carries the job, and lands on that job's period.
        let info = PaydayPushScheduler.userInfo(for: cafe)
        #expect(info[PaydayPushScheduler.jobKey] as? String == "Cafe")
        let landing = NotificationDelegate.periodLanding(identifier: cafe.identifier, userInfo: info)
        #expect(landing == .paycheckScan(periodStart: cafe.periodStart, periodEnd: cafe.periodEnd, job: "Cafe"))
    }

    @Test("reschedule clears every job's pair by prefix, and nothing else")
    func prefixes() {
        #expect(PaydayPushScheduler.isPaydayIdentifier("payday-moment"))
        #expect(PaydayPushScheduler.isPaydayIdentifier("payday-stub-nudge-\(cafeID.uuidString)"))
        #expect(!PaydayPushScheduler.isPaydayIdentifier(SmartNudgeScheduler.notificationIdentifier))
    }
}

@Suite("Jobs periods: the stub sheet's period follows the job")
@MainActor
struct JobStubSheetPeriodTests {
    @Test("the screen's job keeps the screen's period; another job's is re-derived on its calendar")
    func periodFollowsJob() {
        let store = PolicyStore(defaults: freshDefaults())
        store.apply(twoJobs())
        let calculator: (String?) -> PayPeriodCalculator = { store.calculator(forJob: $0, primarySchedule: primarySchedule) }
        let bistroPeriod = calculator(nil).period(containing: at(2026, 10, 6))
        #expect(PaycheckEntryFacts.period(
            forJob: nil, screenJob: nil, screenPeriod: bistroPeriod, calculator: calculator) == bistroPeriod)
        let moved = PaycheckEntryFacts.period(
            forJob: "Cafe", screenJob: nil, screenPeriod: bistroPeriod, calculator: calculator)
        #expect(moved == calculator("Cafe").period(containing: bistroPeriod.end))
        #expect(moved != bistroPeriod)
        // And back.
        #expect(PaycheckEntryFacts.period(
            forJob: nil, screenJob: "cafe", screenPeriod: moved, calculator: calculator)
            == calculator(nil).period(containing: moved.end))
    }
}

@Suite("Jobs periods: the Dashboard is the primary job's")
@MainActor
struct JobDashboardScopeTests {
    private func facts(_ dataset: DashboardEarnings.Dataset) -> DashboardFacts {
        DashboardFacts(
            snapshot: dataset.snapshot, allShiftRecords: dataset.shiftRecordDays,
            allTipRecords: dataset.tipRecords, withholdingModel: dataset.withholdingModel,
            cardTipsPaidAtClose: dataset.cardTipsPaidAtClose, schedule: primarySchedule,
            now: at(2026, 10, 6), forcedPaydayPhase: nil, dismissedClosedEnd: nil, dismissedCheckEnd: nil,
            payrollTimeZone: zone, job: dataset.job)
    }

    @Test("two jobs: the hero and the rows are the primary's only")
    func primaryOnly() {
        let records = shifts()
        let dataset = DashboardEarnings.build(records: records, policies: twoJobs(), payrollTimeZone: zone)
        #expect(dataset.job == .job(nil))
        #expect(dataset.shiftRecordDays.map(\.id) == [records[0].id])
        let dashboard = facts(dataset)
        #expect(dashboard.shiftCount == 1)
        #expect(dashboard.shiftRecordDays.map(\.id) == [records[0].id])
    }

    @Test("one job: the Dashboard is exactly the Dashboard before jobs")
    func oneJobParity() {
        let records = [shifts()[0]]
        let dataset = DashboardEarnings.build(records: records, policies: oneJob(), payrollTimeZone: zone)
        #expect(dataset.job == .all)
        let after = facts(dataset)
        let before = DashboardFacts(
            snapshot: dataset.snapshot, allShiftRecords: records, allTipRecords: dataset.tipRecords,
            withholdingModel: dataset.withholdingModel, schedule: primarySchedule, now: at(2026, 10, 6),
            forcedPaydayPhase: nil, dismissedClosedEnd: nil, dismissedCheckEnd: nil, payrollTimeZone: zone)
        #expect(before.hero == after.hero)
        #expect(before.shiftCount == after.shiftCount)
        #expect(before.heroPeriod == after.heroPeriod)
    }

    @Test("the widget and Siri answer for the primary with two jobs")
    func ambientPrimary() throws {
        let records = shifts()
        let snapshot = try #require(HistoryEarnings.build(records: records, policies: twoJobs(), payrollTimeZone: zone).snapshot)
        let all = AmbientPeriodFigure.answer(from: snapshot, schedule: primarySchedule, payrollTimeZone: zone, now: at(2026, 10, 6))
        let primary = AmbientPeriodFigure.answer(
            from: snapshot, schedule: primarySchedule, payrollTimeZone: zone, now: at(2026, 10, 6),
            job: .picked(nil, jobCount: 2))
        #expect(primary.figure != all.figure)
        #expect(primary.figure.cents == snapshot.range(
            DayRange(start: CivilDay(primary.period.start, in: zone), end: CivilDay(primary.period.end, in: zone)),
            asOf: CivilDay(at(2026, 10, 6), in: zone), job: .job(nil)).knownComponents.earnedIncomeCents)
    }
}

@Suite("Jobs periods: a job's own wage and workweek")
@MainActor
struct JobPolicyEditTests {
    let store = PolicyStore(defaults: freshDefaults())
    let today = CivilDay(iso: "2026-10-06")!

    @Test("adding a job copies the primary's calendar in effect, tagged, from the distant past; no wage")
    func addClonesCalendar() {
        store.apply(CompensationPolicies(
            rates: [primaryRate],
            calendars: [PayrollCalendarPolicy(
                id: UUID(), effectiveFrom: .distantPast, workweekStartWeekday: 3,
                payrollTimeZone: zone, dailyOvertimeThresholdMinutes: 480)]))
        JobCommands.add(name: "Cafe", schedule: nil, primaryName: "Bistro", policyStore: store)
        let cafe = store.policies.policies(forJob: "Cafe")
        #expect(cafe.calendars.count == 1)
        #expect(cafe.calendars[0].jobName == "Cafe")
        #expect(cafe.calendars[0].effectiveFrom == .distantPast)
        #expect(cafe.calendars[0].workweekStartWeekday == 3)
        #expect(cafe.calendars[0].dailyOvertimeThresholdMinutes == 480)
        #expect(cafe.rates.isEmpty)
        #expect(store.currentHourlyRateCents(forJob: "Cafe") == nil)
        // The primary's answers did not move.
        #expect(store.policies.latestCalendar?.jobName == nil)
        #expect(store.currentHourlyRateCents == primaryRate.hourlyRateCents)
    }

    @Test("a job's wage and calendar edits never touch the primary's policies")
    func jobEditsLeavePrimary() {
        store.apply(twoJobs())
        let primaryRates = store.policies.policies(forJob: nil).rates
        let primaryCalendars = store.policies.policies(forJob: nil).calendars
        store.applyRateEdit(hourlyRateCents: 1_500, job: "Cafe")
        store.applyCalendarChange(workweekStartWeekday: 4, payrollTimeZone: zone,
                                  dailyOvertimeThresholdMinutes: 480, today: today, job: "Cafe")
        #expect(store.currentHourlyRateCents(forJob: "Cafe") == 1_500)
        #expect(store.policies.policies(forJob: "Cafe").latestCalendar?.workweekStartWeekday == 4)
        #expect(store.policies.policies(forJob: "Cafe").latestCalendar?.jobName == "Cafe")
        #expect(store.policies.policies(forJob: nil).rates == primaryRates)
        #expect(store.policies.policies(forJob: nil).calendars == primaryCalendars)
        // Clearing the job's wage leaves the primary's.
        store.applyRateEdit(hourlyRateCents: nil, job: "Cafe")
        #expect(store.currentHourlyRateCents(forJob: "Cafe") == nil)
        #expect(store.policies.policies(forJob: nil).rates == primaryRates)
    }

    @Test("the primary's wage and calendar edits keep every other job's policies")
    func primaryEditsKeepJobs() {
        store.apply(twoJobs())
        let cafeRates = store.policies.policies(forJob: "Cafe").rates
        let cafeCalendars = store.policies.policies(forJob: "Cafe").calendars
        store.applyRateEdit(hourlyRateCents: 1_100)
        store.applyCalendarChange(workweekStartWeekday: 2, payrollTimeZone: zone, today: today)
        #expect(store.policies.policies(forJob: "Cafe").rates == cafeRates)
        #expect(store.policies.policies(forJob: "Cafe").calendars == cafeCalendars)
        // Revert removes only the primary's pending policy.
        store.applyCalendarChange(workweekStartWeekday: 1, payrollTimeZone: zone, today: today)
        #expect(store.policies.policies(forJob: "Cafe").calendars == cafeCalendars)
        store.applyRateEdit(hourlyRateCents: nil)
        #expect(store.currentHourlyRateCents == nil)
        #expect(store.policies.policies(forJob: "Cafe").rates == cafeRates)
    }

    @Test("rename retags the job's rates and calendars; remove deletes them")
    func renameAndRemove() throws {
        let container = try ModelContainer(
            for: ShiftRecord.self, PaycheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        store.apply(twoJobs())
        try JobCommands.rename(jobID: cafeID, to: "Coffee", policyStore: store, shifts: [], paychecks: [], in: context)
        #expect(store.policies.policies(forJob: "Cafe").rates.isEmpty)
        #expect(store.policies.policies(forJob: "Coffee").rates.map(\.id) == [cafeRate.id])
        #expect(store.policies.policies(forJob: "Coffee").calendars.map(\.id) == [cafeCalendar.id])
        #expect(JobCommands.remove(jobID: cafeID, policyStore: store, shifts: [], paychecks: []) == nil)
        #expect(store.policies.rates.map(\.id) == [primaryRate.id])
        #expect(store.policies.calendars.map(\.id) == [primaryCalendar.id])
    }

    @Test("a job's schedule edit never touches another job or the primary")
    func scheduleEdit() {
        store.apply(twoJobs(cafeHasSchedule: false))
        store.applyJobSchedule(cafeSchedule, jobID: cafeID)
        #expect(store.policies.jobs.first { $0.id == cafeID }?.schedule == cafeSchedule)
        store.applyJobSchedule(cafeSchedule, jobID: bistroID)
        #expect(store.policies.primaryJob?.schedule == nil)
    }
}

@Suite("Jobs periods: each shift in its own job's payroll zone")
@MainActor
struct JobPayrollZoneAdapterTests {
    @Test("two jobs in two zones: each shift's work day is read in its own job's zone")
    func twoZones() {
        let east = TimeZone(identifier: "America/New_York")!
        let hawaii = TimeZone(identifier: "Pacific/Honolulu")!
        let calendars = [
            PayrollCalendarPolicy(id: UUID(), effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: east),
            PayrollCalendarPolicy(id: UUID(), effectiveFrom: .distantPast, workweekStartWeekday: 1,
                                  payrollTimeZone: hawaii, jobName: "Cafe"),
        ]
        // 05:00 UTC on Oct 7 is 01:00 Oct 7 in New York and 19:00 Oct 6 in
        // Honolulu.
        let instant = at(2026, 10, 7, hour: 5, in: TimeZone(identifier: "UTC")!)
        let primary = ShiftRecord(workDate: instant, cashTipsCents: 100)
        let cafe = ShiftRecord(workDate: instant, cashTipsCents: 100, jobName: "Cafe")
        let inputs = ShiftInputAdapter.adapt([primary, cafe], calendars: calendars).inputs
        #expect(inputs[0].workDay == CivilDay(iso: "2026-10-07"))
        #expect(inputs[1].workDay == CivilDay(iso: "2026-10-06"))
    }

    @Test("a job with no calendar of its own reads the primary's zone")
    func fallsBackToPrimary() {
        let hawaii = TimeZone(identifier: "Pacific/Honolulu")!
        let calendars = [
            PayrollCalendarPolicy(id: UUID(), effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: hawaii),
        ]
        let instant = at(2026, 10, 7, hour: 5, in: TimeZone(identifier: "UTC")!)
        let cafe = ShiftRecord(workDate: instant, cashTipsCents: 100, jobName: "Cafe")
        #expect(ShiftInputAdapter.adapt([cafe], calendars: calendars).inputs[0].workDay == CivilDay(iso: "2026-10-06"))
    }
}
