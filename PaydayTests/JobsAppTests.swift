import Foundation
import PaydayCore
import SwiftData
import Testing
@testable import Payday

/// PR E1 in the app: the Job row's facts, the one-job-shows-nothing rule,
/// the rename / make-primary / delete commands, the CSV Job column and the
/// sync wire. Synthetic values throughout.
private func freshDefaults() -> UserDefaults {
    let suiteName = "com.szakacsmedia.payday.jobstests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func jobDay(_ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = PaydayTestZone.payroll
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
}

private let bistroID = UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!
private let cafeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!

private func twoJobs() -> CompensationPolicies {
    CompensationPolicies(jobs: [
        JobPolicy(id: bistroID, name: "Bistro", schedule: nil, isPrimary: true),
        JobPolicy(id: cafeID, name: "Cafe", schedule: nil, isPrimary: false),
    ])
}

@Suite("Jobs: the Job row and the one-job rule")
struct LogShiftJobFactsTests {
    @Test("zero jobs or one job: no Job row on the log sheet or the paycheck sheet")
    func hiddenWithOneJob() {
        #expect(!LogShiftJobFacts(policies: .empty).isRowVisible)
        #expect(LogShiftJobFacts(policies: .empty).chips.isEmpty)
        // A shift tagged on another device before the job list arrived
        // still shows nothing new.
        #expect(!LogShiftJobFacts(policies: .empty, current: "Cafe").isRowVisible)
        let one = CompensationPolicies(jobs: [JobPolicy(id: bistroID, name: "Bistro", schedule: nil, isPrimary: true)])
        #expect(!LogShiftJobFacts(policies: one).isRowVisible)
        #expect(JobsSettingsView.countLabel(.empty) == "1 job")
        #expect(JobsSettingsView.countLabel(one) == "1 job")
    }

    @Test("two jobs: chips are the jobs, primary first, and the primary's tag is nil")
    func chips() {
        let facts = LogShiftJobFacts(policies: twoJobs())
        #expect(facts.isRowVisible)
        #expect(facts.chips == [.init(name: "Bistro", tag: nil), .init(name: "Cafe", tag: "Cafe")])
        #expect(JobsSettingsView.countLabel(twoJobs()) == "2 jobs")
    }

    @Test("a new shift starts on the primary job; an edited shift shows its own job")
    func selection() {
        let facts = LogShiftJobFacts(policies: twoJobs())
        #expect(LogShiftJobFacts.isSelected(facts.chips[0], current: nil))
        #expect(!LogShiftJobFacts.isSelected(facts.chips[1], current: nil))
        #expect(LogShiftJobFacts.isSelected(facts.chips[1], current: " cafe "))
        #expect(!LogShiftJobFacts.isSelected(facts.chips[0], current: "Cafe"))
    }

    @Test("a tag Settings no longer lists still shows, selected")
    func unknownTagShows() {
        let facts = LogShiftJobFacts(policies: twoJobs(), current: "Deli")
        #expect(facts.chips.last == .init(name: "Deli", tag: "Deli"))
        #expect(LogShiftJobFacts.isSelected(facts.chips[2], current: "Deli"))
    }
}

@Suite("Jobs: Settings commands")
@MainActor
struct JobCommandsTests {
    let container: ModelContainer
    let context: ModelContext
    let store = PolicyStore(defaults: freshDefaults())

