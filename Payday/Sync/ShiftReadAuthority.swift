import Foundation

/// When `public.shifts` becomes the read-authoritative representation for an
/// account.
///
/// Split out as a pure predicate because it is a DESIGN DECISION with four
/// inputs, not a boolean the server hands over. Measured while wiring the
/// flip: nothing in the app ever set `shiftsAreAuthoritativeAt`, so every
/// switch built for the flip was unreachable -- the same
/// coverage-versus-reachability shape that hid the `shiftsAreAuthoritative`
/// wiring for three slices. This is the fact that makes them reachable, so it
/// gets its own tests rather than living inline in a sync method.
///
/// No new migration is required: `public.shift_migration_state` already
/// carries `sms_read_own` RLS and `grant select ... to authenticated`, so a
/// device reads its own row directly.
enum ShiftReadAuthority {

    /// The account-level conversion record, as the device reads it.
    ///
    /// Named fields rather than a decoded row type so the predicate can be
    /// tested without a network shape, and so a column added to the table
    /// does not silently change the rule.
    struct State: Equatable {
        /// The FIRST conversion instant, never moved by a re-run.
        let migratedAt: Date?
        /// Set if the account was rolled back. Authority ends immediately.
        let rollbackAt: Date?
        /// Set if the conversion failed its own conservation check, meaning
        /// the money did not add up.
        let conservationFailedAt: Date?
        /// Legacy groups the conversion has not folded yet.
        let remainingGroupCount: Int?

        init(
            migratedAt: Date? = nil,
            rollbackAt: Date? = nil,
            conservationFailedAt: Date? = nil,
            remainingGroupCount: Int? = nil
        ) {
            self.migratedAt = migratedAt
            self.rollbackAt = rollbackAt
            self.conservationFailedAt = conservationFailedAt
            self.remainingGroupCount = remainingGroupCount
        }
    }

    /// Four conditions, and each one is a way the account is NOT ready.
    ///
    /// It is deliberately not `migratedAt != nil`. That was the obvious
    /// reading and it is wrong three ways:
    ///
    /// 1. **`rollbackAt`** — `rollback_shift_migration()` exists precisely so
    ///    an account can be returned to the legacy representation. Reading
    ///    shifts after a rollback shows a person a representation the server
    ///    has abandoned.
    /// 2. **`conservationFailedAt`** — the conversion checks that the money
    ///    it produced equals the money it consumed. If that check failed, the
    ///    shift rows are the ones whose totals are in doubt, so the legacy
    ///    rows are the safer read. Treating a failed conservation as
    ///    authoritative would show figures the server itself flagged.
    /// 3. **`remainingGroupCount`** — a partly converted account has shifts
    ///    for some nights and only legacy rows for others. Reading shifts
    ///    then hides the unconverted nights entirely, which is worse than
    ///    reading legacy for all of them: a missing night looks like a night
    ///    not worked.
    ///
    /// `remainingGroupCount == nil` counts as ready, matching
    /// `PaydayMigrationReport.isConversionPending`'s `(count ?? 0) > 0`: the
    /// column is null on an account that never had legacy rows to convert.
    static func isAuthoritative(_ state: State) -> Bool {
        guard state.migratedAt != nil else { return false }
        guard state.rollbackAt == nil else { return false }
        guard state.conservationFailedAt == nil else { return false }
        return (state.remainingGroupCount ?? 0) == 0
    }
}
