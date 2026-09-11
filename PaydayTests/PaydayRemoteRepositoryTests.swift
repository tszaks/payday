import Foundation
import Supabase
import Testing
@testable import Payday

@Suite("Payday remote repository efficiency", .serialized)
struct PaydayRemoteRepositoryTests {
    @Test("steady-state poll asks only for rows after durable cursors")
    func steadyStateUsesDeltaQueries() async throws {
        RecordingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let options = SupabaseClientOptions(
            auth: .init(accessToken: { "test-access-token" }),
            global: .init(session: session)
        )
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseKey: "test-anon-key",
            options: options
        )
        let repository = PaydayRemoteRepository(client: client)
        let cursor = PaydaySyncState.ServerCursor(
            updatedAt: "2026-09-04T12:34:56.123Z",
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )

        let changes = try await repository.fetchChanges(
            userID: UUID(),
            tipCursor: cursor,
            paycheckCursor: cursor,
            settingsUpdatedAt: cursor.updatedAt,
            forceSettingsRead: false
        )

        #expect(changes.tips.isEmpty)
        #expect(changes.paychecks.isEmpty)
        #expect(changes.settings?.userID == nil)

        let requests = RecordingURLProtocol.recordedRequests()
        #expect(requests.count == 3)
        let tipRequest = try #require(requests.first { $0.url?.path.hasSuffix("/tip_entries") == true })
        let paycheckRequest = try #require(requests.first { $0.url?.path.hasSuffix("/paycheck_records") == true })
        let settingsRequest = try #require(requests.first { $0.url?.path.hasSuffix("/user_settings") == true })

        for request in [tipRequest, paycheckRequest] {
            let items = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            let delta = try #require(items.first { $0.name == "or" }?.value)
            #expect(delta.contains("updated_at.gt.2026-09-04T12:34:56.123Z"))
            #expect(delta.contains("id.gt.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
            #expect(items.contains { $0.name == "order" && $0.value?.contains("updated_at.asc") == true })
            #expect(items.contains { $0.name == "limit" && $0.value == "1000" })
            #expect(!items.contains { $0.name == "offset" })
        }

        let settingsItems = URLComponents(
            url: try #require(settingsRequest.url),
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        #expect(settingsItems.contains {
            $0.name == "updated_at" && $0.value == "gt.2026-09-04T12:34:56.123Z"
        })
        #expect(settingsItems.contains { $0.name == "limit" && $0.value == "1" })
    }
}

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        requests = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
