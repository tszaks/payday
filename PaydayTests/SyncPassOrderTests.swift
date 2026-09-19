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
            "POST /rest/v1/rpc/fetch_shift_changes",
            "GET /rest/v1/tip_entries",
            "GET /rest/v1/paycheck_records",
            "GET /rest/v1/user_settings",
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
        PaydaySyncState.recordLegacyEntryDeletions([legacy], for: Self.user)

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
        #expect(
            calls.contains("POST /rest/v1/rpc/soft_delete_tip_entries"),
            "the legacy deletion queue was never flushed; got \(calls)"
        )
        // Cleared only on success, so a flushed queue must be empty after.
        #expect(PaydaySyncState.pendingLegacyEntryDeletions(for: Self.user).isEmpty)
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
            ("/rest/v1/user_settings", "{}"),
            ("/rest/v1/tip_entries", "[]"),
            ("/rest/v1/paycheck_records", "[]"),
            ("/rest/v1/shifts", "[]"),
            // Must precede the generic /rpc/ entry: routes match in order,
            // and `fetch_shift_changes` decodes a RemoteShiftPage OBJECT, so
            // the generic "[]" makes the pass throw mid-leg.
            ("/rpc/fetch_shift_changes", "{\"server_now\":\"2026-09-19T00:00:00.000Z\",\"rows\":[]}"),
            ("/rest/v1/rpc/", "[]"),
        ]
        lock.unlock()
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
        let body = Self.routes.first { path.contains($0.0) }?.1 ?? "[]"
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
