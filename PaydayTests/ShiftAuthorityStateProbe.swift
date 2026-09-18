import Foundation
@testable import Payday

extension ShiftReadAuthority.State {
    /// A conversion row for tests, with every column defaulted so a test can
    /// name only the one it is about.
    ///
    /// **The defaults live HERE and not on the production initializer, and
    /// that split is the whole point.**
    ///
    /// On the production type a default is a hazard: `isAuthoritative` opens
    /// with `guard migratedAt != nil`, so an all-nil `State` demotes a
    /// converted account, and an earlier draft of the sync leg wrote exactly
    /// `fetch() ?? State()` as a defensive fallback for a missing row. RLS on
    /// `shift_migration_state` is `for select ... using (auth.uid() =
    /// user_id)`, so an unauthorised read returns ZERO ROWS rather than an
    /// error -- meaning that fallback would have flipped the representation
    /// on every auth blip, indistinguishably from "never converted". With no
    /// defaults on the real initializer, `?? State()` does not compile.
    ///
    /// In a test the same defaults are pure legibility. `probe(remainingGroupCount: 1)`
    /// says "this column, alone, refuses"; spelling out three nils beside it
    /// buries the one fact the test exists to assert.
    ///
    /// Tried first and REJECTED because it does not work: keeping the
    /// defaults and adding an `@available(*, unavailable) init()` overload.
    /// Swift resolves `State()` to the fully-defaulted memberwise init and
    /// builds clean. Probed with a real call site rather than assumed -- the
    /// build SUCCEEDED, which is the only reason this file exists instead of
    /// a comment claiming a guard that was never there.
    static func probe(
        migratedAt: Date? = nil,
        rollbackAt: Date? = nil,
        conservationFailedAt: Date? = nil,
        remainingGroupCount: Int? = nil
    ) -> Self {
        ShiftReadAuthority.State(
            migratedAt: migratedAt,
            rollbackAt: rollbackAt,
            conservationFailedAt: conservationFailedAt,
            remainingGroupCount: remainingGroupCount
        )
    }
}
