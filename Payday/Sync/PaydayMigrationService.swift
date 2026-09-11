import Foundation
import Supabase
import SwiftData

struct PaydayMigrationReport: Equatable, Sendable {
    let localTipEntryCount: Int
    let localPaycheckCount: Int
    let remoteTipEntryCount: Int
    let remotePaycheckCount: Int
    let tipEntryHash: String
    let paycheckHash: String
}

enum PaydayMigrationError: LocalizedError {
    case tipEntryMismatch
    case paycheckMismatch
    case invalidRemoteData
    case accountMismatch

    var errorDescription: String? {
        switch self {
        case .tipEntryMismatch:
            "Some shifts didn't sync. Your local copy is unchanged."
        case .paycheckMismatch:
            "Some paychecks didn't sync. Your local copy is unchanged."
        case .invalidRemoteData:
            "A synced record couldn't be read. Your local copy is unchanged."
        case .accountMismatch:
            "This device already has another Payday account's offline data. Sign back into that account so its cache is never mixed with yours."
        }
    }
}

@MainActor
final class PaydayMigrationService {
    private let client: SupabaseClient

    init(client: SupabaseClient = PaydaySupabase.client) {
        self.client = client
    }

    /// Idempotently contributes the complete local snapshot, then adopts the
    /// signed-in user's canonical server copy. A later device may contain an
    /// older value for an existing UUID; insert-only import must never turn
    /// that normal collision into a migration failure.
    func migrate(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        deviceID: UUID
    ) async throws -> PaydayMigrationReport {
        let user = try await client.auth.session.user
        let userID = user.id
        let localTips = try context.fetch(FetchDescriptor<TipEntry>())
            .map { RemoteTipEntry(entry: $0, userID: userID) }
        let localPaychecks = try context.fetch(FetchDescriptor<PaycheckRecord>())
            .map { RemotePaycheckRecord(record: $0, userID: userID) }
        let repository = PaydayRemoteRepository(client: client)
        let localSettings = RemoteUserSettings(
            userID: userID,
            scheduleStore: scheduleStore,
            preferencesStore: preferencesStore,
            moveLedgerStore: moveLedgerStore
        )

        // Initial import is insert-only. A second device may contribute rows,
        // but it can never overwrite an already-verified server value.
        try await repository.importTips(localTips)
        try await repository.importPaychecks(localPaychecks)
        try await repository.importSettings(localSettings)
        let snapshot = try await repository.fetchSnapshot(userID: userID)
        guard snapshot.tips.allSatisfy({
            $0.serverUpdatedAt.flatMap(PaydayRemoteDate.parseInstant) != nil
        }), snapshot.paychecks.allSatisfy({
            $0.serverUpdatedAt.flatMap(PaydayRemoteDate.parseInstant) != nil
        }), snapshot.settings.serverUpdatedAt.flatMap(PaydayRemoteDate.parseInstant) != nil else {
            throw PaydayMigrationError.invalidRemoteData
        }
        let remoteTips = snapshot.tips.filter { $0.deletedAt == nil }
        let remotePaychecks = snapshot.paychecks.filter { $0.deletedAt == nil }

        let canonicalTipValues = remoteTips.map(\.businessValue)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let canonicalPaycheckValues = remotePaychecks.map(\.businessValue)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let tipHash = try PaydayMigrationHash.value(canonicalTipValues)
        let paycheckHash = try PaydayMigrationHash.value(canonicalPaycheckValues)
        let receipt = RemoteMigrationReceipt(
            userID: userID,
            deviceID: deviceID,
            schemaVersion: 1,
            tipEntryCount: remoteTips.count,
            paycheckRecordCount: remotePaychecks.count,
            tipEntryHash: tipHash,
            paycheckRecordHash: paycheckHash,
            verifiedAt: PaydayRemoteDate.instant(.now)
        )
        try await client
            .from("migration_receipts")
            .upsert(receipt, onConflict: "user_id,device_id")
            .execute()

        let activeIDs = try PaydaySyncService.reconcile(
            snapshot: snapshot,
            context: context,
            scheduleStore: scheduleStore,
            preferencesStore: preferencesStore,
            moveLedgerStore: moveLedgerStore,
            // Initial import is insert-only. Its readback is therefore the
            // canonical server value whether this is the first device or a
            // later one; never let a fresh device's defaults win by clock.
            forceRemoteRows: true,
            forceRemoteSettings: true
        )
        PaydaySyncState.save(
            userID: userID,
            tipEntryIDs: activeIDs.tipIDs,
            paycheckIDs: activeIDs.paycheckIDs,
            migrationVerified: true,
            tipClientUpdatedAt: Dictionary(uniqueKeysWithValues: remoteTips.map { ($0.id, $0.clientUpdatedAt) }),
            paycheckClientUpdatedAt: Dictionary(uniqueKeysWithValues: remotePaychecks.map { ($0.id, $0.clientUpdatedAt) }),
            settingsClientUpdatedAt: snapshot.settings.clientUpdatedAt,
            tipServerCursor: PaydaySyncState.ServerCursor.advanced(
                from: .beginning,
                candidates: snapshot.tips.map { ($0.serverUpdatedAt, $0.id) }
            ),
            paycheckServerCursor: PaydaySyncState.ServerCursor.advanced(
                from: .beginning,
                candidates: snapshot.paychecks.map { ($0.serverUpdatedAt, $0.id) }
            ),
            settingsServerUpdatedAt: snapshot.settings.serverUpdatedAt
        )

        return PaydayMigrationReport(
            localTipEntryCount: localTips.count,
            localPaycheckCount: localPaychecks.count,
            remoteTipEntryCount: remoteTips.count,
            remotePaycheckCount: remotePaychecks.count,
            tipEntryHash: tipHash,
            paycheckHash: paycheckHash
        )
    }

}
