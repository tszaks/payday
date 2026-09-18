import Foundation
import Testing
@testable import Payday

/// The sync leg that makes the flip reachable, and the liveness requirement
/// `docs/design/PR2-S14-writer-flip.md` records for this slice.
///
/// ## What changed
///
/// `PaydaySyncState.applyShiftAuthority` had no caller by design: that is what
/// made S14 a provable no-op. This slice adds the caller — `synchronize` reads
/// `public.shift_migration_state` and hands the result to the predicate — so
/// from here an account can actually become authoritative.
///
/// ## The liveness requirement, and why it is not optional
///
/// `ShiftReadAuthority.resolve` returns `.deferPromotion` while a legacy-edit
/// sheet is open, and **nothing inside the deferral re-arms it.** A caller
/// that treated that outcome as a no-op would strand the account on the legacy
/// representation for the rest of the session: a guard against a few-seconds
/// straddle turned into an indefinite one. So the leg maps
/// `.deferPromotion` onto `requiresFollowUpSync`, which is what makes the
/// deferral a DELAY rather than a cancellation.
///
/// The decode half is tested here rather than the network half: the fetch is
/// three chained Supabase builder calls with no branching, while the mapping
/// from stored columns to the predicate's four inputs is where a wrong answer
/// would be silent. A `rollback_at` that failed to parse would read as "no
/// rollback" and promote an account the server had disowned.
@Suite("Shift authority sync leg", .serialized)
@MainActor
struct ShiftAuthorityLegTests {

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

    /// A fully converted, unrolled, conserved account.
    static let readyJSON = #"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":"2026-09-18T12:00:00.000Z","rollback_at":null,"conservation_failed_at":null,"remaining_group_count":0}"#

    /// A converted account the server has since rolled back.
    static let rolledBackJSON = #"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":"2026-09-18T12:00:00.000Z","rollback_at":"2026-09-18T13:00:00.000Z","conservation_failed_at":null,"remaining_group_count":0}"#

    private func decode(_ json: String) throws -> RemoteShiftMigrationState {
        try JSONDecoder().decode(RemoteShiftMigrationState.self, from: Data(json.utf8))
    }

    // MARK: - The column mapping

    /// A converted, unrolled, fully folded account maps to authoritative.
    @Test("a completed conversion row maps to an authoritative state")
    func completedConversionMapsToAuthoritative() throws {
        let row = try decode("""
        {"user_id":"00000000-0000-0000-0000-0000000000a1",
         "migrated_at":"2026-09-18T12:00:00.000Z",
         "rollback_at":null,
         "conservation_failed_at":null,
         "remaining_group_count":0}
        """)
        #expect(ShiftReadAuthority.isAuthoritative(try row.authorityState()))
    }

    /// Each column that must REFUSE authority, parsed from real JSON rather
    /// than constructed in Swift — because the failure being guarded against
    /// is a timestamp that does not parse and therefore reads as absent.
    ///
    /// A `rollback_at` silently read as nil promotes an account the server has
    /// withdrawn, which is the worst direction for this particular field to
    /// fail in.
    @Test(
        "each refusing column refuses after a real decode",
        arguments: [
            #"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":null,"rollback_at":null,"conservation_failed_at":null,"remaining_group_count":0}"#,
            #"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":"2026-09-18T12:00:00.000Z","rollback_at":"2026-09-18T13:00:00.000Z","conservation_failed_at":null,"remaining_group_count":0}"#,
            #"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":"2026-09-18T12:00:00.000Z","rollback_at":null,"conservation_failed_at":"2026-09-18T13:00:00.000Z","remaining_group_count":0}"#,
            #"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":"2026-09-18T12:00:00.000Z","rollback_at":null,"conservation_failed_at":null,"remaining_group_count":3}"#,
        ]
    )
    func refusingColumnsRefuseAfterDecode(_ json: String) throws {
        let row = try decode(json)
        #expect(!ShiftReadAuthority.isAuthoritative(try row.authorityState()))
    }

