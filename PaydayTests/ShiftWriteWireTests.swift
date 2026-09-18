import Foundation
import Supabase
import Testing
@testable import Payday

/// PR 2 slice S6: the wire shapes for the shift write RPCs.
///
/// Two things are worth asserting here rather than trusting. First, that the
/// encode side names ONLY the columns `private.write_shifts` reads — four
/// columns on `public.shifts` are server-authored and a client that could set
/// them could defeat rollback, the fold's precedence rule, or the one-way
/// tombstone. Second, that the OUTCOMES are decoded at all: the RPCs return a
/// row per requested id precisely so a caller can tell `stored` from
/// `invalid`, and a caller that discarded them would mark a dropped row synced
/// and never retry it.
@Suite("Shift write wire shapes", .serialized)
struct ShiftWriteWireTests {

    // MARK: - Fixtures

    private static let shiftID = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
    private static let userID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private static func shift(
        cash: Int = 1_000,
        credit: Int = 2_000,
        source: String? = nil,
        nativeModifiedAt: String? = nil,
        deletedAt: String? = nil
    ) -> RemoteShift {
        RemoteShift(
            id: shiftID,
            userID: userID,
            workDate: "2026-09-01",
            shiftPeriod: "dinner",
            cashTipsCents: cash,
            creditTipsCents: credit,
            tipOutCents: 150,
            salesCents: 42_000,
            hoursWorked: 6.3833,
            clockIn: "2026-09-01T17:00:00.000Z",
            clockOut: "2026-09-01T23:23:00.000Z",
            serverCount: 4,
            receiptMetrics: nil,
            note: "busy",
            recordedAt: "2026-09-01T23:30:00.000Z",
            clientUpdatedAt: "2026-09-01T23:31:00.000Z",
            source: source,
            legacyEntryIDs: nil,
            nativeModifiedAt: nativeModifiedAt,
            deletedAt: deletedAt,
            deletedReason: nil,
            gratuityFeesCents: nil,
            nonWageEarningsCents: nil,
            version: nil,
            serverUpdatedAt: nil
        )
    }

    /// The first recorded request body, as a JSON object.
    ///
    /// Split into statements on purpose: `#require` nested inside another
    /// `#require`'s argument is a recursive macro expansion and fails to
    /// compile, which is easy to write by accident when unwrapping two things
    /// at once.
    private static func firstBodyObject() throws -> [String: Any] {
        let body = try #require(StubbingURLProtocol.recordedBodies().first)
        let parsed = try JSONSerialization.jsonObject(with: body)
        return try #require(parsed as? [String: Any])
    }

    private static func encodedKeys(_ shift: RemoteShift) throws -> Set<String> {
        let data = try JSONEncoder().encode(shift)
        let parsed = try JSONSerialization.jsonObject(with: data)
        let object = try #require(parsed as? [String: Any])
        return Set(object.keys)
    }

    // MARK: - The encode side

    @Test("a shift payload names every column the writer reads")
    func payloadNamesEveryWrittenColumn() throws {
        let keys = try Self.encodedKeys(Self.shift())
        let expected: Set<String> = [
            "id", "work_date", "shift_period", "cash_tips_cents", "credit_tips_cents",
            "tip_out_cents", "sales_cents", "hours_worked", "clock_in", "clock_out",
            "server_count", "receipt_metrics", "note", "recorded_at", "client_updated_at"
        ]
        #expect(keys == expected, "unexpected: \(keys.symmetricDifference(expected).sorted())")
    }

