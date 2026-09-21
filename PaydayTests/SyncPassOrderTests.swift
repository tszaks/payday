import Foundation
import SwiftData
import Supabase
import Testing
@testable import Payday

/// **The first end-to-end test of `synchronize`.**
///
/// There was none. `grep -rln "\.synchronize(" PaydayTests/` returned
/// nothing, so the most dangerous function in the app -- the one PR 2's
/// design reorders, warning that a mistake leaves a divergence "permanent
/// and unpushable" -- had no coverage of its call sequence at all.
///
/// It could not have one until now: the first line was
/// `client.auth.session`, and a client built with a static `accessToken`
/// provider throws `sessionMissing`. Measured with a probe. The `userID`
/// seam removes that, and this is what the seam is for.
// `.serialized` is load-bearing, not decoration. Both tests share one
// static recorder, and `await synchronize(...)` suspends the main actor --
// so without it the second test's `reset()` can land in the middle of the
// first test's HTTP calls and silently truncate the recorded order.
@Suite("Sync pass order", .serialized)
@MainActor
struct SyncPassOrderTests {

    private static let user = UUID(uuidString: "90000000-0000-4000-8000-000000000001")!
    private static let shift = UUID(uuidString: "90000000-0000-4000-8000-0000000000a1")!

    private func client() -> SupabaseClient {
        RoutingStub.reset()
        // The deletion queues live in App Group UserDefaults keyed by user id,
        // so they survive BOTH the test and the whole test run. Without this
        // a queued deletion from one test changes another test's call order,
        // and a leftover from a previous run changes it before any test runs.
        PaydaySyncState.clearShiftDeletions(
            PaydaySyncState.pendingShiftDeletions(for: Self.user).keys, for: Self.user)
        PaydaySyncState.clearLegacyEntryDeletions(
            PaydaySyncState.pendingLegacyEntryDeletions(for: Self.user).keys, for: Self.user)
        PaydaySyncState.clearShiftRestores(
            PaydaySyncState.pendingShiftRestores(for: Self.user).keys, for: Self.user)
        // The FLIP is persistent too, and keyed by user id like the queues.
        // `aConvergedAccountSkipsTheOneShot` sets it deliberately, and
        // without this reset every test that runs after it sees a flipped
        // account and a pass that skips the one-shot. Third persistent
        // App Group value in this file to need clearing; they all outlive
        // the test AND the run.
        _ = PaydaySyncState.applyShiftAuthority(
            ShiftReadAuthority.State(
                migratedAt: nil, rollbackAt: nil,
                conservationFailedAt: nil, remainingGroupCount: nil
            ), for: Self.user)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingStub.self]
        return SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseKey: "test-anon-key",
            options: SupabaseClientOptions(
                auth: .init(accessToken: { "test-access-token" }),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
    }