    /// The timestamps actually PARSE. Without this the suite above passes for
    /// the wrong reason: an unparseable `rollback_at` is nil, and nil refuses
    /// nothing — it would look like a pass while the account got promoted.
    ///
    /// **Why all three and not just `migrated_at`.** The two withdrawal
    /// markers fail in the OPPOSITE direction from the conversion marker, and
    /// this test is the one that holds that. An unparseable `migrated_at`
    /// reads as "never converted" and demotes a promoted account; an
    /// unparseable `rollback_at` or `conservation_failed_at` reads as "not
    /// withdrawn" and keeps an account authoritative that the server
    /// explicitly disowned, showing figures its own conservation check
    /// flagged. Both are covered because `authorityState()` throws on any
    /// present-but-unreadable value — see its header for why that symmetry is
    /// deliberate rather than a side effect of how the helper is written.
    @Test("the refusing timestamps parse rather than reading as absent")
    func refusingTimestampsParse() throws {
        let row = try decode("""
        {"user_id":"00000000-0000-0000-0000-0000000000a1",
         "migrated_at":"2026-09-18T12:00:00.000Z",
         "rollback_at":"2026-09-18T13:00:00.000Z",
         "conservation_failed_at":"2026-09-18T14:00:00.000Z",
         "remaining_group_count":0}
        """)
        let state = try row.authorityState()
        #expect(state.migratedAt != nil, "migrated_at must parse")
        #expect(state.rollbackAt != nil, "rollback_at must parse, or a rollback reads as absent")
        #expect(state.conservationFailedAt != nil, "conservation_failed_at must parse")
    }

    /// An account with NO conversion row at all, which is every account today.
    ///
    /// The leg does NOT hand this state to `applyShiftAuthority` -- see
    /// `emptyStateWouldDemote` below for why that would be a defect. What this
    /// pins is the predicate's own answer: an empty state is not
    /// authoritative, so nothing anywhere can read a missing row as a
    /// conversion.
    @Test("an absent conversion row is non-authoritative")
    func absentRowIsNotAuthoritative() {
        #expect(!ShiftReadAuthority.isAuthoritative(ShiftReadAuthority.State()))
    }

    // MARK: - Liveness

