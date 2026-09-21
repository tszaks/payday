import Foundation
import Supabase
import Testing
@testable import Payday

/// PR 7: the wire-level fault sweep.
///
/// `ShiftWriteWireTests` pins what the repository sends and decodes when the
/// server answers WELL. This suite pins that it refuses when the server
/// answers badly — the failure the whole fence-and-cursor design exists to
/// prevent is a faulted response masquerading as success, because that is how
/// a caller marks unsynced rows synced, applies a partial page as if it were
/// complete, or advances a cursor past records it never received.
///
/// The matrix is deliberate about which refusal matters per path:
///
///   - every method: non-2xx and undecodable bodies throw
///   - the fenced feed: a mid-pagination fault throws rather than releasing
///     the rows already collected, and a page without a readable `server_now`
///     is refused because there is no safe fence to advance the cursor to
///   - the authority legs (`shift_migration_state`, `dataset_revisions`):
///     a fault throws rather than reading as an absent row, because absent
///     means "unconverted" or "revision 0" and a fault must not silently
///     borrow that meaning
///   - a raw transport failure throws like any other fault
@Suite("Sync wire fault injection", .serialized)
struct SyncWireFaultTests {

    // MARK: - Fixtures

    private static let shiftID = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
    private static let userID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let fence = "2026-09-20T12:00:00.000Z"

    /// The shape PostgREST actually returns for an error. A faulted answer
    /// must throw whether or not it carries this shape, so most tests use it
    /// and the malformed-body tests cover the alternative.
    private static let postgrestError = """
    {"message":"injected fault","code":"XX000","details":"","hint":""}
    """

    private static func shift() -> RemoteShift {
        RemoteShift(
            id: shiftID,
            userID: userID,
            workDate: "2026-09-01",
            shiftPeriod: "dinner",
            cashTipsCents: 1_000,
            creditTipsCents: 2_000,
            tipOutCents: 150,
            salesCents: nil,
            hoursWorked: nil,
            clockIn: nil,
            clockOut: nil,
            serverCount: nil,
            receiptMetrics: nil,
            note: nil,
            recordedAt: "2026-09-01T23:30:00.000Z",
            clientUpdatedAt: "2026-09-01T23:31:00.000Z",
            source: nil,
            legacyEntryIDs: nil,
            nativeModifiedAt: nil,
            deletedAt: nil,
            deletedReason: nil,
            gratuityFeesCents: nil,
            nonWageEarningsCents: nil,
            version: nil,
            serverUpdatedAt: nil
        )
    }

    /// One feed row, encoded as the RPC returns it. `serverUpdatedAt` is
    /// populated because a row without it ends pagination — the multi-page
    /// test needs a full page that demands a next request.
    private static func rowJSON(id: UUID) -> String {
        """
        {"id":"\(id.uuidString)","user_id":"\(userID.uuidString)",\
        "work_date":"2026-09-01","shift_period":"dinner",\
        "cash_tips_cents":1000,"credit_tips_cents":2000,\
        "client_updated_at":"2026-09-01T23:31:00.000Z",\
        "updated_at":"\(fence)"}
        """
    }

    private static func pageJSON(rowIDs: [UUID]) -> String {
        let rows = rowIDs.map(rowJSON(id:)).joined(separator: ",")
        return """
        {"server_now":"\(fence)","rows":[\(rows)]}
        """
    }

    private func repository(
        replies: [FaultStubURLProtocol.Reply]
    ) -> PaydayRemoteRepository {
        FaultStubURLProtocol.reset(replies: replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaultStubURLProtocol.self]
        let options = SupabaseClientOptions(
            auth: .init(accessToken: { "test-access-token" }),
            global: .init(session: URLSession(configuration: configuration))
        )
        return PaydayRemoteRepository(
            client: SupabaseClient(
                supabaseURL: URL(string: "https://example.supabase.co")!,
                supabaseKey: "test-anon-key",
                options: options
            )
        )
    }

    // MARK: - The write RPCs throw rather than reporting success