    private func context() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(
            for: TipEntry.self, PaycheckRecord.self, ShiftRecord.self,
            configurations: config))
    }

    /// A pass over an empty account completes, and the ORDER of its calls is
    /// recorded so the shift-leg reordering in design 7.5 has something to
    /// break. Today there is no shift leg, so this locks in what exists --
    /// which is the point of writing it before the reorder rather than
    /// after.
    @Test("a sync pass over an empty account completes and records its call order")
    func emptyPassRecordsItsOrder() async throws {
        let service = PaydaySyncService(client: client())
        let ctx = try context()

        _ = try? await service.synchronize(
            context: ctx,
            scheduleStore: PayScheduleStore(),
            preferencesStore: UserPreferencesStore(),
            moveLedgerStore: MoveLedgerStore(),
            policyStore: PolicyStore(),
            userID: Self.user
        )

        let calls = RoutingStub.recordedPaths()

        // The SHIPPED order, recorded from a real pass rather than read off
        // the source: settings push, then the baseline pull.
        #expect(calls == [
            "POST /rest/v1/rpc/upsert_user_settings",
            "POST /rest/v1/rpc/payday_unmigrated_tip_row_count",
            // Reached even with a count of 0, because an account with
            // nothing to convert still needs the one-shot to COMPLETE
            // before it can be authoritative.
            "POST /rest/v1/rpc/migrate_tip_entries_to_shifts",
            "POST /rest/v1/rpc/fetch_shift_changes",
            "GET /rest/v1/tip_entries",
            "GET /rest/v1/paycheck_records",
            "GET /rest/v1/user_settings",
            // Reachable only since the stub started returning a VALID
            // settings row. With "{}" the pass threw `keyNotFound: user_id`
            // here and these two legs were never exercised by any test.
            "GET /rest/v1/shift_migration_state",
            "GET /rest/v1/dataset_revisions",
        ], "got \(calls)")

        // No shift PUSH on an empty account, which is correct and is also why
        // this test cannot prove the 7.5 inversion on its own -- there is no
        // push to order the pull against. That is the next test's job.
        #expect(!calls.contains("POST /rest/v1/rpc/upsert_shifts"))
    }

    /// The test design 7.5 names: `firstShiftsSyncPullsBeforePushingAndReadsBackAfter`.
    ///
    /// Supersedes the placeholder that asserted NO shift call happened. That
    /// one was written before the leg existed, to fail the day it was wired.
    /// It did exactly that, and this replaces it rather than relaxing it.
    ///
    /// The inversion only means something when there is a shift to push, so
    /// this pass starts with one unacknowledged local shift.
    @Test("the shift leg pulls before it pushes, then reads back what it wrote")
    func firstShiftsSyncPullsBeforePushingAndReadsBackAfter() async throws {
        let service = PaydaySyncService(client: client())
        let ctx = try context()
        ctx.insert(ShiftRecord(
            id: Self.shift,
            workDate: Date(timeIntervalSince1970: 1_758_000_000),
            cashTipsCents: 1_000,
            hoursWorked: 5
        ))
        try ctx.save()

        _ = try? await service.synchronize(
            context: ctx,
            scheduleStore: PayScheduleStore(),
            preferencesStore: UserPreferencesStore(),
            moveLedgerStore: MoveLedgerStore(),
            policyStore: PolicyStore(),
            userID: Self.user
        )

        let calls = RoutingStub.recordedPaths()
        let pull = calls.firstIndex(of: "POST /rest/v1/rpc/fetch_shift_changes")
        let push = calls.firstIndex(of: "POST /rest/v1/rpc/upsert_shifts")
        let readback = calls.lastIndex(of: "GET /rest/v1/shifts")

        #expect(pull != nil, "no shift pull in \(calls)")
        #expect(push != nil, "no shift push in \(calls)")
        #expect(readback != nil, "no step-9 readback in \(calls)")
        if let pull, let push, let readback {
            // The whole point of 7.5, asserted as an ordering rather than a
            // literal array so an unrelated call cannot silently invalidate it.
            #expect(pull < push, "shift pull must precede the push; got \(calls)")
            #expect(push < readback, "readback must follow the push; got \(calls)")
        }

        // The inversion is for the SHIFT leg only. Settings must still be
        // pushed before anything is pulled, or `apply(_:force:)` reverts a
        // locally changed wage.
        if let settings = calls.firstIndex(of: "POST /rest/v1/rpc/upsert_user_settings"),
           let pull {
            #expect(settings < pull, "settings push must stay ahead of the pull; got \(calls)")
        }
    }
    /// The deletion flush the gate doc predicted would be forgotten -- and
    /// that the first draft of this leg did forget.
    ///
    /// `shifts` is DERIVED from `tip_entries`. Delete a migrated shift,
    /// leave its source rows alive, and the server's fold re-derives it: the
    /// deleted shift comes back. The producer has been queueing these since
    /// PR 2 with no reader, which is why the queue fails silently rather
    /// than loudly.
    @Test("a queued legacy-entry deletion is actually flushed to the server")
    func aQueuedLegacyEntryDeletionReachesTheServer() async throws {
        let legacy = UUID(uuidString: "90000000-0000-4000-8000-0000000000b1")!
        let service = PaydaySyncService(client: client())
        PaydaySyncState.recordLegacyEntryDeletions([legacy], for: Self.user)
        let ctx = try context()
        _ = try? await service.synchronize(
            context: ctx,
            scheduleStore: PayScheduleStore(),
            preferencesStore: UserPreferencesStore(),
            moveLedgerStore: MoveLedgerStore(),
            policyStore: PolicyStore(),
            userID: Self.user
        )

        let calls = RoutingStub.recordedPaths()
        #expect(
            calls.contains("POST /rest/v1/rpc/soft_delete_tip_entries"),
            "the legacy deletion queue was never flushed; got \(calls)"
        )
        // Cleared only on success, so a flushed queue must be empty after.
        #expect(PaydaySyncState.pendingLegacyEntryDeletions(for: Self.user).isEmpty)
    }

    /// The OTHER half of `FLIP-BLOCKER-DELETION-FLUSH`, and the half that
    /// names the condition.
    ///
    /// `aQueuedLegacyEntryDeletionReachesTheServer` proves the legacy source
    /// rows get tombstoned. This proves the shift row itself does. Both are
    /// required before PR 8 may delete the legacy calculation paths, because
    /// deleting them IS the flip whatever the flag says, and a deletion that
    /// never reaches the server means the first thing the new representation
    /// does is resurrect a shift the user deleted.
    @Test("a queued shift deletion is actually flushed to the server")
    func aQueuedShiftDeletionReachesTheServer() async throws {
        let doomed = UUID(uuidString: "90000000-0000-4000-8000-0000000000c1")!
        let service = PaydaySyncService(client: client())
        PaydaySyncState.recordShiftDeletion(doomed, for: Self.user)
        let ctx = try context()
        _ = try? await service.synchronize(
            context: ctx,
            scheduleStore: PayScheduleStore(),
            preferencesStore: UserPreferencesStore(),
            moveLedgerStore: MoveLedgerStore(),
            policyStore: PolicyStore(),
            userID: Self.user
        )

        let calls = RoutingStub.recordedPaths()
        #expect(
            calls.contains("POST /rest/v1/rpc/soft_delete_shifts"),
            "the shift deletion queue was never flushed; got \(calls)"
        )
        // Step 9 must read the deleted id back, because that tombstoned row
        // is what removes it locally on the second reconcileShifts call.
        #expect(
            calls.contains("GET /rest/v1/shifts"),
            "no step-9 readback covering the deleted id; got \(calls)"
        )

        // The queue must DRAIN, not merely be sent. It was cleared only on
        // the undo path, so every later pass re-sent every deletion the
        // account had ever made and the step-9 readback id set grew without
        // bound, because it is keyed on this queue.
        #expect(
            PaydaySyncState.pendingShiftDeletions(for: Self.user).isEmpty,
            "the shift deletion queue never drained"
        )
    }

    /// Step 0's queue must DRAIN, and this is the third queue in this file
    /// with the same defect: written on the user action, flushed by the
    /// sync, cleared only on the UNDO path. `pendingShiftDeletions` and the
    /// tombstone map had it too. A queue that never drains re-sends its
    /// whole history every pass, forever.
    @Test("a queued shift restore is flushed and then drained")
    func aQueuedShiftRestoreIsFlushedAndDrained() async throws {
        let service = PaydaySyncService(client: client())
        let restored = UUID(uuidString: "90000000-0000-4000-8000-0000000000d1")!
        PaydaySyncState.recordShiftRestore(restored, for: Self.user)

        let ctx = try context()
        _ = try? await service.synchronize(
            context: ctx,
            scheduleStore: PayScheduleStore(),
            preferencesStore: UserPreferencesStore(),
            moveLedgerStore: MoveLedgerStore(),
            policyStore: PolicyStore(),
            userID: Self.user
        )

        let calls = RoutingStub.recordedPaths()
        #expect(
            calls.contains("POST /rest/v1/rpc/restore_shifts"),
            "the restore queue was never flushed; got \(calls)"
        )
        #expect(
            calls.first == "POST /rest/v1/rpc/restore_shifts",
            "step 0 must run before every other write; got \(calls)"
        )
        #expect(
            PaydaySyncState.pendingShiftRestores(for: Self.user).isEmpty,
            "the restore queue never drained"
        )
    }

    /// Step 6a converts REAL accounts, so when it runs is not a detail.
    ///
    /// Design 7.5 puts it after the orchestration and before the shift
    /// pull: ahead of the leg it would flip reads to a representation the
    /// device cannot sync, and after the pull it would convert rows this
    /// pass then fails to see. And it is ONE call, never a loop, because a
    /// loop inside a pass is how an account that cannot converge hangs a
    /// sync instead of making partial progress.
    @Test("the one-shot fires only when there is work, and exactly once")
    func theOneShotFiresOnlyWhenThereIsWorkToDo() async throws {
        let service = PaydaySyncService(client: client())
        RoutingStub.route("/rpc/payday_unmigrated_tip_row_count", to: "7")
        let ctx = try context()

        _ = try? await service.synchronize(
            context: ctx,
            scheduleStore: PayScheduleStore(),
            preferencesStore: UserPreferencesStore(),
            moveLedgerStore: MoveLedgerStore(),
            policyStore: PolicyStore(),
            userID: Self.user
        )

        let calls = RoutingStub.recordedPaths()
        let convert = calls.filter { $0.contains("migrate_tip_entries_to_shifts") }
        #expect(convert.count == 1, "expected exactly one conversion call; got \(calls)")

        let iConvert = calls.firstIndex { $0.contains("migrate_tip_entries_to_shifts") }
        let iPull = calls.firstIndex { $0.contains("fetch_shift_changes") }
        let iSettings = calls.firstIndex { $0.contains("upsert_user_settings") }
        if let iConvert, let iPull { #expect(iConvert < iPull, "6a must precede the shift pull; got \(calls)") }
        if let iConvert, let iSettings { #expect(iSettings < iConvert, "6a must follow the orchestration; got \(calls)") }
    }

    /// The self-limit, and it is the whole reason 6a is not simply
    /// unconditional.
    ///
    /// REWRITTEN: this used to assert that a zero COUNT skips the one-shot.
    /// That assumption is exactly the defect -- a new account has a zero
    /// count forever, so it never ran the one-shot, never got
    /// `migrated_at`, and never left the legacy arm. The skip is now keyed
    /// on being AUTHORITATIVE, so a settled account pays nothing while an
    /// unflipped one keeps trying.
    @Test("an authoritative account never calls the one-shot again")
    func aConvergedAccountSkipsTheOneShot() async throws {
        let service = PaydaySyncService(client: client())   // count route defaults to 0
        // Flip it first, through the real predicate's writer rather than by
        // poking the checkpoint, so this tests the shipped path.
        _ = PaydaySyncState.applyShiftAuthority(
            ShiftReadAuthority.State(
                migratedAt: Date(timeIntervalSince1970: 1_758_000_000),
                rollbackAt: nil, conservationFailedAt: nil, remainingGroupCount: 0
            ), for: Self.user)
        #expect(PaydaySyncState.shiftsAreAuthoritative(for: Self.user),
                "precondition: the account must be flipped for this test to mean anything")
        let ctx = try context()
        _ = try? await service.synchronize(
            context: ctx,
            scheduleStore: PayScheduleStore(),
            preferencesStore: UserPreferencesStore(),
            moveLedgerStore: MoveLedgerStore(),
            policyStore: PolicyStore(),
            userID: Self.user
        )
        #expect(!RoutingStub.recordedPaths().contains { $0.contains("migrate_tip_entries_to_shifts") })
    }

    /// The shift cursor must be CLAMPED, and this is the only test that can
    /// tell: the pass succeeds either way, so a plain `ServerCursor.advanced`
    /// is invisible to every other assertion here.
    ///
    /// Why it matters is measured in `db-test-race.sh` case 10. The server
    /// fold stamps a converted shift EARLIER than the visible maximum, so a
    /// cursor parked on the newest pulled row steps over it and never
    /// returns it -- `anUnclampedCursorPermanentlyMissesTheFoldedShift`
    /// delivers 0 rows. Step 6a is what makes folded shifts exist.
    ///
    /// The stub reports `server_now = 2026-09-19T00:00:00Z` and no rows, so
    /// the fence is 300s earlier and the id half becomes the all-zero UUID
    /// -- carrying a real id beside a clamped-down timestamp would skip any
    /// row sitting exactly at the fence with a lower id.
    @Test("the shift cursor is clamped to the safety window, not the newest row")
    func theShiftCursorIsClampedToTheFence() async throws {
        let service = PaydaySyncService(client: client())
        let ctx = try context()
        _ = try? await service.synchronize(
            context: ctx,
            scheduleStore: PayScheduleStore(),
            preferencesStore: UserPreferencesStore(),
            moveLedgerStore: MoveLedgerStore(),
            policyStore: PolicyStore(),
            userID: Self.user
        )

        let cursor = PaydaySyncState.snapshot(for: Self.user).shiftServerCursor
        #expect(cursor != nil, "the pass wrote no shift cursor at all")
        #expect(
            cursor?.updatedAt == "2026-09-18T23:55:00.000Z",
            "expected the fence (server_now - 300s); got \(cursor?.updatedAt ?? "nil")"
        )
        #expect(
            cursor?.id == UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
            "a clamped cursor must carry the all-zero id; got \(cursor?.id.uuidString ?? "nil")"
        )
    }

    /// The pass resolves its account once, at the top, and previously never
    /// asked again -- so a response fetched for account A could be applied
    /// after the session moved to account B (reachable via `deleteAccount`,
    /// which frees the registration). The re-check sits before the first
    /// pulled-row write: a moved session aborts the pass and applies
    /// nothing, rather than writing one account's data into another's
    /// store.
    ///
    /// The seam is `liveSessionUserID`: production reads the real session;
    /// a test answers with a different id to stand in for "the account
    /// changed mid-flight". `injectedUserID` alone cannot test this -- it
    /// pins the account precisely because a stub client has no session.
    @Test("a session that changed mid-pass aborts before applying pulled rows")
    func aMovedSessionAbortsThePass() async throws {
        let service = PaydaySyncService(client: client())
        let ctx = try context()
        let other = UUID(uuidString: "90000000-0000-4000-8000-0000000000ff")!

        do {
            _ = try await service.synchronize(
                context: ctx,
                scheduleStore: PayScheduleStore(),
                preferencesStore: UserPreferencesStore(),
                moveLedgerStore: MoveLedgerStore(),
                policyStore: PolicyStore(),
                userID: Self.user,
                liveSessionUserID: { other }
            )
            Issue.record("the pass applied account A's rows under account B's session")
        } catch {
            #expect(error as? PaydayMigrationError == .accountMismatch,
                    "expected accountMismatch, got \(error)")
        }

        #expect(try ctx.fetch(FetchDescriptor<TipEntry>()).isEmpty,
                "a moved session still wrote pulled tip rows")
        #expect(try ctx.fetch(FetchDescriptor<PaycheckRecord>()).isEmpty,
                "a moved session still wrote pulled paycheck rows")
        #expect(try ctx.fetch(FetchDescriptor<ShiftRecord>()).isEmpty,
                "a moved session still wrote pulled shift rows")
    }

    /// The same re-check must not fire when the session DIDN'T move -- an
    /// abort on every pass would be worse than the gap it closes.
    @Test("an unmoved session passes the re-check and completes")
    func anUnmovedSessionCompletes() async throws {
        let service = PaydaySyncService(client: client())
        let ctx = try context()

        do {
            _ = try await service.synchronize(
                context: ctx,
                scheduleStore: PayScheduleStore(),
                preferencesStore: UserPreferencesStore(),
                moveLedgerStore: MoveLedgerStore(),
                policyStore: PolicyStore(),
                userID: Self.user,
                liveSessionUserID: { Self.user }
            )
        } catch {
            Issue.record("an unmoved session aborted the pass: \(error)")
        }
    }

}

