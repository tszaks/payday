import Foundation
import Testing
@testable import Payday

/// The mid-session straddle, and the completion of gate 7.
///
/// ## What the straddle was
///
/// `shiftsAreAuthoritativeForCurrentAccount` is re-read on every render, so a
/// sync completing mid-session re-renders every screen from the new source.
/// Measured while reviewing the flip: that is correct everywhere except one
/// case. A `.edit(TipEntry)` sheet open across the flip commits through
/// `commitLiveEdit` into the legacy representation, which readers no longer
/// read. The deriver runs legacy-to-records only, so the edit comes back on
/// the next server fold and pull rather than being lost -- but in the interval
/// the person edited their shift and watched it revert, which presents as the
/// app losing their correction.
///
/// The fix REMOVES the case rather than handling it: a promotion cannot occur
/// while a legacy-edit sheet is open, so no sheet can straddle one.
///
/// ## The asymmetry is the point
///
/// `demotionIsNeverDeferred` below is the case that disagrees with the rule,
/// and it is the reason this suite exists rather than a single happy-path
/// test. Deferring a demotion would keep every screen reading a
/// representation the server has just withdrawn -- worse than the straddle it
/// would be avoiding. The deferral may only ever delay GAINING trust.
@Suite("Flip straddle deferral", .serialized)
@MainActor
struct FlipStraddleDeferralTests {

    private func ready() -> ShiftReadAuthority.State {
        ShiftReadAuthority.State.probe(
            migratedAt: Date(timeIntervalSince1970: 1_750_000_000),
            remainingGroupCount: 0
        )
    }

    private func account(authoritative: Bool) -> UUID {
        if let existing = PaydaySyncState.registeredUserID {
            PaydaySyncState.forget(userID: existing)
        }
        let id = UUID()
        PaydaySyncState.forget(userID: id)
        _ = PaydaySyncState.registerCurrentUser(id)
        if authoritative {
            PaydaySyncState.mutate(userID: id) {
                $0.shiftsAreAuthoritativeAt = "2026-09-18T00:00:00.000Z"
            }
        }
        LegacyEditSheetPresence.resetForTesting()
        return id
    }

    // MARK: - The four outcomes

