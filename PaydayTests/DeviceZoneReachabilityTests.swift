import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// Why the allowlisted device-zone fallback in `ShiftInputAdapter` is safe,
/// pinned so it cannot silently stop being safe.
///
/// `ShiftInputAdapter.adapt` opens with
/// `calendars.last?.payrollTimeZone ?? .current`. A frozen payroll zone is a
/// T1 guarantee -- a device that travels must not re-date a shift into
/// another week or another pay period -- so a device zone on a valued path
/// would be a real defect: `workDay` and the workweek boundary are computed
/// with that zone, and two phones in two zones could then cross different
/// boundaries and produce different overtime, hence different money.
///
/// Measured: it is not on a valued path. The fallback is reachable only when
/// `calendars` is EMPTY, and with no calendar policy the ledger has no
/// workweek to allocate into, so every wage reads
/// `.unavailable(.noCalendarPolicy)` and no wage cents exist to diverge.
/// `PolicyStore.runMigrationsIfNeeded` then freezes the device zone INTO a
/// policy, and `PaydayCloudGate` calls it on launch and after every sync, so
/// the window is the async hop before that first adoption on one launch.
///
/// The load-bearing fact is therefore "no calendar policy means no wage
/// money". If a future change gave the ledger a default workweek so it could
/// value wages without a policy, the device zone would become money-bearing
/// that instant. This suite fails if that happens, which is the only reason
/// `scripts/lint-device-zone.pl` can allowlist that line at all.
@Suite("Device zone reachability")
@MainActor
struct DeviceZoneReachabilityTests {

    private static let today = Date(timeIntervalSince1970: 1_790_000_000)

    private static func record() -> ShiftRecord {
        ShiftRecord(
            workDate: today, shiftPeriod: .dinner,
            cashTipsCents: 4_200, creditTipsCents: 7_350,
            tipOutCents: 1_100, hoursWorked: 9.75, recordedAt: today
        )
    }

    /// The pin: with NO calendar policy, the device zone cannot move money,
    /// because there is no wage money at all.
    @Test("with no calendar policy the ledger values no wages, so the device zone cannot move money")
    func noCalendarPolicyMeansNoWageMoney() throws {
        let adapted = ShiftInputAdapter.adapt([Self.record()], calendars: [])
        let input = try #require(adapted.inputs.first)

        // A rate exists; only the calendar policy is missing. Without this the
        // test would pass for the wrong reason -- `.rateNotSet` rather than
        // `.noCalendarPolicy`.
        let rates = [PayRatePolicy(
            id: PolicyMigration.deterministicID("devicezone/rate"),
            effectiveFrom: .distantPast,
            hourlyRateCents: 2_000,
            provenance: .confirmed
        )]

        let output = CompensationLedger.evaluate([input], rates: rates, calendars: [])
        let valuation = try #require(output.valuations.first)

        guard case .unavailable(let reason) = valuation.wage else {
            Issue.record("expected .unavailable, got \(valuation.wage) — the device zone is now money-bearing")
            return
        }
        #expect(reason == .noCalendarPolicy)
        #expect(valuation.components.regularWagesCents == 0)
        #expect(valuation.components.overtimeWagesCents == 0)

        // And the hours are real, so this is not "no wages because no hours".
        #expect(input.minutesWorked == 585)

        // The tips survive, which is what the window actually shows a user.
        #expect(valuation.components.voluntaryCashCents == 4_200)
        #expect(valuation.components.voluntaryCreditCents == 7_350)
        #expect(valuation.components.tipOutCents == 1_100)
    }

    /// The contrast, so the pin above is a statement about the missing
    /// CALENDAR policy and not about the ledger refusing everything: add one
    /// and the same shift values its wages.
    @Test("adding a calendar policy makes the same shift wage-valued")
    func withACalendarPolicyTheSameShiftIsValued() throws {
        let calendars = [PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("devicezone/calendar"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: 2,
            payrollTimeZone: TimeZone(identifier: "America/New_York")!
        )]
        let adapted = ShiftInputAdapter.adapt([Self.record()], calendars: calendars)
        let input = try #require(adapted.inputs.first)
        let rates = [PayRatePolicy(
            id: PolicyMigration.deterministicID("devicezone/rate"),
            effectiveFrom: .distantPast,
            hourlyRateCents: 2_000,
            provenance: .confirmed
        )]

        let output = CompensationLedger.evaluate([input], rates: rates, calendars: calendars)
        let valuation = try #require(output.valuations.first)
        guard case .valued = valuation.wage else {
            Issue.record("expected .valued with a calendar policy, got \(valuation.wage)")
            return
        }
        #expect(valuation.components.regularWagesCents > 0)
    }
}
