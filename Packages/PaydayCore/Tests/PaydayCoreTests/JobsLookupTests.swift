import Foundation
import Testing
@testable import PaydayCore

/// E2b item 11: every lookup on an UNFILTERED `CompensationPolicies` answers
/// for the primary job (nil-tagged policies only), and a job's answers come
/// from `policies(forJob:)`. A job-tagged rate or calendar added later than
/// the primary's must never become the primary's answer. Synthetic values.
@Suite("Jobs: lookups answer for the primary")
struct JobsLookupTests {
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func day(_ iso: String) -> CivilDay { CivilDay(iso: iso)! }

    static let east = TimeZone(identifier: "America/New_York")!
    static let west = TimeZone(identifier: "America/Los_Angeles")!

    static let primaryRate = PayRatePolicy(
        id: uuid(1), effectiveFrom: day("2026-01-01"), hourlyRateCents: 800, provenance: .assumedFromLegacySetting)
    /// Later than the primary's on purpose: an unfiltered `.last` would pick it.
    static let cafeRate = PayRatePolicy(
        id: uuid(2), effectiveFrom: day("2026-03-01"), hourlyRateCents: 1000, provenance: .confirmed,
        jobName: "Cafe")
    static let primaryCalendar = PayrollCalendarPolicy(
        id: uuid(3), effectiveFrom: .distantPast, workweekStartWeekday: 1, payrollTimeZone: east)
    static let cafeCalendar = PayrollCalendarPolicy(
        id: uuid(4), effectiveFrom: day("2026-03-01"), workweekStartWeekday: 2, payrollTimeZone: west,
        dailyOvertimeThresholdMinutes: 480, jobName: "Cafe")

    static let primaryOnly = CompensationPolicies(rates: [primaryRate], calendars: [primaryCalendar])
    static let both = CompensationPolicies(
        rates: [primaryRate, cafeRate], calendars: [primaryCalendar, cafeCalendar])
    static let onDay = day("2026-06-01")

    @Test("calendar(on:) ignores a job's calendar")
    func calendarOn() {
        #expect(Self.both.calendar(on: Self.onDay) == Self.primaryOnly.calendar(on: Self.onDay))
        #expect(Self.both.policies(forJob: "Cafe").calendar(on: Self.onDay) == Self.cafeCalendar)
    }

    @Test("rate(on:) ignores a job's rate")
    func rateOn() {
        #expect(Self.both.rate(on: Self.onDay) == Self.primaryRate)
        #expect(Self.both.policies(forJob: "Cafe").rate(on: Self.onDay) == Self.cafeRate)
    }

    @Test("latestCalendar ignores a job's calendar")
    func latestCalendar() {
        #expect(Self.both.latestCalendar == Self.primaryCalendar)
        #expect(Self.both.policies(forJob: "cafe").latestCalendar == Self.cafeCalendar)
    }

    @Test("latestRate ignores a job's rate")
    func latestRate() {
        #expect(Self.both.latestRate == Self.primaryRate)
        #expect(Self.both.policies(forJob: "Cafe").latestRate == Self.cafeRate)
    }

    @Test("allRolesRates ignores a job's rates")
    func allRolesRates() {
        #expect(Self.both.allRolesRates == [Self.primaryRate])
        #expect(Self.both.policies(forJob: "Cafe").allRolesRates == [Self.cafeRate])
    }

    @Test("payrollTimeZone ignores a job's zone")
    func payrollTimeZone() {
        #expect(Self.both.payrollTimeZone == Self.east)
        #expect(Self.both.policies(forJob: "Cafe").payrollTimeZone == Self.west)
    }

    @Test("hasOnlyAssumedRates ignores a job's confirmed rate")
    func hasOnlyAssumedRates() {
        #expect(Self.primaryOnly.hasOnlyAssumedRates)
        #expect(Self.both.hasOnlyAssumedRates)
        #expect(!Self.both.policies(forJob: "Cafe").hasOnlyAssumedRates)
    }

    @Test("The primary's filtered value answers exactly like the unfiltered one")
    func primaryFilterParity() {
        let primary = Self.both.policies(forJob: nil)
        #expect(primary.latestCalendar == Self.both.latestCalendar)
        #expect(primary.latestRate == Self.both.latestRate)
        #expect(primary.payrollTimeZone == Self.both.payrollTimeZone)
    }

    @Test("The lookup scope is never encoded")
    func scopeNotEncoded() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let scoped = String(decoding: try encoder.encode(Self.both.policies(forJob: "Cafe")), as: UTF8.self)
        #expect(!scoped.contains("lookupJob"))
    }
}