    init() throws {
        container = try ModelContainer(
            for: ShiftRecord.self, PaycheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    private func shift(_ day: Int, job: String?) -> ShiftRecord {
        let record = ShiftRecord(workDate: jobDay(day), cashTipsCents: 1_000, jobName: job, modifiedAt: jobDay(1))
        context.insert(record)
        return record
    }

    private func paycheck(job: String?) -> PaycheckRecord {
        let record = PaycheckRecord(periodStart: jobDay(1), periodEnd: jobDay(14), paidTipsCents: 0)
        record.jobName = job
        record.modifiedAt = jobDay(1)
        context.insert(record)
        return record
    }

    @Test("adding the first extra job names the primary; every logged shift stays on it")
    func add() {
        let old = shift(5, job: nil)
        JobCommands.add(name: " Cafe ", schedule: nil, primaryName: "Bistro", policyStore: store)
        #expect(store.policies.jobNames == ["Bistro", "Cafe"])
        #expect(store.policies.primaryJob?.name == "Bistro")
        #expect(old.jobName == nil)
    }

    @Test("rename rewrites the tag on that job's shifts and paychecks, and touches them")
    func rename() throws {
        store.apply(twoJobs())
        let cafe = shift(5, job: "Cafe"), primary = shift(6, job: nil), check = paycheck(job: "cafe")
        try JobCommands.rename(jobID: cafeID, to: "Coffee", policyStore: store,
                               shifts: [cafe, primary], paychecks: [check], in: context)
        #expect(store.policies.jobNames == ["Bistro", "Coffee"])
        #expect(cafe.jobName == "Coffee")
        #expect(check.jobName == "Coffee")
        #expect(primary.jobName == nil)
        #expect(cafe.modifiedAt > jobDay(1))
        #expect(primary.modifiedAt == jobDay(1))
    }

    @Test("renaming the primary changes no record: its tag is nil")
    func renamePrimary() throws {
        store.apply(twoJobs())
        let primary = shift(6, job: nil)
        try JobCommands.rename(jobID: bistroID, to: "Grill", policyStore: store,
                               shifts: [primary], paychecks: [], in: context)
        #expect(store.policies.primaryJob?.name == "Grill")
        #expect(primary.jobName == nil)
        #expect(primary.modifiedAt == jobDay(1))
    }

    @Test("make primary swaps the nil tag between the two jobs' records")
    func makePrimary() throws {
        store.apply(twoJobs())
        let cafe = shift(5, job: "Cafe"), bistro = shift(6, job: nil), check = paycheck(job: nil)
        try JobCommands.makePrimary(jobID: cafeID, policyStore: store,
                                    shifts: [cafe, bistro], paychecks: [check], in: context)
        #expect(store.policies.primaryJob?.id == cafeID)
        #expect(store.policies.jobNames == ["Cafe", "Bistro"])
        #expect(cafe.jobName == nil)
        #expect(bistro.jobName == "Bistro")
        #expect(check.jobName == "Bistro")
    }

    @Test("delete is refused while a shift or paycheck carries the name, and says how many")
    func deleteRefused() {
        store.apply(twoJobs())
        let tagged = [shift(5, job: "Cafe"), shift(6, job: "Cafe")]
        let refusal = JobCommands.remove(jobID: cafeID, policyStore: store, shifts: tagged, paychecks: [paycheck(job: "Cafe")])
        #expect(refusal == JobCommands.Usage(shifts: 2, paychecks: 1))
        #expect(store.policies.jobNames == ["Bistro", "Cafe"])
        #expect(JobsSettingsView.refusalMessage(job: "Cafe", usage: refusal!)
                == "Cafe is on 2 shifts and 1 paycheck. Move them to another job first.")
    }

    @Test("other Settings edits (clearing the wage, changing the workweek) keep the job list")
    func otherPolicyEditsKeepJobs() {
        store.apply(twoJobs())
        store.applyRateEdit(hourlyRateCents: nil)
        #expect(store.policies.jobNames == ["Bistro", "Cafe"])
        let today = CivilDay(year: 2026, month: 10, day: 5)
        _ = store.applyCalendarChange(workweekStartWeekday: 2, payrollTimeZone: PaydayTestZone.payroll,
                                      dailyOvertimeThresholdMinutes: nil, today: today)
        #expect(store.policies.jobNames == ["Bistro", "Cafe"])
        _ = store.applyCalendarChange(workweekStartWeekday: 2, payrollTimeZone: PaydayTestZone.payroll,
                                      dailyOvertimeThresholdMinutes: nil, today: today)
        #expect(store.policies.jobNames == ["Bistro", "Cafe"])
    }

    @Test("deleting the only extra job returns to one job: no list, no Job row")
    func deleteToOneJob() {
        store.apply(twoJobs())
        let refusal = JobCommands.remove(jobID: cafeID, policyStore: store, shifts: [shift(5, job: nil)], paychecks: [])
        #expect(refusal == nil)
        #expect(store.policies.jobs.isEmpty)
        #expect(!LogShiftJobFacts(policies: store.policies).isRowVisible)
        // The primary can never be deleted.
        store.apply(twoJobs())
        #expect(JobCommands.remove(jobID: bistroID, policyStore: store, shifts: [], paychecks: []) == nil)
        #expect(store.policies.jobs.count == 2)
    }
}

@Suite("Jobs: CSV and sync wire")
struct JobsWireTests {
    static let calculator = PayPeriodCalculator(
        payrollTimeZone: PaydayTestZone.payroll,
        schedule: PaySchedule(frequency: .biweekly, anchorPeriodEnd: jobDay(18), firstWeekday: 2)
    )

