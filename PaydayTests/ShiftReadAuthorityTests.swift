import Foundation
import Testing
@testable import Payday

/// The predicate that decides when `public.shifts` becomes the read
/// representation, and each way it must refuse.
///
/// Worth its own suite because the obvious reading -- "migrated_at is set" --
/// is wrong three ways, and each wrong way shows a user something false
/// rather than merely being untidy.
@Suite("Shift read authority")
struct ShiftReadAuthorityTests {

    private static let then = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("an unconverted account is not authoritative")
    func unconvertedIsNotAuthoritative() {
        #expect(!ShiftReadAuthority.isAuthoritative(.init()))
    }

    @Test("a fully converted account is authoritative")
    func convertedIsAuthoritative() {
        #expect(ShiftReadAuthority.isAuthoritative(
            .init(migratedAt: Self.then, remainingGroupCount: 0)
        ))
    }

    /// `remaining_group_count` is null on an account that never had legacy
    /// rows to convert, which is ready rather than pending. Matches
    /// `PaydayMigrationReport.isConversionPending`'s `(count ?? 0) > 0`, so
    /// the two readings of the same column cannot disagree.
    @Test("a null remaining count is ready, not pending")
    func nullRemainingCountIsReady() {
        #expect(ShiftReadAuthority.isAuthoritative(
            .init(migratedAt: Self.then, remainingGroupCount: nil)
        ))
    }

    /// A rolled-back account must stop being authoritative immediately.
    /// `rollback_shift_migration()` exists precisely so an account can be
    /// returned to the legacy representation; continuing to read shifts shows
    /// a person a representation the server has abandoned.
    @Test("a rolled-back account is not authoritative, even though it converted")
    func rollbackRevokesAuthority() {
        #expect(!ShiftReadAuthority.isAuthoritative(
            .init(migratedAt: Self.then, rollbackAt: Self.then, remainingGroupCount: 0)
        ))
    }

    /// The conversion checks that the money it produced equals the money it
    /// consumed. If that failed, the SHIFT rows are the ones in doubt, so the
    /// legacy rows are the safer read -- treating a failed conservation as
    /// authoritative would show figures the server itself flagged.
    @Test("a failed conservation check is not authoritative")
    func conservationFailureRevokesAuthority() {
        #expect(!ShiftReadAuthority.isAuthoritative(
            .init(migratedAt: Self.then, conservationFailedAt: Self.then, remainingGroupCount: 0)
        ))
    }

    /// The subtlest one. A partly converted account has shifts for some
    /// nights and only legacy rows for others, so reading shifts HIDES the
    /// unconverted nights entirely -- and a missing night looks like a night
    /// not worked, which is worse than reading legacy for all of them.
    @Test("a partly converted account is not authoritative")
    func remainingGroupsRevokeAuthority() {
        #expect(!ShiftReadAuthority.isAuthoritative(
            .init(migratedAt: Self.then, remainingGroupCount: 1)
        ))
        #expect(!ShiftReadAuthority.isAuthoritative(
            .init(migratedAt: Self.then, remainingGroupCount: 47)
        ))
    }

    /// Each refusal is INDEPENDENTLY sufficient, asserted so a future edit
    /// cannot make one of them merely advisory by combining conditions.
    @Test("each refusal stands alone")
    func eachRefusalIsSufficient() {
        let ready = ShiftReadAuthority.State(migratedAt: Self.then, remainingGroupCount: 0)
        #expect(ShiftReadAuthority.isAuthoritative(ready))

        let refusals: [(String, ShiftReadAuthority.State)] = [
            ("never converted", .init(remainingGroupCount: 0)),
            ("rolled back", .init(migratedAt: Self.then, rollbackAt: Self.then, remainingGroupCount: 0)),
            ("conservation failed", .init(migratedAt: Self.then, conservationFailedAt: Self.then, remainingGroupCount: 0)),
            ("groups remaining", .init(migratedAt: Self.then, remainingGroupCount: 1)),
        ]
        for (reason, state) in refusals {
            #expect(!ShiftReadAuthority.isAuthoritative(state),
                    "\(reason) must be sufficient on its own to refuse authority")
        }
    }
}
