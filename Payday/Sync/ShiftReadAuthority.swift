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

    /// What to do with a freshly read server state, given what this device
    /// currently believes and what is on screen.
    enum Outcome: Equatable {
        /// Start reading `public.shifts`.
        case promote
        /// Stop reading them. Never deferred; see `resolve`.
        case demote
        /// The server says authoritative, but a sheet editing a LEGACY row is
        /// open, so the switch waits for the next sync pass.
        case deferPromotion
        case unchanged
    }

    /// The one place the flip is allowed to happen, and the one place it is
    /// allowed to be held back.
    ///
    /// ## Why promotion defers
    ///
    /// The flag is re-read on every render, so a sync completing mid-session
    /// re-renders every screen from the new source, which is correct. An open
    /// sheet is mostly safe on its own terms too: `LogTipSheet` captures its
    /// `target` at presentation and `deleteRoute`/`editingRecord` key on that
    /// target's TYPE, so a legacy sheet keeps routing legacy. And a `.new`
    /// sheet deliberately re-reads the flag at save time, so one opened before
    /// a flip writes the NEW representation -- desirable, not a bug.
    ///
    /// One case is left, and it is the one that matters: a `.edit(TipEntry)`
    /// sheet open across the flip commits through `commitLiveEdit` into the
    /// legacy representation, which readers no longer read. The deriver runs
    /// legacy-to-records only, so the edit is recovered on the next server
    /// fold and pull rather than lost -- but for that interval the person
    /// edited their shift and watched it revert. On a money app that presents
    /// as the app losing their correction, which is the trust failure this
    /// whole project exists to prevent, so it does not ship as a documented
    /// caveat.
    ///
    /// Deferral REMOVES the case instead of handling it: no legacy-edit sheet
    /// can straddle a promotion, because a promotion cannot occur while one is
    /// open. The alternative considered was re-resolving a legacy target to its
    /// `ShiftRecord` through `legacyEntryIDs` at save time, which handles the
    /// straddle correctly but leaves it representable.
    ///
    /// ## Why demotion does NOT defer
    ///
    /// `rollbackAt` and `conservationFailedAt` are the server withdrawing its
    /// own conversion -- the money did not add up, or the account was returned
    /// to legacy. Holding a demotion back to protect an open sheet would keep
    /// every screen reading a representation the server has just disowned,
    /// which is strictly worse than the straddle it would be avoiding. So the
    /// asymmetry is deliberate: the deferral only ever delays gaining trust,
    /// never delays losing it.
    static func resolve(
        _ state: State,
        currentlyAuthoritative: Bool,
        legacyEditSheetPresented: Bool
    ) -> Outcome {
        let ready = isAuthoritative(state)
        if currentlyAuthoritative {
            return ready ? .unchanged : .demote
        }
        guard ready else { return .unchanged }
        return legacyEditSheetPresented ? .deferPromotion : .promote
    }
}
