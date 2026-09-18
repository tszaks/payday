import Foundation
import Testing
@testable import Payday
@testable import PaydayCore

/// The proof the canonicalization was for: one shift fingerprints the same
/// whichever adapter read it.
///
/// Before `tipOutCents` was canonicalized to `?? 0`, a shift with an explicit
/// zero tip-out digested differently through `ShiftInputAdapter` (which
/// preserves `0` off `ShiftRecord.tipOutCents`) than through
/// `LegacySnapshotBridge` (which yields `nil`, because `TipBreakdown` had
/// already summed both cases to 0 and the bridge cannot recover which it
/// had). Money was identical either way, so the digest was reporting a change
/// that could not affect any answer.
///
/// That mattered because the bridge-to-store swap is supposed to be a no-op
/// for a real account. A differing digest is the one observable that could
/// have contradicted it.
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

    private static func manifest(_ input: ShiftInput) throws -> InputManifest {
        try InputManifest(
            shifts: [input], paychecks: [], schedule: nil,
            rates: [], calendars: [], asOf: input.workDay
        )
    }

    /// The case that used to diverge: an EXPLICIT zero tip-out.
    @Test("an explicit-zero tip-out fingerprints identically through both adapters")
    func explicitZeroAgreesAcrossPaths() throws {
        let record = ShiftRecord(
            workDate: Self.today, shiftPeriod: .dinner,
            cashTipsCents: 5_600, creditTipsCents: 9_900,
            tipOutCents: 0, hoursWorked: 5.5, recordedAt: Self.today
        )

        let adapted = ShiftInputAdapter.adapt([record], calendars: Self.calendars())
        let viaAdapter = try #require(adapted.inputs.first)
        let bridgedRaw = LegacySnapshotBridge.shiftInput(
            for: (day: record.workDate, shiftID: record.id,
                  items: ShiftProjection.rows(for: record)),
            payrollTimeZone: Self.zone
        )
        let viaBridge = try #require(bridgedRaw)

        // The VALUES still differ, deliberately: each side is faithful to the
        // input it has.
        #expect(viaAdapter.tipOutCents == 0)
        #expect(viaBridge.tipOutCents == nil)

        // The DIGESTS now agree, which is the whole point.
        let a = try Self.manifest(viaAdapter)
        let b = try Self.manifest(viaBridge)
        #expect(a.digest == b.digest)
        #expect(a.shiftsDigest == b.shiftsDigest)
    }

    /// And the never-entered case, which my first attempted fix would have
    /// broken while fixing the one above. Both must hold at once.
    @Test("a never-entered tip-out also fingerprints identically through both adapters")
    func neverEnteredAgreesAcrossPaths() throws {
        let record = ShiftRecord(
            workDate: Self.today, shiftPeriod: .dinner,
            cashTipsCents: 5_600, creditTipsCents: 9_900,
            tipOutCents: nil, hoursWorked: 5.5, recordedAt: Self.today
        )

        let adapted = ShiftInputAdapter.adapt([record], calendars: Self.calendars())
        let viaAdapter = try #require(adapted.inputs.first)
        let bridgedRaw = LegacySnapshotBridge.shiftInput(
            for: (day: record.workDate, shiftID: record.id,
                  items: ShiftProjection.rows(for: record)),
            payrollTimeZone: Self.zone
        )
        let viaBridge = try #require(bridgedRaw)

        #expect(viaAdapter.tipOutCents == nil)
        #expect(viaBridge.tipOutCents == nil)

        let a = try Self.manifest(viaAdapter)
        let b = try Self.manifest(viaBridge)
        #expect(a.digest == b.digest)
    }

    /// A real tip-out must still change the fingerprint, so the collapse is
    /// scoped to nil-versus-zero and has not blunted the detector.
    @Test("a real tip-out still changes the fingerprint")
    func realTipOutStillMovesTheDigest() throws {
        func manifest(tipOut: Int?) throws -> InputManifest {
            let record = ShiftRecord(
                workDate: Self.today, cashTipsCents: 5_600, creditTipsCents: 9_900,
                tipOutCents: tipOut, hoursWorked: 5.5, recordedAt: Self.today
            )
            let adapted = ShiftInputAdapter.adapt([record], calendars: Self.calendars())
            return try Self.manifest(try #require(adapted.inputs.first))
        }
        #expect(try manifest(tipOut: 1_000).digest != (try manifest(tipOut: 0)).digest)
        #expect(try manifest(tipOut: 1_000).digest != (try manifest(tipOut: nil)).digest)
    }
}