    @Test("a ready account with no sheet open promotes")
    func promotesWhenClear() {
        #expect(ShiftReadAuthority.resolve(
            ready(), currentlyAuthoritative: false, legacyEditSheetPresented: false
        ) == .promote)
    }

    @Test("a ready account with a legacy-edit sheet open defers")
    func defersWhileLegacySheetOpen() {
        #expect(ShiftReadAuthority.resolve(
            ready(), currentlyAuthoritative: false, legacyEditSheetPresented: true
        ) == .deferPromotion)
    }

    /// **The disagreeing case.** A rollback or a failed conservation check is
    /// the server withdrawing its own conversion, so it takes effect while a
    /// sheet is open -- the one thing the deferral must NOT do.
    @Test(
        "a demotion is never deferred, even with a legacy-edit sheet open",
        arguments: [
            ShiftReadAuthority.State.probe(
                migratedAt: Date(timeIntervalSince1970: 1),
                rollbackAt: Date(timeIntervalSince1970: 2),
                remainingGroupCount: 0
            ),
            ShiftReadAuthority.State.probe(
                migratedAt: Date(timeIntervalSince1970: 1),
                conservationFailedAt: Date(timeIntervalSince1970: 2),
                remainingGroupCount: 0
            ),
        ]
    )
    func demotionIsNeverDeferred(_ state: ShiftReadAuthority.State) {
        #expect(ShiftReadAuthority.resolve(
            state, currentlyAuthoritative: true, legacyEditSheetPresented: true
        ) == .demote)
    }

    @Test("an unready, non-authoritative account is unchanged whatever is on screen")
    func unchangedWhenNothingToDo() {
        let notReady = ShiftReadAuthority.State.probe(remainingGroupCount: 3)
        #expect(ShiftReadAuthority.resolve(
            notReady, currentlyAuthoritative: false, legacyEditSheetPresented: false
        ) == .unchanged)
        #expect(ShiftReadAuthority.resolve(
            notReady, currentlyAuthoritative: false, legacyEditSheetPresented: true
        ) == .unchanged)
    }

    // MARK: - The writer actually writes, and actually does not

    @Test("promotion persists; deferral leaves the account exactly as it was")
    func writerHonoursTheOutcome() {
        let id = account(authoritative: false)

        LegacyEditSheetPresence.begin()
        let deferred = PaydaySyncState.applyShiftAuthority(ready(), for: id)
        #expect(deferred == .deferPromotion)
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id),
                "a deferral must not write; if it did, the sheet's next commit straddles")

        LegacyEditSheetPresence.end()
        let promoted = PaydaySyncState.applyShiftAuthority(ready(), for: id)
        #expect(promoted == .promote)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id),
                "and the very next pass must promote, or a deferral becomes permanent")
    }

    @Test("demotion clears the flag even while a sheet is open")
    func writerDemotesThroughAnOpenSheet() {
        let id = account(authoritative: true)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id))

        LegacyEditSheetPresence.begin()
        let outcome = PaydaySyncState.applyShiftAuthority(
            ShiftReadAuthority.State.probe(
                migratedAt: Date(timeIntervalSince1970: 1),
                rollbackAt: Date(timeIntervalSince1970: 2),
                remainingGroupCount: 0
            ),
            for: id
        )
        LegacyEditSheetPresence.end()

        #expect(outcome == .demote)
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id))
    }

    // MARK: - The hold nests

    /// A day detail sheet presenting a log sheet over itself is a real path,
    /// so the first dismissal must not release a hold the second still needs.
    @Test("two open legacy sheets need two dismissals to release the hold")
    func presenceNests() {
        LegacyEditSheetPresence.resetForTesting()
        LegacyEditSheetPresence.begin()
        LegacyEditSheetPresence.begin()
        LegacyEditSheetPresence.end()
        #expect(LegacyEditSheetPresence.isPresented,
                "one sheet is still open, so the promotion must still be held")
        LegacyEditSheetPresence.end()
        #expect(!LegacyEditSheetPresence.isPresented)
    }

    @Test("an unbalanced dismissal cannot drive the count negative")
    func presenceClampsAtZero() {
        LegacyEditSheetPresence.resetForTesting()
        LegacyEditSheetPresence.end()
        LegacyEditSheetPresence.end()
        LegacyEditSheetPresence.begin()
        // A `Comment` needs a literal, not a concatenation.
        #expect(LegacyEditSheetPresence.isPresented,
                "a negative count would read as no-sheet-open forever, silently disabling the deferral")
    }

    // MARK: - Gate 7, the durable half

    /// Each of the four conditions refuses authority ON ITS OWN.
    ///
    /// This is the half of gate 7 a test can actually own: the predicate's
    /// LOGIC. It is deliberately separate from the empirical claim below,
    /// because conflating them would make the gate read as proving something
    /// it structurally cannot.
    @Test(
        "the predicate refuses each partial state independently",
        arguments: [
            // Never converted.
            ShiftReadAuthority.State.probe(remainingGroupCount: 0),
            // Converted, then rolled back.
            ShiftReadAuthority.State.probe(
                migratedAt: Date(timeIntervalSince1970: 1),
                rollbackAt: Date(timeIntervalSince1970: 2),
                remainingGroupCount: 0
            ),
            // Converted, but the money did not add up.
            ShiftReadAuthority.State.probe(
                migratedAt: Date(timeIntervalSince1970: 1),
                conservationFailedAt: Date(timeIntervalSince1970: 2),
                remainingGroupCount: 0
            ),
            // Converted, but not finished: some nights have shifts and some
            // have only legacy rows.
            ShiftReadAuthority.State.probe(
                migratedAt: Date(timeIntervalSince1970: 1),
                remainingGroupCount: 1
            ),
        ]
    )
    func gate7PredicateRefusesEveryPartialState(_ state: ShiftReadAuthority.State) {
        #expect(!ShiftReadAuthority.isAuthoritative(state))
    }

    /// And the positive, so the four above are not passing because the
    /// predicate refuses everything.
    @Test("the predicate accepts a fully converted, unrolled, conserved account")
    func gate7PredicateAcceptsAReadyAccount() {
        #expect(ShiftReadAuthority.isAuthoritative(ready()))
    }

    /// The flip ships as a no-op, asserted the only way a suite can assert it.
    ///
    /// **What this proves:** with nothing having written
    /// `shiftsAreAuthoritativeAt`, a freshly registered account reads
    /// non-authoritative, so every switched surface takes the legacy path and
    /// the flip changes no behaviour for such an account.
    ///
    /// **What this does NOT prove, and must not be read as proving:** that no
    /// account in PRODUCTION is authoritative today. A suite cannot know the
    /// server's state. That claim rests on a separate, empirical fact --
    /// `applyShiftAuthority` is the only writer of the field and no sync leg
    /// calls it yet, so no device has ever promoted an account -- and it has
    /// to be RE-CHECKED against the server at flip time rather than inherited
    /// from a green suite. Keeping the two apart is the point; a gate that
    /// blurs them reports more confidence than it has.
    @Test("an account with no authority ever written reads non-authoritative")
    func gate7FreshAccountIsNotAuthoritative() {
        let id = account(authoritative: false)
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id))
        #expect(!PaydaySyncState.shiftsAreAuthoritativeForCurrentAccount)
    }
}