/// Routes by URL path and records the order, because one canned body for
/// every request cannot drive a pass that makes nine different calls.
final class RoutingStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var routes: [(String, String)] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); paths = []
        routes = [
            // A VALID settings row, not "{}". With "{}" the pass threw
            // `keyNotFound: user_id` at the settings decode -- so every test
            // here silently stopped before the deletion clears, the
            // reconcile and the checkpoint write. The harness looked like it
            // covered a whole pass and covered two thirds of one.
            ("/rest/v1/user_settings", """
                {"user_id":"90000000-0000-4000-8000-000000000001",
                 "smart_nudge_enabled":true,"payday_reminder_enabled":true,
                 "move_ledger":{},"client_updated_at":"2026-09-19T00:00:00.000Z",
                 "updated_at":"2026-09-19T00:00:00.000Z"}
                """),
            ("/rest/v1/tip_entries", "[]"),
            ("/rest/v1/paycheck_records", "[]"),
            ("/rest/v1/shifts", "[]"),
            // Must precede the generic /rpc/ entry: routes match in order,
            // and `fetch_shift_changes` decodes a RemoteShiftPage OBJECT, so
            // the generic "[]" makes the pass throw mid-leg.
            // Returns a NUMBER, not "[]" -- the generic /rpc/ body does not
            // decode as Int and the pass throws before the shift leg.
            // Default 0, so the one-shot does not fire in the passes that
            // are about ordering; `theOneShotFiresOnlyWhenThereIsWorkToDo`
            // overrides it.
            ("/rpc/payday_unmigrated_tip_row_count", "0"),
            // The one-shot returns a `shift_migration_state` ROW, not a
            // list. With the generic "[]" the pass throws here and every
            // later assertion in this file silently stops being exercised
            // -- the same shape as `fetch_shift_changes` above.
            //
            // Stamped and finished, which is what an empty account now gets:
            // the function ran, converted nothing, and completed.
            ("/rpc/migrate_tip_entries_to_shifts", """
                {"user_id":"90000000-0000-4000-8000-000000000001",
                 "migrated_at":"2026-09-19T00:00:00.000Z","rollback_at":null,
                 "conservation_failed_at":null,"remaining_group_count":0}
                """),
            ("/rpc/fetch_shift_changes", "{\"server_now\":\"2026-09-19T00:00:00.000Z\",\"rows\":[]}"),
            ("/rest/v1/rpc/", "[]"),
        ]
        lock.unlock()
    }

    /// Override one route for a single test. The map is rebuilt by
    /// `reset()`, so this cannot leak into the next test.
    static func route(_ fragment: String, to body: String) {
        lock.lock(); defer { lock.unlock() }
        routes.insert((fragment, body), at: 0)
    }

    static func recordedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? "?"
        let method = request.httpMethod ?? "?"
        Self.lock.lock()
        Self.paths.append("\(method) \(path)")
        var body = Self.routes.first { path.contains($0.0) }?.1 ?? "[]"
        Self.lock.unlock()

        // `/user_settings` is read TWO ways in one codebase: the baseline
        // path decodes a single object, the delta path decodes an array of
        // one. Same URL, so the only honest discriminator is the header
        // PostgREST itself uses for `.single()`. Getting this wrong threw
        // `typeMismatch` mid-pass and silently truncated every test here.
        if path.contains("user_settings"), !path.contains("/rpc/"),
           request.value(forHTTPHeaderField: "Accept")?.contains("pgrst.object") != true {
            body = "[\(body)]"
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
