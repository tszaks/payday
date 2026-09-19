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
            "GET /rest/v1/tip_entries",
            "GET /rest/v1/paycheck_records",
            "GET /rest/v1/user_settings",
        ], "got \(calls)")
    }

    /// **The shift leg is absent, measured end to end rather than grepped.**
    ///
    /// This assertion is written to FAIL when design 7.5 lands, and that is
    /// its job. Whoever wires the leg has to come here and state the new
    /// order deliberately -- which is the only moment anyone will check that
    /// the shift PULL precedes the shift PUSH, the inversion 7.5 requires
    /// and that applies to the shift leg alone.
    ///
    /// A reorder with no test to break is a reorder nobody reviews.
    @Test("no shift call happens yet, and this fails the day the leg is wired")
    func theShiftLegIsNotWiredYet() async throws {
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

        let shiftCalls = RoutingStub.recordedPaths().filter {
            $0.contains("/shifts") || $0.contains("_shifts") || $0.contains("shift_")
        }
        #expect(shiftCalls.isEmpty, """
            The shift leg is now reaching the network: \(shiftCalls).
            Update the expected order in this suite, and while you are here
            confirm the shift PULL precedes the shift PUSH per design 7.5.
            """)
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