    /// **The requirement the design doc records for this slice.** A deferred
    /// promotion is re-attempted and COMPLETES once the sheet closes.
    ///
    /// Written as the sequence the leg actually performs — resolve, observe
    /// the outcome, and on the next pass resolve again — so it fails if
    /// someone makes the deferral terminal.
    @Test("a deferred promotion completes on the next pass once the sheet closes")
    func deferredPromotionIsReattempted() {
        let id = account(authoritative: false)
        let ready = ShiftReadAuthority.State(
            migratedAt: Date(timeIntervalSince1970: 1_750_000_000),
            remainingGroupCount: 0
        )

        // Pass 1, with a legacy-edit sheet open.
        LegacyEditSheetPresence.begin()
        let first = PaydaySyncState.applyShiftAuthority(ready, for: id)
        #expect(first == .deferPromotion)
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id))

        // The outcome the leg turns into `requiresFollowUpSync`. If this ever
        // stops being `.deferPromotion`, the follow-up is never requested and
        // the account is stranded for the session.
        #expect(first == .deferPromotion,
                "the leg maps exactly this outcome onto requiresFollowUpSync")

        // The sheet closes.
        LegacyEditSheetPresence.end()

        // Pass 2, which the follow-up sync performs.
        let second = PaydaySyncState.applyShiftAuthority(ready, for: id)
        #expect(second == .promote)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id),
                "a deferral must be a delay, not a cancellation")
    }

    /// And the case that would make the follow-up pointless: a promotion that
    /// is NOT deferred needs no second pass, so the leg must not ask for one.
    ///
    /// Stated because the cheap fix for the liveness bug is "always request a
    /// follow-up", which would make every sync request another sync forever.
    @Test("an undeferred promotion needs no follow-up pass")
    func undeferredPromotionNeedsNoFollowUp() {
        let id = account(authoritative: false)
        let ready = ShiftReadAuthority.State(
            migratedAt: Date(timeIntervalSince1970: 1_750_000_000),
            remainingGroupCount: 0
        )
        let outcome = PaydaySyncState.applyShiftAuthority(ready, for: id)
        #expect(outcome == .promote)
        #expect(outcome != .deferPromotion, "so requiresFollowUpSync stays false for this pass")
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id))
    }

    /// A steady state must not request a follow-up either: an already
    /// authoritative account whose server state is unchanged resolves
    /// `.unchanged`, so repeated syncs do not chase each other.
    @Test("a steady authoritative account resolves unchanged and asks for nothing")
    func steadyStateAsksForNothing() {
        let id = account(authoritative: true)
        let ready = ShiftReadAuthority.State(
            migratedAt: Date(timeIntervalSince1970: 1_750_000_000),
            remainingGroupCount: 0
        )
        let outcome = PaydaySyncState.applyShiftAuthority(ready, for: id)
        #expect(outcome == .unchanged)
        #expect(outcome != .deferPromotion)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id))
    }

    // MARK: - A failed read must not demote

    /// **The defect this leg shipped with in its first draft**, and the one
    /// place the demotion asymmetry cuts the wrong way.
    ///
    /// `resolve` returns `.demote` on the `currentlyAuthoritative` branch
    /// whenever `isAuthoritative` is false, and `isAuthoritative` opens with
    /// `guard migratedAt != nil`. So an EMPTY `State` demotes a converted
    /// account. The first draft substituted `ShiftReadAuthority.State()` for a
    /// missing row, which turns any read returning nothing into a
    /// representation flip for that user.
    ///
    /// And "returns nothing" is quiet: RLS here is
    /// `for select ... using (auth.uid() = user_id)`, so a request that fails
    /// to authenticate as the owner yields ZERO ROWS rather than an error.
    ///
    /// This pins the CONSEQUENCE rather than the fix, so it fails if anyone
    /// reintroduces the empty-state substitution.
    @Test("an empty state would demote an authoritative account, which is why the leg skips it")
    func emptyStateWouldDemote() {
        let id = account(authoritative: true)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id))
        let outcome = ShiftReadAuthority.resolve(
            ShiftReadAuthority.State(),
            currentlyAuthoritative: true,
            legacyEditSheetPresented: false
        )
        #expect(outcome == .demote,
                "an empty state demotes, so a failed read must never be turned into one")
    }

    /// The other direction, which is why skipping is correct rather than
    /// merely cautious: a REAL withdrawal arrives as a column on an existing
    /// row, so it still demotes immediately.
    ///
    /// The server signals withdrawal by SETTING a column, never by removing
    /// the row -- nothing in any migration deletes from
    /// `shift_migration_state`, which is rollback's only anchor. So an absent
    /// row can never legitimately mean "withdrawn", and skipping it loses no
    /// real signal.
    @Test("a real withdrawal still demotes immediately, decoded from its row")
    func realWithdrawalStillDemotes() throws {
        let id = account(authoritative: true)
        let row = try decode(Self.rolledBackJSON)
        let outcome = PaydaySyncState.applyShiftAuthority(try row.authorityState(), for: id)
        #expect(outcome == .demote)
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id),
                "a withdrawal on a real row must take effect, sheet or no sheet")
    }

    // MARK: - A present-but-unparseable timestamp must not read as absent

    /// **The field-level version of the absent-row hazard.**
    ///
    /// A non-null timestamp that will not parse used to collapse to nil, and
    /// `isAuthoritative` opens with `guard migratedAt != nil` -- so it read as
    /// "never converted" and DEMOTED a promoted account. The row exists, so
    /// the leg\'s absent-row guard does not catch it.
    ///
    /// Severe rather than cosmetic: demoting a promoted account hides every
    /// shift logged since promotion, because those exist only as
    /// `ShiftRecord`s. And a server format change would fail to parse on
    /// EVERY pass, making the demotion persistent rather than transient.
    @Test("a present-but-unparseable timestamp throws instead of reading as absent")
    func unparseableTimestampThrows() throws {
        let row = try decode(#"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":"not-a-timestamp","rollback_at":null,"conservation_failed_at":null,"remaining_group_count":0}"#)
        #expect(throws: RemoteShiftMigrationState.UnparseableTimestamp.self) {
            _ = try row.authorityState()
        }
    }

    /// And a genuine SQL NULL still means absent, so the throw above is
    /// narrow. Without this the fix could have been "throw on any nil".
    @Test("a genuine null timestamp still means absent, not an error")
    func genuineNullIsAbsentNotAnError() throws {
        let row = try decode(#"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":null,"rollback_at":null,"conservation_failed_at":null,"remaining_group_count":0}"#)
        let state = try row.authorityState()
        #expect(state.migratedAt == nil)
        #expect(!ShiftReadAuthority.isAuthoritative(state))
    }

    /// End to end: the unparseable row reaches the leg and changes nothing,
    /// because the throw lands in the existing catch.
    @Test("the leg leaves an authoritative account alone when a timestamp will not parse")
    func legUnparseableTimestampDoesNotDemote() async throws {
        let id = account(authoritative: true)
        let row = try decode(#"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":"not-a-timestamp","rollback_at":null,"conservation_failed_at":null,"remaining_group_count":0}"#)

        let deferred = await leg(userID: id, row: row)
        #expect(!deferred)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id),
                "an unreadable field is a failure to read, never a withdrawal")
    }

    // MARK: - The leg itself, driven

    /// A supplied conversion row, so the REAL leg runs with no session.
    private func leg(
        userID: UUID,
        row: RemoteShiftMigrationState?
    ) async -> Bool {
        await PaydaySyncService.applyShiftAuthorityLeg(userID: userID) { row }
    }

    /// A leg whose fetch THROWS, which is a different failure from a row
    /// that is absent and must behave the same way.
    private func throwingLeg(userID: UUID) async -> Bool {
        struct ReadFailed: Error {}
        return await PaydaySyncService.applyShiftAuthorityLeg(userID: userID) {
            throw ReadFailed()
        }
    }

    /// **The round trip, through the leg rather than through a grep.**
    ///
    /// Defer while a legacy-edit sheet is open, close it, and the NEXT pass
    /// promotes. Asserting that `.deferPromotion` came back would pass over a
    /// caller that drops it; this drives the code that maps it.
    @Test("the leg defers while a sheet is open and promotes on the next pass")
    func legDefersThenPromotes() async throws {
        let id = account(authoritative: false)
        let ready = try decode(Self.readyJSON)

        LegacyEditSheetPresence.begin()
        let deferred = await leg(userID: id, row: ready)
        #expect(deferred, "the leg must report the deferral so a follow-up is requested")
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id))

        LegacyEditSheetPresence.end()
        let second = await leg(userID: id, row: ready)
        #expect(!second, "a completed promotion needs no follow-up")
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id),
                "a deferral must be a delay, not a cancellation")
    }

    /// **An ABSENT row must not demote a converted account.** The P0.
    @Test("the leg leaves an authoritative account alone when no row comes back")
    func legAbsentRowDoesNotDemote() async {
        let id = account(authoritative: true)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id))

        let deferred = await leg(userID: id, row: nil)
        #expect(!deferred)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id),
                "an absent row is a failure to ask, never a withdrawal")
    }

    /// And a THROWN read, the other way the same question goes unanswered.
    @Test("the leg leaves an authoritative account alone when the read throws")
    func legThrownReadDoesNotDemote() async {
        let id = account(authoritative: true)
        let deferred = await throwingLeg(userID: id)
        #expect(!deferred)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id),
                "a thrown read must not flip the representation either")
    }

    /// The disagreeing case: a REAL withdrawal, on a real row, still demotes
    /// through the leg — so the skip above is narrow rather than a blanket
    /// refusal to ever demote.
    @Test("the leg demotes on a real withdrawal row")
    func legDemotesOnRealWithdrawal() async throws {
        let id = account(authoritative: true)
        let rolledBack = try decode(Self.rolledBackJSON)

        let deferred = await leg(userID: id, row: rolledBack)
        #expect(!deferred)
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id),
                "a withdrawal signalled by a column must take effect")
    }

    /// A withdrawal demotes even with a sheet open, through the leg. The
    /// asymmetry, end to end.
    @Test("the leg demotes on a withdrawal even while a legacy-edit sheet is open")
    func legDemotesThroughAnOpenSheet() async throws {
        let id = account(authoritative: true)
        let rolledBack = try decode(Self.rolledBackJSON)

        LegacyEditSheetPresence.begin()
        let deferred = await leg(userID: id, row: rolledBack)
        LegacyEditSheetPresence.end()

        #expect(!deferred)
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id))
    }
}
