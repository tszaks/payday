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
/// ## The deferral is gone with the sheet it protected
///
/// `ShiftReadAuthority.resolve` used to return `.deferPromotion` while a
/// legacy-edit sheet was open. There is no `.edit(TipEntry)` target any more,
/// so the straddle it guarded is unrepresentable and the outcome is gone with
/// it: promotion is now unconditional once the server says the conversion is
/// complete.
///
/// The decode half is tested here rather than the network half: the fetch is
/// three chained Supabase builder calls with no branching, while the mapping
/// from stored columns to the predicate's inputs is where a wrong answer
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
        #expect(!ShiftReadAuthority.isAuthoritative(ShiftReadAuthority.State.probe()))
    }

    // MARK: - Promotion and steady state

    /// A ready row on a non-authoritative account promotes on the pass.
    @Test("a completed conversion promotes on the pass it is read")
    func readyRowPromotes() {
        let id = account(authoritative: false)
        let ready = ShiftReadAuthority.State.probe(
            migratedAt: Date(timeIntervalSince1970: 1_750_000_000),
            remainingGroupCount: 0
        )
        let outcome = PaydaySyncState.applyShiftAuthority(ready, for: id)
        #expect(outcome == .promote)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id))
    }

    /// A steady state resolves unchanged: an already authoritative account
    /// whose server state is unchanged stays authoritative, so repeated syncs
    /// do not chase each other.
    @Test("a steady authoritative account resolves unchanged")
    func steadyStateIsUnchanged() {
        let id = account(authoritative: true)
        let ready = ShiftReadAuthority.State.probe(
            migratedAt: Date(timeIntervalSince1970: 1_750_000_000),
            remainingGroupCount: 0
        )
        let outcome = PaydaySyncState.applyShiftAuthority(ready, for: id)
        #expect(outcome == .unchanged)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id))
    }

    // MARK: - A failed read must not demote

    /// **The defect this leg shipped with in its first draft**, and the one
    /// place the demotion asymmetry cuts the wrong way.
    ///
    /// `resolve` returns `.demote` on the `currentlyAuthoritative` branch
    /// whenever `isAuthoritative` is false, and `isAuthoritative` opens with
    /// `guard migratedAt != nil`. So an EMPTY `State` demotes a converted
    /// account. The first draft substituted `ShiftReadAuthority.State.probe()` for a
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
            ShiftReadAuthority.State.probe(),
            currentlyAuthoritative: true
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
                "a withdrawal on a real row must take effect")
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

        let result = await PaydaySyncService.applyShiftAuthorityLeg(userID: id) { row }
        #expect(result.remainingGroupCount == nil)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id),
                "an unreadable field is a failure to read, never a withdrawal")
    }

    // MARK: - The count the leg used to throw away

    /// **The test that would have caught the unreachable banner.**
    ///
    /// The leg returned `Bool` -- the deferral alone -- and discarded
    /// `remaining_group_count` one line after reading it. Nothing else in the
    /// app read that column, so `PaydayMigrationReport.conversionPending` had
    /// no producer, `isConversionPending` was false for every account, and
    /// `PaydayCloudState.conversionBanner` always returned nil. The banner was
    /// built, its copy was tested, and it could not appear.
    ///
    /// `ConversionBannerTests` was green throughout, because it builds the
    /// report through the initializer with the count already in it. A test
    /// that SUPPLIES the value it checks cannot discover that nothing
    /// produces it. This one runs the real leg and reads what comes out.
    @Test("the leg carries the server's remaining count out")
    func legReportsRemainingCount() async throws {
        let id = UUID()
        let row = try decode(#"{"user_id":"00000000-0000-0000-0000-0000000000a1","migrated_at":"2026-09-18T00:00:00Z","rollback_at":null,"conservation_failed_at":null,"remaining_group_count":7}"#)

        let result = await PaydaySyncService.applyShiftAuthorityLeg(userID: id) { row }

        #expect(result.remainingGroupCount == 7)
        // And the account is NOT authoritative while groups remain, which is
        // what makes the banner's "your totals are unchanged" sentence true.
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id))
    }

    /// nil and 0 are different answers. A pass that learned nothing must not
    /// report "finished" -- that would hide a banner that should be up.
    @Test("a missing row and a failed read both report an unknown count, never zero")
    func unknownCountIsNilNotZero() async {
        let absent = await PaydaySyncService.applyShiftAuthorityLeg(userID: UUID()) { nil }
        #expect(absent.remainingGroupCount == nil)

        struct ReadFailed: Error {}
        let failed = await PaydaySyncService.applyShiftAuthorityLeg(userID: UUID()) {
            throw ReadFailed()
        }
        #expect(failed.remainingGroupCount == nil)
    }

    // MARK: - The leg itself, driven

    /// **The round trip, through the leg rather than through a grep.**
    ///
    /// A ready row promotes on the pass it is read, and reports the
    /// conversion is finished.
    @Test("the leg promotes on a ready row")
    func legPromotesOnReadyRow() async throws {
        let id = account(authoritative: false)
        let ready = try decode(Self.readyJSON)

        let result = await PaydaySyncService.applyShiftAuthorityLeg(userID: id) { ready }
        #expect(result.remainingGroupCount == 0)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id))
    }

    /// **An ABSENT row must not demote a converted account.** The P0.
    @Test("the leg leaves an authoritative account alone when no row comes back")
    func legAbsentRowDoesNotDemote() async {
        let id = account(authoritative: true)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id))

        let result = await PaydaySyncService.applyShiftAuthorityLeg(userID: id) { nil }
        #expect(result.remainingGroupCount == nil)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: id),
                "an absent row is a failure to ask, never a withdrawal")
    }

    /// And a THROWN read, the other way the same question goes unanswered.
    @Test("the leg leaves an authoritative account alone when the read throws")
    func legThrownReadDoesNotDemote() async {
        let id = account(authoritative: true)
        struct ReadFailed: Error {}
        let result = await PaydaySyncService.applyShiftAuthorityLeg(userID: id) {
            throw ReadFailed()
        }
        #expect(result.remainingGroupCount == nil)
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

        let result = await PaydaySyncService.applyShiftAuthorityLeg(userID: id) { rolledBack }
        #expect(result.remainingGroupCount == 0)
        #expect(!PaydaySyncState.shiftsAreAuthoritative(for: id),
                "a withdrawal signalled by a column must take effect")
    }

    /// **A guarantee that dropped from two to one, so it gets a name.**
    ///
    /// A partially converted account used to be held back from the records
    /// engine TWICE: `migrated_at` was null (the one-shot only stamped when
    /// it wrote rows) AND `remaining_group_count` was positive. Stamping on
    /// COMPLETION removes the first, so the whole guarantee now rests on the
    /// remainder alone.
    ///
    /// If this ever passes with `remaining > 0`, an account mid-conversion
    /// reads from `shifts` that do not all exist yet and its owner sees part
    /// of their own money.
    @Test("a partially converted account is not authoritative, on the remainder alone")
    func aPartiallyConvertedAccountIsNotAuthoritative() {
        let midConversion = ShiftReadAuthority.State(
            migratedAt: Date(timeIntervalSince1970: 1_758_000_000),  // stamped: it RAN
            rollbackAt: nil,
            conservationFailedAt: nil,
            remainingGroupCount: 3                                    // but did not finish
        )
        #expect(ShiftReadAuthority.isAuthoritative(midConversion) == false)

        // The same state with the work finished IS authoritative, so the
        // test above is failing on the remainder and not on something else.
        let finished = ShiftReadAuthority.State(
            migratedAt: Date(timeIntervalSince1970: 1_758_000_000),
            rollbackAt: nil,
            conservationFailedAt: nil,
            remainingGroupCount: 0
        )
        #expect(ShiftReadAuthority.isAuthoritative(finished))
    }

    /// The new-account case, which is the whole reason the stamp moved.
    /// Nothing to convert, the one-shot ran anyway, so it completed.
    @Test("an account with nothing to convert is authoritative once the one-shot has run")
    func anEmptyAccountIsAuthoritativeAfterTheOneShotRuns() {
        let neverRan = ShiftReadAuthority.State(
            migratedAt: nil, rollbackAt: nil,
            conservationFailedAt: nil, remainingGroupCount: 0
        )
        #expect(ShiftReadAuthority.isAuthoritative(neverRan) == false,
                "no stamp means the one-shot has not completed here")

        let ranWithNoWork = ShiftReadAuthority.State(
            migratedAt: Date(timeIntervalSince1970: 1_758_000_000),
            rollbackAt: nil, conservationFailedAt: nil, remainingGroupCount: 0
        )
        #expect(ShiftReadAuthority.isAuthoritative(ranWithNoWork))
    }

}
