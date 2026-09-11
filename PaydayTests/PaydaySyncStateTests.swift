import Foundation
import SwiftData
import Testing
@testable import Payday

@Suite("Payday sync efficiency and ownership")
struct PaydaySyncStateTests {
    @Test("only new or locally changed rows are selected for upload")
    func changedRowsOnly() {
        let unchanged = UUID()
        let changed = UUID()
        let inserted = UUID()

        let result = PaydaySyncState.changedIDs(
            current: [unchanged: "1", changed: "2", inserted: "1"],
            acknowledged: [unchanged: "1", changed: "1"]
        )

        #expect(result == [changed, inserted])
    }

    @Test("a different account cannot claim an existing offline cache")
    func accountMismatchFailsClosed() {
        let existing = UUID()

        #expect(PaydaySyncState.canRegister(userID: existing, registeredUserID: existing))
        #expect(!PaydaySyncState.canRegister(userID: UUID(), registeredUserID: existing))
    }

    @Test("legacy checkpoints decode with empty efficiency metadata")
    func legacyCheckpointDecodes() throws {
        struct LegacySnapshot: Codable {
            let tipEntryIDs: Set<UUID>
            let paycheckIDs: Set<UUID>
            let migrationVerified: Bool
        }
        let tipID = UUID()
        let data = try JSONEncoder().encode(LegacySnapshot(
            tipEntryIDs: [tipID],
            paycheckIDs: [],
            migrationVerified: true
        ))

        let decoded = try JSONDecoder().decode(PaydaySyncState.Snapshot.self, from: data)

        #expect(decoded.tipEntryIDs == [tipID])
        #expect(decoded.migrationVerified)
        #expect(decoded.tipClientUpdatedAt.isEmpty)
        #expect(decoded.paycheckClientUpdatedAt.isEmpty)
        #expect(decoded.settingsClientUpdatedAt == nil)
        #expect(decoded.tipServerCursor == nil)
        #expect(decoded.paycheckServerCursor == nil)
        #expect(decoded.settingsServerUpdatedAt == nil)
    }