    @Test("with no job tags the CSV header is exactly today's; with one, Job is last")
    @MainActor
    func csv() {
        let plain = CSVExporter.export(
            records: [ShiftRecord(workDate: jobDay(8), cashTipsCents: 5_000)],
            paycheckRecords: [], calculator: Self.calculator)
        #expect(plain.split(separator: "\n").first.map(String.init) == CSVExporter.header)

        let tagged = CSVExporter.export(
            records: [
                ShiftRecord(workDate: jobDay(8), cashTipsCents: 5_000, roleName: "Bar", jobName: "Cafe"),
                ShiftRecord(workDate: jobDay(9), cashTipsCents: 5_000),
            ],
            paycheckRecords: [], calculator: Self.calculator)
        let lines = tagged.split(separator: "\n").map(String.init)
        #expect(lines[0] == CSVExporter.header + ",Role,Job")
        #expect(lines[1].hasSuffix(",Bar,Cafe"))
        #expect(lines[2].hasSuffix(",,"))
    }

    @MainActor
    private static func remoteShift(job: String?) -> RemoteShift {
        RemoteShift(record: ShiftRecord(workDate: jobDay(1), cashTipsCents: 1_000, jobName: job),
                    userID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    }

    @MainActor
    private static func remotePaycheck(job: String?) -> RemotePaycheckRecord {
        let record = PaycheckRecord(periodStart: jobDay(1), periodEnd: jobDay(14), paidTipsCents: 0)
        record.jobName = job
        return RemotePaycheckRecord(record: record, userID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    }

    @Test("a shift's job is always sent, null for the primary, and round-trips")
    @MainActor
    func shiftWire() throws {
        let none = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.remoteShift(job: nil))) as? [String: Any])
        #expect(none["job_name"] is NSNull)
        var row = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.remoteShift(job: "Cafe"))) as? [String: Any])
        #expect(row["job_name"] as? String == "Cafe")
        row["user_id"] = "11111111-1111-4111-8111-111111111111"
        #expect(try JSONDecoder().decode(RemoteShift.self, from: JSONSerialization.data(withJSONObject: row)).jobName == "Cafe")
        row.removeValue(forKey: "job_name")
        #expect(try JSONDecoder().decode(RemoteShift.self, from: JSONSerialization.data(withJSONObject: row)).jobName == nil)
        #expect(try Self.remoteShift(job: "Cafe").contentFingerprint != Self.remoteShift(job: nil).contentFingerprint)
    }

    @Test("a paycheck's job is always sent, null for the primary; its fingerprint is unchanged without one")
    @MainActor
    func paycheckWire() throws {
        let none = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.remotePaycheck(job: nil))) as? [String: Any])
        #expect(none["job_name"] is NSNull)
        // The other keys are exactly the synthesized shape's: nil optionals omitted.
        #expect(none["note"] == nil)
        let row = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.remotePaycheck(job: "Cafe"))) as? [String: Any])
        #expect(row["job_name"] as? String == "Cafe")
        let decoded = try JSONDecoder().decode(RemotePaycheckRecord.self, from: JSONSerialization.data(withJSONObject: row))
        #expect(decoded.jobName == "Cafe")
        let value = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.remotePaycheck(job: nil).businessValue)) as? [String: Any])
        #expect(!value.keys.contains("jobName"))
        #expect(try Self.remotePaycheck(job: "Cafe").contentFingerprint != Self.remotePaycheck(job: nil).contentFingerprint)
    }
}
