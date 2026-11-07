import Foundation
import Testing
@testable import PaydayCore

/// PR E1: a job is a name tag. Policies carry an optional job name and the
/// account carries a list of jobs, inside the same compensation_policies
/// JSON. Nothing here changes a figure. Synthetic values throughout.
@Suite("Jobs: policy shape")
struct JobsTests {
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func day(_ iso: String) -> CivilDay { CivilDay(iso: iso)! }

    static let zone = TimeZone(identifier: "America/New_York")!

    static let primaryRate = PayRatePolicy(
        id: uuid(1), effectiveFrom: day("2026-01-01"), hourlyRateCents: 800, provenance: .confirmed)
    static let cafeRate = PayRatePolicy(
        id: uuid(2), effectiveFrom: day("2026-01-01"), hourlyRateCents: 1000, provenance: .confirmed,
        jobName: "Cafe")
    static let primaryCalendar = PayrollCalendarPolicy(
        id: uuid(3), effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: zone)
    static let cafeCalendar = PayrollCalendarPolicy(
        id: uuid(4), effectiveFrom: .distantPast, workweekStartWeekday: 2, payrollTimeZone: zone,
        jobName: "Cafe")

    static let bistro = JobPolicy(id: uuid(10), name: "Bistro", schedule: nil, isPrimary: true)
    static let cafe = JobPolicy(
        id: uuid(11), name: "Cafe",
        schedule: PayScheduleInput(frequency: "weekly", anchorPeriodEnd: day("2026-01-10"), payDelayDays: 5),
        isPrimary: false)

    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("Policy JSON stored before jobs decodes with no jobs and no job names")
    func oldJSONDecodes() throws {
        let old = try Self.encode(CompensationPolicies(rates: [Self.primaryRate], calendars: [Self.primaryCalendar]))
        #expect(!old.contains("job"))
        let decoded = try JSONDecoder().decode(CompensationPolicies.self, from: Data(old.utf8))
        #expect(decoded.jobs == [])
        #expect(decoded.jobNames == [])
        #expect(decoded.rates.allSatisfy { $0.jobName == nil })
        #expect(decoded.calendars.allSatisfy { $0.jobName == nil })
    }

    @Test("With no jobs the encoded JSON is byte-identical to the pre-jobs shape")
    func noJobsEncodesUnchanged() throws {
        let policies = CompensationPolicies(rates: [Self.primaryRate], calendars: [Self.primaryCalendar])
        let encoded = try Self.encode(policies)
        let pinned = try Self.encode(PreJobsShape(
            version: 1, rates: [PreJobsRate(Self.primaryRate)], calendars: [PreJobsCalendar(Self.primaryCalendar)]))
        #expect(encoded == pinned)
    }

    @Test("Jobs and job names round-trip")
    func roundTrip() throws {
        let policies = CompensationPolicies(
            rates: [Self.primaryRate, Self.cafeRate],
            calendars: [Self.primaryCalendar, Self.cafeCalendar],
            jobs: [Self.cafe, Self.bistro])
        let decoded = try JSONDecoder().decode(
            CompensationPolicies.self, from: Data(try Self.encode(policies).utf8))
        #expect(decoded == policies)
        #expect(decoded.jobNames == ["Bistro", "Cafe"])
        #expect(decoded.primaryJob?.name == "Bistro")
    }

    @Test("policies(forJob:) keeps the job's own policies; nil-job policies belong to the primary")
    func policiesForJob() {
        let policies = CompensationPolicies(
            rates: [Self.primaryRate, Self.cafeRate],
            calendars: [Self.primaryCalendar, Self.cafeCalendar],
            jobs: [Self.bistro, Self.cafe])
        let cafe = policies.policies(forJob: " cafe ")
        #expect(cafe.rates.map(\.id) == [Self.cafeRate.id])
        #expect(cafe.calendars.map(\.id) == [Self.cafeCalendar.id])
        let primary = policies.policies(forJob: nil)
        #expect(primary.rates.map(\.id) == [Self.primaryRate.id])
        #expect(primary.calendars.map(\.id) == [Self.primaryCalendar.id])
        #expect(policies.policies(forJob: "Bistro") == primary)
        #expect(policies.policies(forJob: "Nowhere").rates.isEmpty)
    }

    @Test("Editing keeps the jobs")
    func editingKeepsJobs() {
        let policies = CompensationPolicies(rates: [Self.primaryRate], jobs: [Self.bistro, Self.cafe])
        #expect(policies.adding(rate: Self.cafeRate).jobs == policies.jobs)
        #expect(policies.adding(calendar: Self.primaryCalendar).jobs == policies.jobs)
        #expect(policies.removingRate(id: Self.primaryRate.id).jobs == policies.jobs)
        #expect(policies.removingRates(forRole: "Bar").jobs == policies.jobs)
    }

    @Test("Job names are trimmed and capped like role names")
    func nameRules() {
        #expect(JobPolicy(id: Self.uuid(20), name: "  Cafe  ", schedule: nil, isPrimary: false).name == "Cafe")
        #expect(PayRatePolicy(id: Self.uuid(21), effectiveFrom: Self.day("2026-01-01"), hourlyRateCents: 1,
                              provenance: .confirmed, jobName: "   ").jobName == nil)
        #expect(JobPolicy(id: Self.uuid(22), name: String(repeating: "x", count: 60), schedule: nil,
                          isPrimary: false).name.count == 40)
    }
}

/// The pre-jobs wire shape, restated by hand so the byte-identity test does
/// not lean on the code under test.
private struct PreJobsShape: Encodable {
    var version: Int
    var rates: [PreJobsRate]
    var calendars: [PreJobsCalendar]
}

private struct PreJobsRate: Encodable {
    var id: UUID, effectiveFrom: CivilDay, hourlyRateCents: Int, provenance: RateProvenance
    init(_ p: PayRatePolicy) {
        id = p.id; effectiveFrom = p.effectiveFrom; hourlyRateCents = p.hourlyRateCents; provenance = p.provenance
    }
}

private struct PreJobsCalendar: Encodable {
    var id: UUID, effectiveFrom: CivilDay, workweekStartWeekday: Int, overtimeThresholdMinutes: Int
    var overtimeMultiplierHundredths: Int, payrollTimeZone: String
    init(_ p: PayrollCalendarPolicy) {
        id = p.id; effectiveFrom = p.effectiveFrom; workweekStartWeekday = p.workweekStartWeekday
        overtimeThresholdMinutes = p.overtimeThresholdMinutes
        overtimeMultiplierHundredths = p.overtimeMultiplierHundredths
        payrollTimeZone = p.payrollTimeZone.identifier
    }
}