    /// Each of these is refused at the database too — `public.shifts` grants no
    /// direct INSERT or UPDATE — so this is the second of two layers, not the
    /// only one. It is worth having because the failure is silent: an extra key
    /// would simply be ignored by the RPC today and become meaningful the day
    /// someone widens it.
    @Test("a shift payload never names a server-authored column")
    func payloadOmitsServerAuthoredColumns() throws {
        let keys = try Self.encodedKeys(
            Self.shift(source: "migration", nativeModifiedAt: "2026-09-02T00:00:00.000Z",
                       deletedAt: "2026-09-03T00:00:00.000Z")
        )
        for column in ["source", "legacy_entry_ids", "native_modified_at", "deleted_at",
                       "deleted_reason", "user_id", "version", "updated_at",
                       "gratuity_fees_cents", "non_wage_earnings_cents"] {
            #expect(!keys.contains(column), "payload leaked \(column)")
        }
    }

    /// Rule 4 in the client: a write never resurrects a tombstone, so handing a
    /// tombstoned row to `upsertShifts` must not send `deleted_at: null` and
    /// clear it either. Omission, not a null.
    @Test("a tombstoned shift handed to the writer sends no deleted_at at all")
    func aTombstoneIsNeverSentOnTheWritePath() throws {
        let data = try JSONEncoder().encode(Self.shift(deletedAt: "2026-09-03T00:00:00.000Z"))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("deleted_at"))
    }

    @Test("an absent optional is encoded as an explicit null, not dropped")
    func absentOptionalsAreExplicitNulls() throws {
        // The writer reads each key independently and treats a missing key the
        // same as a null one, so either would work against today's SQL. Sending
        // the null keeps an EDIT that clears a field from being read as "leave
        // it alone", which is the shape that would silently refuse to erase a
        // note or a tip-out.
        let data = try JSONEncoder().encode(Self.shift())
        let parsed = try JSONSerialization.jsonObject(with: data)
        let object = try #require(parsed as? [String: Any])
        #expect(object["receipt_metrics"] is NSNull)
    }

    // MARK: - The decode side

    @Test("a full server row decodes including its provenance")
    func serverRowDecodes() throws {
        let json = """
        {
          "id": "aaaaaaaa-0000-4000-8000-000000000001",
          "user_id": "11111111-1111-4111-8111-111111111111",
          "work_date": "2026-09-01",
          "shift_period": null,
          "cash_tips_cents": 5000,
          "credit_tips_cents": 2000,
          "tip_out_cents": null,
          "sales_cents": null,
          "hours_worked": 6.3833,
          "clock_in": null,
          "clock_out": null,
          "server_count": null,
          "receipt_metrics": null,
          "note": null,
          "recorded_at": null,
          "client_updated_at": "2026-09-01T23:31:00.000Z",
          "source": "migration",
          "legacy_entry_ids": ["bbbbbbbb-0000-4000-8000-000000000002"],
          "native_modified_at": "2026-09-05T00:00:00.000Z",
          "deleted_at": null,
          "deleted_reason": null,
          "gratuity_fees_cents": 0,
          "non_wage_earnings_cents": 7000,
          "version": 3,
          "updated_at": "2026-09-05T00:00:01.000Z"
        }
        """
        let shift = try JSONDecoder().decode(RemoteShift.self, from: Data(json.utf8))
        #expect(shift.cashTipsCents == 5_000)
        #expect(shift.nonWageEarningsCents == 7_000)
        #expect(shift.legacyEntryIDs?.count == 1)
        #expect(shift.version == 3)
        #expect(shift.serverUpdatedAt == "2026-09-05T00:00:01.000Z")
    }

    /// The set a rollback would silently discard: rollback reads
    /// `public.tip_entries` again, and a PR-2 build's edit never writes back
    /// there. Being able to COUNT it before anyone pulls that lever is the
    /// whole reason `source` is not rewritten on an edit.
    @Test("an edited conversion artifact is identifiable")
    func editedConversionArtifactIsIdentifiable() throws {
        #expect(Self.shift(source: "migration", nativeModifiedAt: "2026-09-05T00:00:00.000Z")
            .isEditedConversionArtifact)
        // A conversion nobody has touched is not at risk: rollback restores
        // exactly the value it still holds.
        #expect(!Self.shift(source: "migration").isEditedConversionArtifact)
        // A natively authored shift never was a conversion artifact.
        #expect(!Self.shift(source: "device", nativeModifiedAt: "2026-09-05T00:00:00.000Z")
            .isEditedConversionArtifact)
    }

    @Test("write outcomes decode every status the server can return")
    func writeOutcomesDecode() throws {
        let json = """
        [
          {"shift_id":"aaaaaaaa-0000-4000-8000-000000000001","status":"stored",
           "stored_client_updated_at":"2026-09-18T12:00:00.000Z"},
          {"shift_id":"aaaaaaaa-0000-4000-8000-000000000002","status":"invalid",
           "stored_client_updated_at":null},
          {"shift_id":null,"status":"invalid","stored_client_updated_at":null},
          {"shift_id":"aaaaaaaa-0000-4000-8000-000000000003","status":"refused",
           "stored_client_updated_at":null}
        ]
        """
        let outcomes = try JSONDecoder().decode([ShiftWriteOutcome].self, from: Data(json.utf8))
        #expect(outcomes.count == 4)
        #expect(outcomes[0].status == .stored)
        #expect(outcomes[0].storedClientUpdatedAt == "2026-09-18T12:00:00.000Z")
        #expect(outcomes[1].status == .invalid)
        // The one case the server cannot name back, because the id itself was
        // what it could not read.
        #expect(outcomes[2].shiftID == nil)
        #expect(outcomes[3].status == .refused)
        #expect(outcomes.filter { $0.status.isPersisted }.count == 1)
    }

    /// A server that grows a new status must not make an older client throw
    /// while decoding its own SUCCESSFUL write. The unknown case is what makes
    /// that true, and `isPersisted` stays false so the row is retried rather
    /// than assumed saved.
    @Test("an unrecognised status decodes rather than throwing")
    func unknownStatusDecodes() throws {
        let json = """
        [{"shift_id":"aaaaaaaa-0000-4000-8000-000000000001","status":"quarantined",
          "stored_client_updated_at":null}]
        """
        let outcomes = try JSONDecoder().decode([ShiftWriteOutcome].self, from: Data(json.utf8))
        #expect(outcomes[0].status == .unknown("quarantined"))
        #expect(!outcomes[0].status.isPersisted)
    }

    @Test("lifecycle outcomes decode all six statuses")
    func lifecycleOutcomesDecode() throws {
        let json = """
        [
          {"shift_id":"aaaaaaaa-0000-4000-8000-000000000001","status":"deleted"},
          {"shift_id":"aaaaaaaa-0000-4000-8000-000000000002","status":"absent"},
          {"shift_id":"aaaaaaaa-0000-4000-8000-000000000003","status":"restored"},
          {"shift_id":"aaaaaaaa-0000-4000-8000-000000000004","status":"not_deleted"},
          {"shift_id":"aaaaaaaa-0000-4000-8000-000000000005","status":"refused"},
          {"shift_id":null,"status":"invalid"}
        ]
        """
        let outcomes = try JSONDecoder().decode([ShiftLifecycleOutcome].self, from: Data(json.utf8))
        #expect(outcomes.map(\.status) == [
            .deleted, .absent, .restored, .notDeleted, .refused, .invalid
        ])
        // `refused` is the one a caller must surface rather than retry: it is a
        // 'converted' tombstone, and reopening it would resurrect a shift whose
        // legacy source rows are gone.
        #expect(outcomes[4].status == .refused)
    }

    @Test("an unrecognised lifecycle status decodes rather than throwing")
    func unknownLifecycleStatusDecodes() throws {
        let json = """
        [{"shift_id":"aaaaaaaa-0000-4000-8000-000000000001","status":"embargoed"}]
        """
        let outcomes = try JSONDecoder().decode([ShiftLifecycleOutcome].self, from: Data(json.utf8))
        #expect(outcomes[0].status == .unknown("embargoed"))
    }

    // MARK: - The requests the repository actually makes

    private func repository(body: String) -> PaydayRemoteRepository {
        StubbingURLProtocol.reset(body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbingURLProtocol.self]
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

    @Test("upsertShifts posts p_rows to the RPC and returns the decoded outcomes")
    func upsertShiftsPostsAndDecodes() async throws {
        let repository = repository(body: """
        [{"shift_id":"aaaaaaaa-0000-4000-8000-000000000001","status":"stored",
          "stored_client_updated_at":"2026-09-18T12:00:00.000Z"}]
        """)

        let outcomes = try await repository.upsertShifts([Self.shift()])

        // The clamp is why this matters: the server keeps its own clock's value,
        // not the one that was sent, so the client must record what came back.
        #expect(outcomes.count == 1)
        #expect(outcomes[0].status == .stored)
        #expect(outcomes[0].storedClientUpdatedAt == "2026-09-18T12:00:00.000Z")

        let request = try #require(StubbingURLProtocol.recorded().first)
        #expect(request.url?.path.hasSuffix("/rpc/upsert_shifts") == true)
        #expect(request.httpMethod == "POST")
        let object = try Self.firstBodyObject()
        let rows = try #require(object["p_rows"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["cash_tips_cents"] as? Int == 1_000)
        #expect(rows[0]["source"] == nil)
    }

    @Test("an empty write makes no request at all")
    func emptyWriteMakesNoRequest() async throws {
        let repository = repository(body: "[]")
        let outcomes = try await repository.upsertShifts([])
        #expect(outcomes.isEmpty)
        #expect(StubbingURLProtocol.recorded().isEmpty)
    }

    @Test("softDeleteShifts sends id and deleted_at pairs")
    func softDeleteSendsPairs() async throws {
        let repository = repository(body: """
        [{"shift_id":"aaaaaaaa-0000-4000-8000-000000000001","status":"deleted"}]
        """)
        let when = try #require(PaydayRemoteDate.parseInstant("2026-09-10T00:00:00.000Z"))

        let outcomes = try await repository.softDeleteShifts([Self.shiftID: when])

        #expect(outcomes.map(\.status) == [.deleted])
        let request = try #require(StubbingURLProtocol.recorded().first)
        #expect(request.url?.path.hasSuffix("/rpc/soft_delete_shifts") == true)
        let object = try Self.firstBodyObject()
        let rows = try #require(object["p_rows"] as? [[String: Any]])
        // Swift encodes a UUID in UPPERCASE and Postgres accepts either case
        // on a uuid cast, so the comparison is deliberately case-insensitive
        // rather than pinned to one form. shift_write_rpcs_test.sql asserts the
        // database half of that, because every other fixture there is
        // lowercase and would not have caught a case-sensitive reader.
        let sentID = try #require(rows[0]["id"] as? String)
        #expect(sentID.lowercased() == Self.shiftID.uuidString.lowercased())
        #expect(rows[0]["deleted_at"] as? String == "2026-09-10T00:00:00.000Z")
    }

    @Test("restoreShifts sends p_ids and nothing when the list is empty")
    func restoreSendsIDs() async throws {
        let repository = repository(body: """
        [{"shift_id":"aaaaaaaa-0000-4000-8000-000000000001","status":"restored"}]
        """)

        #expect(try await repository.restoreShifts([]).isEmpty)
        #expect(StubbingURLProtocol.recorded().isEmpty)

        let outcomes = try await repository.restoreShifts([Self.shiftID])
        #expect(outcomes.map(\.status) == [.restored])
        let object = try Self.firstBodyObject()
        let ids = try #require(object["p_ids"] as? [String])
        #expect(ids.count == 1)
    }

    /// REPLACES an S6 test that asserted a plain table select with a keyset
    /// filter and an explicit column list. That read path is gone: it could
    /// not carry a server snapshot time, so its cursor could advance past a
    /// shift folded by a still-open transaction and lose it permanently. The
    /// RPC owns the filter, the ordering and the column set now, and it is
    /// tested where those live -- `supabase/tests` for the shape and
    /// `db-test-race.sh` case 10 for the fence.
    @Test("fetchShiftChanges calls the fenced RPC with the keyset it holds")
    func fetchShiftChangesCallsTheFencedRPC() async throws {
        let repository = repository(body: """
        {"server_now":"2026-09-18T12:00:00.000Z","rows":[]}
        """)
        let cursor = PaydaySyncState.ServerCursor(
            updatedAt: "2026-09-04T12:34:56.123Z",
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )

        let result = try await repository.fetchShiftChanges(cursor: cursor)

        #expect(result.rows.isEmpty)
        // The snapshot time comes back even on an empty page, which is what
        // lets the cursor advance safely when nothing changed.
        #expect(result.serverNow == PaydayRemoteDate.parseInstant("2026-09-18T12:00:00.000Z"))

        let request = try #require(StubbingURLProtocol.recorded().first)
        #expect(request.url?.path.hasSuffix("/rpc/fetch_shift_changes") == true)
        let object = try Self.firstBodyObject()
        #expect(object["p_after_updated_at"] as? String == "2026-09-04T12:34:56.123Z")
        #expect((object["p_after_id"] as? String)?.lowercased()
            == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(object["p_limit"] as? Int == 1_000)
    }

    /// A baseline is the same fenced feed with no cursor, not a separate
    /// unfenced read. S6's snapshot path was an unfenced table select, so the
    /// one sync that pulls a whole history was also the one with no fence.
    @Test("the baseline pull is the same fenced feed with no cursor")
    func baselineUsesTheSameFeed() async throws {
        let repository = repository(body: """
        {"server_now":"2026-09-18T12:00:00.000Z","rows":[]}
        """)

        _ = try await repository.fetchShiftSnapshot()

        let request = try #require(StubbingURLProtocol.recorded().first)
        #expect(request.url?.path.hasSuffix("/rpc/fetch_shift_changes") == true)
        let object = try Self.firstBodyObject()
        // OMITTED rather than sent as explicit nulls: the Supabase client
        // drops nil values from the payload. That is equivalent here only
        // because `fetch_shift_changes` defaults both parameters to null, so
        // an absent key and a null key select the same first page. If those
        // defaults are ever removed, this call starts failing to resolve the
        // overload rather than silently paging from the wrong place --
        // `anUppercaseUuidIsAcceptedAndNormalised`'s sibling lesson, and the
        // reason the SQL suite exercises the null-cursor call directly.
        #expect(object["p_after_updated_at"] == nil)
        #expect(object["p_after_id"] == nil)
        #expect(object["p_limit"] as? Int == 1_000)
    }

    /// Without a readable snapshot time there is no safe fence, and advancing
    /// the cursor on a guess is the exact failure this path exists to
    /// prevent. So it refuses rather than proceeding.
    @Test("a page with an unreadable server time is refused, not guessed at")
    func unreadableServerTimeIsRefused() async throws {
        let repository = repository(body: """
        {"server_now":"not a timestamp","rows":[]}
        """)

        await #expect(throws: PaydayMigrationError.invalidRemoteData) {
            _ = try await repository.fetchShiftChanges(cursor: nil)
        }
    }
}

/// Records requests AND their bodies, and replies with a canned payload.
///
/// `URLRequest.httpBody` is nil once URLSession has converted the body to a
/// stream, which is what happens to every request the Supabase client makes, so
/// the body is read back off `httpBodyStream`. A harness that only checked
/// `httpBody` would silently assert nothing.
private final class StubbingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var responseBody = "[]"
    private static let lock = NSLock()

    static func reset(body: String) {
        lock.lock()
        requests = []
        bodies = []
        responseBody = body
        lock.unlock()
    }

    static func recorded() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func recordedBodies() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            let size = 4_096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            stream.close()
            body = collected
        }

        Self.lock.lock()
        Self.requests.append(request)
        if let body, !body.isEmpty { Self.bodies.append(body) }
        let payload = Self.responseBody
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