    @Test("server cursor uses timestamp and ID tie-breaker")
    func serverCursorFilter() {
        let id = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let cursor = PaydaySyncState.ServerCursor(
            updatedAt: "2026-09-04T12:34:56.123Z",
            id: id
        )

        #expect(
            cursor.postgrestFilter
                == "updated_at.gt.2026-09-04T12:34:56.123Z,and(updated_at.eq.2026-09-04T12:34:56.123Z,id.gt.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)"
        )
    }

    @Test("server cursor advances across shared transaction timestamps")
    func serverCursorAdvances() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        let result = PaydaySyncState.ServerCursor.advanced(
            from: .beginning,
            candidates: [
                ("2026-09-04T12:34:56.123Z", firstID),
                ("2026-09-04T12:34:56.123Z", secondID),
                ("2026-09-04T12:34:57.000Z", laterID)
            ]
        )

        #expect(result?.updatedAt == "2026-09-04T12:34:57.000Z")
        #expect(result?.id == laterID)
    }

    @Test("a missing replaceable cache forces a server baseline despite durable cursors")
    func missingCacheForcesBaseline() {
        let tipID = UUID()
        let paycheckID = UUID()
        let checkpoint = PaydaySyncState.Snapshot(
            tipEntryIDs: [tipID],
            paycheckIDs: [paycheckID],
            tipServerCursor: .beginning,
            paycheckServerCursor: .beginning,
            settingsServerUpdatedAt: "2026-09-04T12:34:56.123Z"
        )

        #expect(PaydaySyncState.cacheRequiresBaseline(
            localTipIDs: [],
            localPaycheckIDs: [],
            checkpoint: checkpoint
        ))
        #expect(!PaydaySyncState.cacheRequiresBaseline(
            localTipIDs: checkpoint.tipEntryIDs,
            localPaycheckIDs: checkpoint.paycheckIDs,
            checkpoint: checkpoint
        ))
        #expect(!PaydaySyncState.cacheRequiresBaseline(
            localTipIDs: [],
            localPaycheckIDs: [],
            pendingTipDeletionIDs: [tipID],
            pendingPaycheckDeletionIDs: [paycheckID],
            checkpoint: checkpoint
        ))
    }

    @Test("partial unexpected cache loss forces a server baseline")
    func partialCacheLossForcesBaseline() {
        let retained = UUID()
        let missing = UUID()
        let checkpoint = PaydaySyncState.Snapshot(
            tipEntryIDs: [retained, missing],
            tipServerCursor: .beginning,
            paycheckServerCursor: .beginning,
            settingsServerUpdatedAt: "2026-09-04T12:34:56.123Z"
        )

        #expect(PaydaySyncState.cacheRequiresBaseline(
            localTipIDs: [retained],
            localPaycheckIDs: [],
            checkpoint: checkpoint
        ))
    }

    @Test("server reconciliation preserves only edits made while sync was suspended")
    func concurrentEditDetectionIgnoresWallClockOrdering() {
        let id = UUID()
        let futureSkewedVersion = "2099-01-01T00:00:00.000Z"
        let captured = [id: futureSkewedVersion]

        #expect(!PaydaySyncState.localRowChangedDuringSync(
            id: id,
            currentClientUpdatedAt: futureSkewedVersion,
            capturedClientUpdatedAt: captured
        ))
        #expect(PaydaySyncState.localRowChangedDuringSync(
            id: id,
            currentClientUpdatedAt: "2099-01-01T00:00:01.000Z",
            capturedClientUpdatedAt: captured
        ))
    }

    @Test("in-flight inserts edits and deletions remain unacknowledged")
    func inFlightMutationsRemainPending() {
        let edited = UUID()
        let inserted = UUID()
        let deleted = UUID()
        let untouched = UUID()
        let captured = [
            edited: "1",
            deleted: "1",
            untouched: "1"
        ]
        let beforeReconcile = [
            edited: "2",
            inserted: "1",
            untouched: "1"
        ]

        let changed = PaydaySyncState.IDsChangedDuringSync(
            captured: captured,
            current: beforeReconcile
        )
        let acknowledged = PaydaySyncState.acknowledgedVersions(
            current: beforeReconcile,
            checkpoint: captured,
            changedDuringSync: changed
        )

        #expect(changed == [edited, inserted, deleted])
        #expect(acknowledged[edited] == "1")
        #expect(acknowledged[inserted] == nil)
        #expect(acknowledged[deleted] == "1")
        #expect(acknowledged[untouched] == "1")
        #expect(PaydaySyncState.changedIDs(
            current: beforeReconcile,
            acknowledged: acknowledged
        ) == [edited, inserted])
    }

    @MainActor
    @Test("canonical migration tombstones beat a future-skewed local clock")
    func canonicalMigrationForcesRemoteTombstone() throws {
        let container = try ModelContainer(
            for: TipEntry.self,
            PaycheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let local = TipEntry(
            id: id,
            date: Date(timeIntervalSince1970: 0),
            amountCents: 4_200,
            kind: .credit
        )
        local.modifiedAt = Date(timeIntervalSince1970: 4_070_908_800)
        context.insert(local)
        try context.save()

        let remote = try JSONDecoder().decode(
            RemoteTipEntry.self,
            from: Data(#"{"id":"11111111-1111-4111-8111-111111111111","user_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","shift_id":null,"work_date":"2026-09-04","amount_cents":4200,"kind":"credit","note":null,"recorded_at":null,"is_double":false,"hours_worked":null,"tip_out_cents":null,"sales_cents":null,"shift_period":null,"clock_in":null,"clock_out":null,"server_count":null,"receipt_metrics":null,"client_updated_at":"2026-09-04T12:00:00.000Z","deleted_at":"2026-09-04T12:01:00.000Z","updated_at":"2026-09-04T12:01:00.000Z"}"#.utf8)
        )

        let active = try PaydaySyncService.reconcileTips(
            [remote],
            in: context,
            forceRemote: true
        )

        #expect(active.isEmpty)
        #expect(try context.fetch(FetchDescriptor<TipEntry>()).isEmpty)
    }
}
