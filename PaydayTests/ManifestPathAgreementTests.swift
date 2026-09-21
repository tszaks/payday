import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// The canonicalization the whole file exists to pin: a shift's explicit-zero
/// tip-out and its never-entered tip-out must fingerprint identically.
///
/// Before `tipOutCents` was canonicalized to `?? 0`, a shift with an explicit
/// zero digested differently than one carrying `nil`. Money was identical
/// either way, so the digest was reporting a change that could not affect any
/// answer — a differing digest for the same account is the one observable
/// that could contradict "the store is a no-op for the same data."
///
/// The bridge path this was originally measured against is gone with the
/// flip; `ShiftInputAdapter` is now the single boundary, so the assertion
/// runs on it alone.
@Suite("Manifest path agreement")
@MainActor
struct ManifestPathAgreementTests {

    private static let zone = TimeZone(identifier: "America/New_York")!
    private static let today = Date(timeIntervalSince1970: 1_790_000_000)

    private static func calendars() -> [PayrollCalendarPolicy] {
        [PayrollCalendarPolicy(
            id: PolicyMigration.deterministicID("pathagree/calendar"),
            effectiveFrom: .distantPast,
            workweekStartWeekday: 2,
            payrollTimeZone: zone
        )]
    }

    private static func manifest(tipOut: Int?) throws -> (input: ShiftInput, manifest: InputManifest) {
        // A FIXED id: the digest covers `s.id.uuidString`, so two records that
        // differ only in tipOut must share one, or the digests disagree on the
        // id and the assertion measures a UUID instead of the collapse.
        let record = ShiftRecord(
            id: PolicyMigration.deterministicID("pathagree/shift"),
            workDate: Self.today, shiftPeriod: .dinner,
            cashTipsCents: 5_600, creditTipsCents: 9_900,
            tipOutCents: tipOut, hoursWorked: 5.5, recordedAt: Self.today
        )
        let adapted = ShiftInputAdapter.adapt([record], calendars: Self.calendars())
        let input = try #require(adapted.inputs.first)
        let manifest = try InputManifest(
            shifts: [input], paychecks: [], schedule: nil,
            rates: [], calendars: [], asOf: input.workDay
        )
        return (input, manifest)
    }

    /// The case that used to diverge: an EXPLICIT zero tip-out must digest
    /// the same as a never-entered one.
    @Test("explicit-zero and never-entered tip-outs fingerprint identically")
    func explicitZeroAgreesWithNeverEntered() throws {
        let zero = try Self.manifest(tipOut: 0)
        let never = try Self.manifest(tipOut: nil)

        // The INPUTS still differ, deliberately: the adapter is faithful to
        // the stored field.
        #expect(zero.input.tipOutCents == 0)
        #expect(never.input.tipOutCents == nil)

        // The DIGESTS agree, which is the whole point.
        #expect(zero.manifest.digest == never.manifest.digest)
        #expect(zero.manifest.shiftsDigest == never.manifest.shiftsDigest)
    }

    /// A real tip-out must still change the fingerprint, so the collapse is
    /// scoped to nil-versus-zero and has not blunted the detector.
    @Test("a real tip-out still changes the fingerprint")
    func realTipOutStillMovesTheDigest() throws {
        #expect(try Self.manifest(tipOut: 1_000).manifest.digest != Self.manifest(tipOut: 0).manifest.digest)
        #expect(try Self.manifest(tipOut: 1_000).manifest.digest != Self.manifest(tipOut: nil).manifest.digest)
    }
}
