import Foundation
import Testing
@testable import Payday

/// PR 2 slice S8: the shift cursor fence, as a pure function.
///
/// The bug this prevents needs a long-running third-party transaction to
/// express, which is why no existing test caught it and why S6 shipped
/// without it. The database half is proved in `scripts/db-test-race.sh` case
/// 10 against real concurrent sessions. This suite proves the arithmetic,
/// which is the part that has to be exactly right and which a race harness is
/// a poor tool for.
@Suite("Shift cursor fence")
struct ShiftCursorFenceTests {
    private static func instant(_ offsetSeconds: TimeInterval) -> String {
        PaydayRemoteDate.instant(Self.now.addingTimeInterval(offsetSeconds))
    }
    private static let now = Date(timeIntervalSince1970: 1_789_000_000)
    private static let a = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
    private static let b = UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000002")!

    private func cursor(
        pulled: [(updatedAt: String?, id: UUID)],
        from current: PaydaySyncState.ServerCursor? = nil
    ) -> PaydaySyncState.ServerCursor? {
        PaydaySyncState.clampedShiftCursor(
            from: current, pulledUpdatedAt: pulled, serverNow: Self.now)
    }

    /// The failing sequence, in arithmetic. A row stamped 400s ago is outside
    /// the 300s window, so the cursor may sit on it.
    @Test("a row older than the window is safe to advance to")
    func oldRowAdvancesToItself() throws {
        let stamp = Self.instant(-400)
        let result = try #require(cursor(pulled: [(stamp, Self.a)]))
        #expect(result.updatedAt == stamp)
        #expect(result.id == Self.a)
    }

    /// The case that matters. A row stamped 10s ago is inside the window, so a
    /// transaction that began before it and has not committed yet could still
    /// be carrying an earlier stamp. The cursor is held at the fence instead.
    @Test("a row inside the window holds the cursor at the fence, not at the row")
    func recentRowIsClamped() throws {
        let stamp = Self.instant(-10)
        let result = try #require(cursor(pulled: [(stamp, Self.a)]))

        let resolved = try #require(PaydayRemoteDate.parseInstant(result.updatedAt))
        #expect(resolved == Self.now.addingTimeInterval(-300))
        // Deliberately BEHIND the row just pulled. Re-pulling is free.
        let rowStamp = try #require(PaydayRemoteDate.parseInstant(stamp))
        #expect(resolved < rowStamp)
    }

    /// When the clamp binds, the id half must be the zero UUID. The filter is
    /// `updated_at > X or (updated_at = X and id > Y)`, so carrying a pulled
    /// row's id alongside a clamped-down timestamp would skip any row sitting
    /// exactly at X with a lower id.
    @Test("a clamped cursor carries the zero id, not a pulled row's")
    func clampedCursorUsesTheZeroID() throws {
        let result = try #require(cursor(pulled: [(Self.instant(-10), Self.b)]))
        #expect(result.id == UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        #expect(result.id != Self.b)
    }

    /// A delta pass that returns nothing still has to advance, or the account
    /// re-reads its whole history every pass forever.
    @Test("an empty pull still advances to the fence")
    func emptyPullAdvancesToTheFence() throws {
        let result = try #require(cursor(pulled: []))
        let resolved = try #require(PaydayRemoteDate.parseInstant(result.updatedAt))
        #expect(resolved == Self.now.addingTimeInterval(-300))
    }

    /// Ties broken by id, exactly as the shipped tip cursor does, so one
    /// transaction stamping a whole batch with an identical timestamp cannot
    /// make the client skip rows.
    @Test("rows sharing a timestamp are tie-broken by id")
    func tiesBreakByID() throws {
        let stamp = Self.instant(-400)
        let result = try #require(cursor(pulled: [(stamp, Self.a), (stamp, Self.b)]))
        #expect(result.updatedAt == stamp)
        #expect(result.id == Self.b, "the higher id wins, matching the tip cursor")
    }

    /// A different failure from the one being fixed: a cursor that walks
    /// backwards every pass would re-pull an unbounded history. The fence may
    /// hold the cursor still, never rewind it.
    @Test("the fence never moves an existing cursor backwards")
    func neverRewindsAnExistingCursor() throws {
        let held = PaydaySyncState.ServerCursor(updatedAt: Self.instant(-100), id: Self.a)
        // Nothing pulled, so the fence would propose now-300s, which is
        // EARLIER than the cursor already held.
        let result = try #require(cursor(pulled: [], from: held))
        #expect(result.updatedAt == held.updatedAt)
        #expect(result.id == held.id)
    }

    @Test("a cursor that can legitimately move forward still does")
    func advancesWhenAhead() throws {
        let held = PaydaySyncState.ServerCursor(updatedAt: Self.instant(-900), id: Self.a)
        let stamp = Self.instant(-400)
        let result = try #require(cursor(pulled: [(stamp, Self.b)], from: held))
        #expect(result.updatedAt == stamp)
        #expect(result.id == Self.b)
    }

    /// Unreadable timestamps are skipped rather than trusted. A row whose
    /// `updated_at` cannot be parsed must not become the cursor.
    @Test("an unparseable timestamp cannot become the cursor")
    func unparseableRowsAreIgnored() throws {
        let result = try #require(cursor(pulled: [("not a date", Self.a), (nil, Self.b)]))
        let resolved = try #require(PaydayRemoteDate.parseInstant(result.updatedAt))
        #expect(resolved == Self.now.addingTimeInterval(-300))
    }

    /// The window is the contract the database comment and the release gate
    /// both name. If this changes, both have to change with it.
    @Test("the window is five minutes")
    func windowIsFiveMinutes() {
        #expect(PaydaySyncState.shiftCursorSafetyWindow == 300)
    }

    /// The page wire shape: rows and the snapshot time decode together.
    @Test("a change-feed page decodes its rows and its server time")
    func pageDecodes() throws {
        let json = """
        {
          "server_now": "2026-09-18T12:00:00.000Z",
          "rows": [{
            "id": "aaaaaaaa-0000-4000-8000-000000000001",
            "user_id": "11111111-1111-4111-8111-111111111111",
            "work_date": "2026-09-01",
            "cash_tips_cents": 5000,
            "credit_tips_cents": 0,
            "client_updated_at": "2026-09-01T23:00:00.000Z",
            "updated_at": "2026-09-01T23:00:01.000Z"
          }]
        }
        """
        let page = try JSONDecoder().decode(RemoteShiftPage.self, from: Data(json.utf8))
        #expect(page.serverNow == "2026-09-18T12:00:00.000Z")
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.cashTipsCents == 5_000)
    }

    @Test("an empty page still carries a server time")
    func emptyPageStillStamped() throws {
        let json = #"{"server_now":"2026-09-18T12:00:00.000Z","rows":[]}"#
        let page = try JSONDecoder().decode(RemoteShiftPage.self, from: Data(json.utf8))
        #expect(page.rows.isEmpty)
        #expect(page.serverNow == "2026-09-18T12:00:00.000Z")
    }
}
