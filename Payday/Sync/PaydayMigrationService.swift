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

    /// How many legacy groups the server has not converted yet, or nil when
    /// the question does not apply.
    ///
    /// **A SUB-STATE ON THE REPORT, NEVER A `Phase`**, and the reason is
    /// specific enough to be worth writing at the declaration. An earlier
    /// design made this `Phase.awaitingAccountConversion` and said
    /// `syncIfReady` would not fire in that phase. That turns into a total
    /// account outage, because `PaydayCloudState.syncIfReady` opens with
    /// `guard case .ready = phase` and `queueSyncAfterLocalChange` routes
    /// through the same function. The moment the phase were not `.ready`
    /// NOTHING would sync: no tip pull, no tip push, no paycheck or settings
    /// sync, and no flush of `pendingTipDeletions` -- which is the only
    /// carrier of a deletion a 1.0 build queued and never sent.
    ///
    /// So the phase stays `.ready`, everything else syncs normally, only the
    /// shift leg is skipped, and the wait is a BANNER.
    var conversionPending: Int?

    init(
        localTipEntryCount: Int,
        localPaycheckCount: Int,
        remoteTipEntryCount: Int,
        remotePaycheckCount: Int,
        tipEntryHash: String,
        paycheckHash: String,
        conversionPending: Int? = nil
    ) {
        self.localTipEntryCount = localTipEntryCount
        self.localPaycheckCount = localPaycheckCount
        self.remoteTipEntryCount = remoteTipEntryCount
        self.remotePaycheckCount = remotePaycheckCount
        self.tipEntryHash = tipEntryHash
        self.paycheckHash = paycheckHash
        self.conversionPending = conversionPending
    }

    /// Whether a conversion is outstanding. `0` means finished, not pending,
    /// so this is deliberately not `conversionPending != nil`.
    var isConversionPending: Bool { (conversionPending ?? 0) > 0 }
}

enum PaydayMigrationError: LocalizedError {
    case tipEntryMismatch
    case paycheckMismatch
    case invalidRemoteData
    case accountMismatch
    /// The account's legacy rows are uploaded and backed up, but the server
    /// has not finished converting them into shifts yet.
    case conversionIncomplete

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
        case .conversionIncomplete:
            // Verbatim from the design. The first clause is only TRUE because
            // public.tip_entries is never rewritten by the conversion, so
            // this copy and that invariant ship together: if a future slice
            // ever rewrites a legacy row, this sentence becomes a lie and has
            // to change with it.
            "Payday is still updating your shifts. Everything you've logged is saved and already backed up to your account; your shifts start syncing as soon as that finishes."
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
        policyStore: PolicyStore,
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
            moveLedgerStore: moveLedgerStore,
            policyStore: policyStore
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
            policyStore: policyStore,
            // Initial import is insert-only. Its readback is therefore the
            // canonical server value whether this is the first device or a
            // later one; never let a fresh device's defaults win by clock.
            forceRemoteRows: true,
            forceRemoteSettings: true
        )
        // Derived from the LOCAL rows the reconcile just wrote, not from the
        // server rows they came from. Those rows now hold canonical server
        // content either way, but only a locally derived digest is rendered
        // the way the NEXT sync will render it: the server's own
        // `contentFingerprint` digests the `work_date` string it stores,
        // while every later comparison goes through
        // `PaydayRemoteDate.stableDay`, and those two disagree outside
        // (UTC-10:30, UTC+13:30]. Seeded from the server side, a user in
        // UTC-11, UTC+14 or Chatham would see the entire history re-upload on
        // the first sync after migrating.
        let reconciledTips = try context.fetch(FetchDescriptor<TipEntry>())
            .filter { activeIDs.tipIDs.contains($0.id) }
        let reconciledPaychecks = try context.fetch(FetchDescriptor<PaycheckRecord>())
            .filter { activeIDs.paycheckIDs.contains($0.id) }
        // The fingerprints are computed OUTSIDE the mutation, because the
        // closure cannot throw and these can.
        let tipFingerprints = try PaydayRowFingerprint.values(reconciledTips)
        let paycheckFingerprints = try PaydayRowFingerprint.values(reconciledPaychecks)
        // `mutate`, never a fresh Snapshot: see PaydaySyncState.mutate.
        PaydaySyncState.mutate(userID: userID) { checkpoint in
            checkpoint.tipEntryIDs = activeIDs.tipIDs
            checkpoint.paycheckIDs = activeIDs.paycheckIDs
            checkpoint.migrationVerified = true
            checkpoint.tipClientUpdatedAt = Dictionary(
                uniqueKeysWithValues: remoteTips.map { ($0.id, $0.clientUpdatedAt) })
            checkpoint.paycheckClientUpdatedAt = Dictionary(
                uniqueKeysWithValues: remotePaychecks.map { ($0.id, $0.clientUpdatedAt) })
            // Recording these is also what keeps a freshly migrated install
            // off the one-time seeding read.
            checkpoint.tipContentFingerprint = tipFingerprints
            checkpoint.paycheckContentFingerprint = paycheckFingerprints
            checkpoint.settingsClientUpdatedAt = snapshot.settings.clientUpdatedAt
            checkpoint.tipServerCursor = PaydaySyncState.ServerCursor.advanced(
                from: .beginning,
                candidates: snapshot.tips.map { ($0.serverUpdatedAt, $0.id) }
            )
            checkpoint.paycheckServerCursor = PaydaySyncState.ServerCursor.advanced(
                from: .beginning,
                candidates: snapshot.paychecks.map { ($0.serverUpdatedAt, $0.id) }
            )
            checkpoint.settingsServerUpdatedAt = snapshot.settings.serverUpdatedAt
        }

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