    @Test("upsertShifts throws on HTTP 500")
    func upsertThrowsOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        await #expect(throws: (any Error).self) {
            try await repository.upsertShifts([Self.shift()])
        }
    }

    @Test("upsertShifts throws when the outcome body is not decodable")
    func upsertThrowsOnMalformedOutcomes() async {
        let repository = repository(replies: [.http(200, body: "not json")])
        await #expect(throws: (any Error).self) {
            try await repository.upsertShifts([Self.shift()])
        }
    }

    @Test("upsertShifts throws on an empty 200 body")
    func upsertThrowsOnEmptyBody() async {
        let repository = repository(replies: [.http(200, body: "")])
        await #expect(throws: (any Error).self) {
            try await repository.upsertShifts([Self.shift()])
        }
    }

    @Test("softDeleteShifts throws on HTTP 500")
    func softDeleteThrowsOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        await #expect(throws: (any Error).self) {
            try await repository.softDeleteShifts([Self.shiftID: Date(timeIntervalSince1970: 1_700_000_000)])
        }
    }

    @Test("softDeleteShifts throws when the outcome body is not decodable")
    func softDeleteThrowsOnMalformedOutcomes() async {
        let repository = repository(replies: [.http(200, body: "not json")])
        await #expect(throws: (any Error).self) {
            try await repository.softDeleteShifts([Self.shiftID: Date(timeIntervalSince1970: 1_700_000_000)])
        }
    }

    @Test("restoreShifts throws on HTTP 500")
    func restoreThrowsOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        await #expect(throws: (any Error).self) {
            try await repository.restoreShifts([Self.shiftID])
        }
    }

    @Test("restoreShifts throws when the outcome body is not decodable")
    func restoreThrowsOnMalformedOutcomes() async {
        let repository = repository(replies: [.http(200, body: "not json")])
        await #expect(throws: (any Error).self) {
            try await repository.restoreShifts([Self.shiftID])
        }
    }

    // MARK: - The fenced feed refuses bad pages

    @Test("fetchShiftChanges throws on HTTP 500")
    func changesThrowOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShiftChanges(cursor: nil)
        }
    }

    @Test("fetchShiftChanges throws when the page is not decodable")
    func changesThrowOnMalformedBody() async {
        let repository = repository(replies: [.http(200, body: "not json")])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShiftChanges(cursor: nil)
        }
    }

    @Test("fetchShiftChanges throws on an empty 200 body")
    func changesThrowOnEmptyBody() async {
        let repository = repository(replies: [.http(200, body: "")])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShiftChanges(cursor: nil)
        }
    }

    @Test("fetchShiftChanges throws when the page is an array, not a page object")
    func changesThrowOnWrongShape() async {
        let repository = repository(replies: [.http(200, body: "[]")])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShiftChanges(cursor: nil)
        }
    }

    @Test("a page with no server_now is refused")
    func changesThrowOnMissingFence() async {
        let repository = repository(replies: [.http(200, body: #"{"rows":[]}"#)])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShiftChanges(cursor: nil)
        }
    }

    @Test("a transport failure throws like any other fault")
    func changesThrowOnTransportError() async {
        let repository = repository(replies: [.transport(.networkConnectionLost)])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShiftChanges(cursor: nil)
        }
    }

    /// The scenario the fence exists for: a good first page demands a second
    /// request, and the second request fails. The rows already collected must
    /// NOT escape — if they did, the caller would apply a partial page and
    /// advance the cursor past the records it never saw, which is precisely
    /// "lost records under fault injection."
    @Test("a fault mid-pagination throws instead of releasing a partial collection")
    func changesThrowMidPagination() async throws {
        let fullPage = (0 ..< PaydayRemoteRepository.shiftFeedPageSize).map { _ in UUID() }
        let repository = repository(replies: [
            .http(200, body: Self.pageJSON(rowIDs: fullPage)),
            .http(500, body: Self.postgrestError),
        ])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShiftChanges(cursor: nil)
        }
        #expect(FaultStubURLProtocol.recorded().count == 2)
    }

    /// The same page re-served (a retry, a replayed response, overlapping
    /// pages) must not double-apply rows.
    @Test("duplicate ids across the collection are deduplicated")
    func changesDeduplicateIDs() async throws {
        let repository = repository(replies: [
            .http(200, body: Self.pageJSON(rowIDs: [Self.shiftID, Self.shiftID]))
        ])
        let (rows, serverNow) = try await repository.fetchShiftChanges(cursor: nil)
        #expect(rows.count == 1)
        #expect(rows[0].id == Self.shiftID)
        #expect(serverNow == PaydayRemoteDate.parseInstant(Self.fence))
    }

    // MARK: - The other reads refuse too

    @Test("fetchShifts throws on HTTP 500")
    func fetchShiftsThrowsOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShifts(userID: Self.userID, ids: [Self.shiftID])
        }
    }

    @Test("fetchShifts throws when the body is not decodable")
    func fetchShiftsThrowsOnMalformedBody() async {
        let repository = repository(replies: [.http(200, body: "not json")])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShifts(userID: Self.userID, ids: [Self.shiftID])
        }
    }

    @Test("the legacy change feed throws on HTTP 500")
    func fetchChangesThrowsOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        let cursor = PaydaySyncState.ServerCursor(updatedAt: Self.fence, id: Self.shiftID)
        await #expect(throws: (any Error).self) {
            try await repository.fetchChanges(
                userID: Self.userID,
                tipCursor: cursor,
                paycheckCursor: cursor,
                settingsUpdatedAt: Self.fence,
                forceSettingsRead: false
            )
        }
    }

    /// The snapshot's settings row is `.single()` — a valid empty array must
    /// throw rather than produce a snapshot with no settings in it.
    @Test("fetchSnapshot throws when the settings read comes back empty")
    func snapshotThrowsOnEmptySettings() async {
        let repository = repository(replies: [
            .http(200, body: "[]"),   // tips
            .http(200, body: "[]"),   // paychecks
            .http(200, body: "[]"),   // settings, asked for .single()
        ])
        await #expect(throws: (any Error).self) {
            try await repository.fetchSnapshot(userID: Self.userID)
        }
    }

    // MARK: - The authority legs fail closed

    /// An absent migration row means "unconverted" and is not an error. A
    /// FAULTED read is a different state and must not borrow that meaning —
    /// it throws, and the account simply doesn't flip this pass.
    @Test("fetchShiftMigrationState throws on HTTP 500 rather than reading as absent")
    func migrationStateThrowsOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShiftMigrationState(userID: Self.userID)
        }
    }

    @Test("fetchShiftMigrationState throws on an undecodable row")
    func migrationStateThrowsOnMalformed() async {
        let repository = repository(replies: [.http(200, body: "[{\"user_id\":\"nope\"}]")])
        await #expect(throws: (any Error).self) {
            try await repository.fetchShiftMigrationState(userID: Self.userID)
        }
    }

    /// An absent dataset_revisions row is revision 0 by contract. A faulted
    /// read is not revision 0 — a stale_input race and a broken wire are
    /// different states and the latter throws.
    @Test("fetchDatasetRevision throws on HTTP 500 rather than reading as 0")
    func datasetRevisionThrowsOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        await #expect(throws: (any Error).self) {
            try await repository.fetchDatasetRevision(userID: Self.userID)
        }
    }

    @Test("fetchDatasetRevision throws on an undecodable row")
    func datasetRevisionThrowsOnMalformed() async {
        let repository = repository(replies: [.http(200, body: "[{\"revision\":\"not-a-number\"}]")])
        await #expect(throws: (any Error).self) {
            try await repository.fetchDatasetRevision(userID: Self.userID)
        }
    }

    /// The conversion budgeter reads this count every pass; a faulted count
    /// must throw rather than read as 0 ("nothing left to convert").
    @Test("unmigratedTipRowCount throws on HTTP 500 rather than reading as 0")
    func unmigratedCountThrowsOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        await #expect(throws: (any Error).self) {
            try await repository.unmigratedTipRowCount()
        }
    }

    /// `upsertEarningsSnapshot` returns the server's verdict as a string
    /// BECAUSE `stale_input` is an ordinary outcome and must stay
    /// distinguishable from a network failure. A fault must throw, not read
    /// as either verdict.
    @Test("upsertEarningsSnapshot throws on HTTP 500")
    func earningsSnapshotThrowsOnServerError() async {
        let repository = repository(replies: [.http(500, body: Self.postgrestError)])
        await #expect(throws: (any Error).self) {
            try await repository.upsertEarningsSnapshot(
                revision: 1,
                engineVersion: 1,
                asOf: nil,
                manifestDigest: "digest",
                payload: Data("{}".utf8)
            )
        }
    }
}

/// A `URLProtocol` that answers requests from a queue of canned replies —
/// consumed in order, with the last reply repeating when the caller makes
/// more requests than the queue holds. The queue is what the mid-pagination
/// fault needs: a good first page, then a 500.
private final class FaultStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(Int, body: String)
        case transport(URLError.Code)
    }

    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var served = 0
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(replies: [Reply]) {
        lock.lock()
        self.replies = replies
        served = 0
        requests = []
        lock.unlock()
    }

    static func recorded() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let index = min(Self.served, Self.replies.count - 1)
        Self.served += 1
        let reply = Self.replies[index]
        Self.lock.unlock()

        switch reply {
        case .http(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .transport(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
