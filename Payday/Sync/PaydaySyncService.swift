import Foundation
import OSLog
import Supabase
import SwiftData

struct PaydayRemoteSnapshot: Sendable {
    let tips: [RemoteTipEntry]
    let paychecks: [RemotePaycheckRecord]
    let settings: RemoteUserSettings
}

struct PaydayRemoteChanges: Sendable {
    let tips: [RemoteTipEntry]
    let paychecks: [RemotePaycheckRecord]
    let settings: RemoteUserSettings?
}

struct PaydaySyncOutcome: Sendable {
    let report: PaydayMigrationReport
    let requiresFollowUpSync: Bool
}

struct PaydayRemoteRepository {
    let client: SupabaseClient
    private let batchSize = 500
    private let tipColumns = "id,user_id,shift_id,work_date,amount_cents,kind,note,recorded_at,is_double,hours_worked,tip_out_cents,sales_cents,shift_period,clock_in,clock_out,server_count,receipt_metrics,client_updated_at,deleted_at,updated_at"
    private let paycheckColumns = "id,user_id,period_start,period_end,paid_tips_cents,note,hourly_rate_cents,owed_tips_cents,gross_pay_cents,net_pay_cents,regular_wages_cents,overtime_wages_cents,gratuity_cents,taxes_cents,client_updated_at,deleted_at,updated_at"
    private let settingsColumns = "user_id,first_name,base_hourly_wage_cents,pay_frequency,anchor_period_end,pay_delay_days,first_weekday,smart_nudge_enabled,payday_reminder_enabled,move_ledger,client_updated_at,updated_at"

    func importTips(_ rows: [RemoteTipEntry]) async throws {
        try await send(rows, function: "import_tip_entries")
    }

    func importPaychecks(_ rows: [RemotePaycheckRecord]) async throws {
        try await send(rows, function: "import_paycheck_records")
    }

    func upsertTips(_ rows: [RemoteTipEntry]) async throws {
        try await send(rows, function: "upsert_tip_entries")
    }

    func upsertPaychecks(_ rows: [RemotePaycheckRecord]) async throws {
        try await send(rows, function: "upsert_paycheck_records")
    }

    func importSettings(_ settings: RemoteUserSettings) async throws {
        try await client
            .rpc("import_user_settings", params: PaydayRPCRow(pRow: settings))
            .execute()
    }

    func upsertSettings(_ settings: RemoteUserSettings) async throws {
        try await client
            .rpc("upsert_user_settings", params: PaydayRPCRow(pRow: settings))
            .execute()
    }

    func softDeleteTips(_ pending: [UUID: Date]) async throws {
        try await softDelete(pending, function: "soft_delete_tip_entries")
    }

    func softDeletePaychecks(_ pending: [UUID: Date]) async throws {
        try await softDelete(pending, function: "soft_delete_paycheck_records")
    }

    func fetchSnapshot(userID: UUID) async throws -> PaydayRemoteSnapshot {
        let tipRows: [RemoteTipEntry] = try await fetchChanged(
            table: "tip_entries",
            columns: tipColumns,
            userID: userID,
            after: .beginning,
            cursor: { PaydaySyncState.ServerCursor(updatedAt: $0.serverUpdatedAt ?? "", id: $0.id) }
        )
        let paycheckRows: [RemotePaycheckRecord] = try await fetchChanged(
            table: "paycheck_records",
            columns: paycheckColumns,
            userID: userID,
            after: .beginning,
            cursor: { PaydaySyncState.ServerCursor(updatedAt: $0.serverUpdatedAt ?? "", id: $0.id) }
        )
        let settings: RemoteUserSettings = try await client
            .from("user_settings")
            .select(settingsColumns)
            .eq("user_id", value: userID)
            .single()
            .execute()
            .value
        // A row updated while a long baseline is paging can legitimately
        // appear once at its old position and again at its newer server
        // timestamp. Keep the last (newest) occurrence so migration counts
        // and hashes describe one canonical row per UUID.
        let tips = deduplicated(tipRows, id: \.id)
        let paychecks = deduplicated(paycheckRows, id: \.id)
        return PaydayRemoteSnapshot(tips: tips, paychecks: paychecks, settings: settings)
    }

    /// Keyset pagination keeps steady-state downloads proportional to rows
    /// changed since the last acknowledged server cursor. The `(updated_at,
    /// id)` pair avoids skipping rows when one transaction stamps a whole
    /// upload batch with the same server time.
    func fetchChanges(
        userID: UUID,
        tipCursor: PaydaySyncState.ServerCursor,
        paycheckCursor: PaydaySyncState.ServerCursor,
        settingsUpdatedAt: String,
        forceSettingsRead: Bool
    ) async throws -> PaydayRemoteChanges {
        let tips: [RemoteTipEntry] = try await fetchChanged(
            table: "tip_entries",
            columns: tipColumns,
            userID: userID,
            after: tipCursor,
            cursor: { PaydaySyncState.ServerCursor(updatedAt: $0.serverUpdatedAt ?? "", id: $0.id) }
        )
        let paychecks: [RemotePaycheckRecord] = try await fetchChanged(
            table: "paycheck_records",
            columns: paycheckColumns,
            userID: userID,
            after: paycheckCursor,
            cursor: { PaydaySyncState.ServerCursor(updatedAt: $0.serverUpdatedAt ?? "", id: $0.id) }
        )
        let settings = try await fetchSettings(
            userID: userID,
            updatedAfter: forceSettingsRead ? nil : settingsUpdatedAt
        )
        return PaydayRemoteChanges(tips: tips, paychecks: paychecks, settings: settings)
    }

    func fetchTips(userID: UUID, ids: Set<UUID>) async throws -> [RemoteTipEntry] {
        try await fetchByIDs(table: "tip_entries", columns: tipColumns, userID: userID, ids: ids)
    }

    func fetchPaychecks(userID: UUID, ids: Set<UUID>) async throws -> [RemotePaycheckRecord] {
        try await fetchByIDs(table: "paycheck_records", columns: paycheckColumns, userID: userID, ids: ids)
    }

    private func send<T: Encodable>(_ rows: [T], function: String) async throws {
        guard !rows.isEmpty else { return }
        for start in stride(from: 0, to: rows.count, by: batchSize) {
            let end = min(start + batchSize, rows.count)
            try await client
                .rpc(function, params: PaydayRPCPayload(pRows: Array(rows[start..<end])))
                .execute()
        }
    }

    private func softDelete(_ pending: [UUID: Date], function: String) async throws {
        let groups = Dictionary(grouping: pending, by: \.value)
        for (date, rows) in groups {
            let values = rows.map(\.key)
            for start in stride(from: 0, to: values.count, by: batchSize) {
                let end = min(start + batchSize, values.count)
                try await client
                    .rpc(
                        function,
                        params: PaydayDeletionParameters(
                            ids: Array(values[start..<end]),
                            deletedAt: PaydayRemoteDate.instant(date)
                        )
                    )
                    .execute()
            }
        }
    }

    private func fetchChanged<T: Decodable>(
        table: String,
        columns: String,
        userID: UUID,
        after initialCursor: PaydaySyncState.ServerCursor,
        cursor: (T) -> PaydaySyncState.ServerCursor
    ) async throws -> [T] {
        var result: [T] = []
        var pageCursor = initialCursor
        while true {
            let page: [T] = try await client
                .from(table)
                .select(columns)
                .eq("user_id", value: userID)
                .or(pageCursor.postgrestFilter)
                .order("updated_at", ascending: true)
                .order("id", ascending: true)
                .limit(1_000)
                .execute()
                .value
            result.append(contentsOf: page)
            guard page.count == 1_000, let last = page.last else { return result }
            let next = cursor(last)
            guard PaydayRemoteDate.parseInstant(next.updatedAt) != nil else {
                throw PaydayMigrationError.invalidRemoteData
            }
            pageCursor = next
        }
    }

    private func fetchByIDs<T: Decodable>(
        table: String,
        columns: String,
        userID: UUID,
        ids: Set<UUID>
    ) async throws -> [T] {
        guard !ids.isEmpty else { return [] }
        let orderedIDs = ids.sorted { $0.uuidString < $1.uuidString }
        var result: [T] = []
        for start in stride(from: 0, to: orderedIDs.count, by: batchSize) {
            let end = min(start + batchSize, orderedIDs.count)
            let page: [T] = try await client
                .from(table)
                .select(columns)
                .eq("user_id", value: userID)
                .in("id", values: Array(orderedIDs[start..<end]))
                .execute()
                .value
            result.append(contentsOf: page)
        }
        return result
    }

    private func fetchSettings(userID: UUID, updatedAfter: String?) async throws -> RemoteUserSettings? {
        var query = client
            .from("user_settings")
            .select(settingsColumns)
            .eq("user_id", value: userID)
        if let updatedAfter {
            query = query.gt("updated_at", value: updatedAfter)
        }
        let rows: [RemoteUserSettings] = try await query.limit(1).execute().value
        return rows.first
    }

    private func deduplicated<Row>(_ rows: [Row], id: KeyPath<Row, UUID>) -> [Row] {
        var result: [UUID: Row] = [:]
        for row in rows {
            result[row[keyPath: id]] = row
        }
        return Array(result.values)
    }
}

@MainActor
final class PaydaySyncService {
    private static let logger = Logger(
        subsystem: "com.szakacsmedia.payday",
        category: "SupabaseSync"
    )
    private let client: SupabaseClient

    init(client: SupabaseClient = PaydaySupabase.client) {
        self.client = client
    }

    static func cachedReport(context: ModelContext, userID: UUID) throws -> PaydayMigrationReport {
        let tips = try context.fetch(FetchDescriptor<TipEntry>())
            .map { RemoteTipEntry(entry: $0, userID: userID).businessValue }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let paychecks = try context.fetch(FetchDescriptor<PaycheckRecord>())
            .map { RemotePaycheckRecord(record: $0, userID: userID).businessValue }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return PaydayMigrationReport(
            localTipEntryCount: tips.count,
            localPaycheckCount: paychecks.count,
            remoteTipEntryCount: tips.count,
            remotePaycheckCount: paychecks.count,
            tipEntryHash: try PaydayMigrationHash.value(tips),
            paycheckHash: try PaydayMigrationHash.value(paychecks)
        )
    }

    func synchronize(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore
    ) async throws -> PaydaySyncOutcome {
        let userID = try await client.auth.session.user.id
        let repository = PaydayRemoteRepository(client: client)
        let localTips = try context.fetch(FetchDescriptor<TipEntry>())
            .map { RemoteTipEntry(entry: $0, userID: userID) }
        let localPaychecks = try context.fetch(FetchDescriptor<PaycheckRecord>())
            .map { RemotePaycheckRecord(record: $0, userID: userID) }
        let localSettings = RemoteUserSettings(
            userID: userID,
            scheduleStore: scheduleStore,
            preferencesStore: preferencesStore,
            moveLedgerStore: moveLedgerStore
        )
        let checkpoint = PaydaySyncState.snapshot(for: userID)
        let localTipVersionsAtStart = Dictionary(uniqueKeysWithValues: localTips.map {
            ($0.id, $0.clientUpdatedAt)
        })
        let localPaycheckVersionsAtStart = Dictionary(uniqueKeysWithValues: localPaychecks.map {
            ($0.id, $0.clientUpdatedAt)
        })
        let changedTipIDs = PaydaySyncState.changedIDs(
            current: localTipVersionsAtStart,
            acknowledged: checkpoint.tipClientUpdatedAt
        )
        let changedPaycheckIDs = PaydaySyncState.changedIDs(
            current: localPaycheckVersionsAtStart,
            acknowledged: checkpoint.paycheckClientUpdatedAt
        )
        let changedTips = localTips.filter { changedTipIDs.contains($0.id) }
        let changedPaychecks = localPaychecks.filter { changedPaycheckIDs.contains($0.id) }
        let currentTipIDs = Set(localTips.map(\.id))
        let currentPaycheckIDs = Set(localPaychecks.map(\.id))
        var pendingTipDeletions = PaydaySyncState.pendingTipDeletions(for: userID)
        var pendingPaycheckDeletions = PaydaySyncState.pendingPaycheckDeletions(for: userID)

        // A restored row (for example via the Undo toast) cancels its pending
        // deletion. Missing cache rows alone never delete Supabase data.
        let restoredTipIDs = currentTipIDs.intersection(pendingTipDeletions.keys)
        let restoredPaycheckIDs = currentPaycheckIDs.intersection(pendingPaycheckDeletions.keys)
        for id in restoredTipIDs { pendingTipDeletions.removeValue(forKey: id) }
        for id in restoredPaycheckIDs { pendingPaycheckDeletions.removeValue(forKey: id) }
        PaydaySyncState.clearTipDeletions(restoredTipIDs, for: userID)
        PaydaySyncState.clearPaycheckDeletions(restoredPaycheckIDs, for: userID)
        Self.logger.notice(
            "Sync plan. localTips=\(localTips.count) localPaychecks=\(localPaychecks.count) uploadTips=\(changedTips.count) uploadPaychecks=\(changedPaychecks.count) deleteTips=\(pendingTipDeletions.count) deletePaychecks=\(pendingPaycheckDeletions.count)"
        )

        try await repository.upsertTips(changedTips)
        try await repository.upsertPaychecks(changedPaychecks)
        try await repository.softDeleteTips(pendingTipDeletions)
        try await repository.softDeletePaychecks(pendingPaycheckDeletions)
        let settingsChanged = checkpoint.settingsClientUpdatedAt != localSettings.clientUpdatedAt
        if settingsChanged {
            try await repository.upsertSettings(localSettings)
        }

        let remoteTips: [RemoteTipEntry]
        let remotePaychecks: [RemotePaycheckRecord]
        let remoteSettings: RemoteUserSettings?
        let tipCursorRows: [RemoteTipEntry]
        let paycheckCursorRows: [RemotePaycheckRecord]
        let needsServerBaseline = checkpoint.tipServerCursor == nil
            || checkpoint.paycheckServerCursor == nil
            || checkpoint.settingsServerUpdatedAt == nil
            || PaydaySyncState.cacheRequiresBaseline(
                localTipIDs: currentTipIDs,
                localPaycheckIDs: currentPaycheckIDs,
                pendingTipDeletionIDs: Set(pendingTipDeletions.keys),
                pendingPaycheckDeletionIDs: Set(pendingPaycheckDeletions.keys),
                checkpoint: checkpoint
            )

        if needsServerBaseline {
            // Legacy checkpoints predate delta cursors. Pay the full read cost
            // once, verify it, then every later sync uses indexed keyset deltas.
            let snapshot = try await repository.fetchSnapshot(userID: userID)
            try Self.verifyServerContainsLocalSnapshot(
                localTipIDs: currentTipIDs,
                localPaycheckIDs: currentPaycheckIDs,
                snapshot: snapshot
            )
            remoteTips = snapshot.tips
            remotePaychecks = snapshot.paychecks
            remoteSettings = snapshot.settings
            tipCursorRows = snapshot.tips
            paycheckCursorRows = snapshot.paychecks
        } else {
            let changes = try await repository.fetchChanges(
                userID: userID,
                tipCursor: checkpoint.tipServerCursor!,
                paycheckCursor: checkpoint.paycheckServerCursor!,
                settingsUpdatedAt: checkpoint.settingsServerUpdatedAt!,
                forceSettingsRead: settingsChanged
            )
            // Read back only locally touched IDs. This catches a conflict-safe
            // RPC that correctly rejected a stale client timestamp without
            // reverting to an all-history download.
            let confirmedTips = try await repository.fetchTips(
                userID: userID,
                ids: changedTipIDs.union(pendingTipDeletions.keys)
            )
            let confirmedPaychecks = try await repository.fetchPaychecks(
                userID: userID,
                ids: changedPaycheckIDs.union(pendingPaycheckDeletions.keys)
            )
            try Self.verifyServerContainsChangedRows(
                changedTipIDs: changedTipIDs,
                changedPaycheckIDs: changedPaycheckIDs,
                confirmedTips: confirmedTips,
                confirmedPaychecks: confirmedPaychecks
            )
            remoteTips = Self.merged(changes.tips, confirmedTips, id: \.id)
            remotePaychecks = Self.merged(changes.paychecks, confirmedPaychecks, id: \.id)
            remoteSettings = changes.settings
            // Confirmation reads can contain rows newer than the ordered
            // delta stream. Reconcile them, but never advance a global cursor
            // over unrelated rows that may have committed just before them.
            tipCursorRows = changes.tips
            paycheckCursorRows = changes.paychecks
        }

        guard remoteTips.allSatisfy({
            $0.serverUpdatedAt.flatMap(PaydayRemoteDate.parseInstant) != nil
        }), remotePaychecks.allSatisfy({
            $0.serverUpdatedAt.flatMap(PaydayRemoteDate.parseInstant) != nil
        }) else {
            throw PaydayMigrationError.invalidRemoteData
        }
        Self.logger.notice(
            "Sync download. baseline=\(needsServerBaseline) tips=\(remoteTips.count) paychecks=\(remotePaychecks.count) settings=\(remoteSettings.map { _ in 1 } ?? 0)"
        )

        let tipVersionsBeforeReconcile = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<TipEntry>()).map {
                ($0.id, PaydayRemoteDate.instant($0.modifiedAt))
            }
        )
        let paycheckVersionsBeforeReconcile = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<PaycheckRecord>()).map {
                ($0.id, PaydayRemoteDate.instant($0.modifiedAt))
            }
        )
        let tipsChangedDuringSync = PaydaySyncState.IDsChangedDuringSync(
            captured: localTipVersionsAtStart,
            current: tipVersionsBeforeReconcile
        )
        let paychecksChangedDuringSync = PaydaySyncState.IDsChangedDuringSync(
            captured: localPaycheckVersionsAtStart,
            current: paycheckVersionsBeforeReconcile
        )
        let settingsChangedDuringSync = PaydayRemoteDate.instant(PaydaySettingsSyncClock.modifiedAt)
            != localSettings.clientUpdatedAt

        _ = try Self.reconcileTips(
            remoteTips,
            in: context,
            localVersionsAtStart: localTipVersionsAtStart,
            locallyDeletedDuringSync: Set(localTipVersionsAtStart.keys)
                .subtracting(tipVersionsBeforeReconcile.keys)
        )
        _ = try Self.reconcilePaychecks(
            remotePaychecks,
            in: context,
            localVersionsAtStart: localPaycheckVersionsAtStart,
            locallyDeletedDuringSync: Set(localPaycheckVersionsAtStart.keys)
                .subtracting(paycheckVersionsBeforeReconcile.keys)
        )
        if let remoteSettings {
            Self.apply(
                remoteSettings,
                scheduleStore: scheduleStore,
                preferencesStore: preferencesStore,
                moveLedgerStore: moveLedgerStore,
                force: PaydayRemoteDate.instant(PaydaySettingsSyncClock.modifiedAt)
                    == localSettings.clientUpdatedAt
            )
        }
        try context.save()
        if !remoteTips.isEmpty || !remotePaychecks.isEmpty || remoteSettings != nil {
            PaydayWidgetRefresh.request()
        }
        PaydaySyncState.clearTipDeletions(pendingTipDeletions.keys, for: userID)
        PaydaySyncState.clearPaycheckDeletions(pendingPaycheckDeletions.keys, for: userID)

        let acknowledgedTips = try context.fetch(FetchDescriptor<TipEntry>())
            .map { RemoteTipEntry(entry: $0, userID: userID) }
        let acknowledgedPaychecks = try context.fetch(FetchDescriptor<PaycheckRecord>())
            .map { RemotePaycheckRecord(record: $0, userID: userID) }
        let tipCursor = PaydaySyncState.ServerCursor.advanced(
            from: checkpoint.tipServerCursor ?? .beginning,
            candidates: tipCursorRows.map { ($0.serverUpdatedAt, $0.id) }
        )
        let paycheckCursor = PaydaySyncState.ServerCursor.advanced(
            from: checkpoint.paycheckServerCursor ?? .beginning,
            candidates: paycheckCursorRows.map { ($0.serverUpdatedAt, $0.id) }
        )
        guard let tipCursor, let paycheckCursor else {
            throw PaydayMigrationError.invalidRemoteData
        }
        let settingsServerUpdatedAt = remoteSettings?.serverUpdatedAt
            ?? checkpoint.settingsServerUpdatedAt
        guard let settingsServerUpdatedAt,
              PaydayRemoteDate.parseInstant(settingsServerUpdatedAt) != nil else {
            throw PaydayMigrationError.invalidRemoteData
        }
        PaydaySyncState.save(
            userID: userID,
            tipEntryIDs: Set(acknowledgedTips.map(\.id)),
            paycheckIDs: Set(acknowledgedPaychecks.map(\.id)),
            migrationVerified: true,
            tipClientUpdatedAt: PaydaySyncState.acknowledgedVersions(
                current: Dictionary(uniqueKeysWithValues: acknowledgedTips.map {
                    ($0.id, $0.clientUpdatedAt)
                }),
                checkpoint: checkpoint.tipClientUpdatedAt,
                changedDuringSync: tipsChangedDuringSync
            ),
            paycheckClientUpdatedAt: PaydaySyncState.acknowledgedVersions(
                current: Dictionary(uniqueKeysWithValues: acknowledgedPaychecks.map {
                    ($0.id, $0.clientUpdatedAt)
                }),
                checkpoint: checkpoint.paycheckClientUpdatedAt,
                changedDuringSync: paychecksChangedDuringSync
            ),
            settingsClientUpdatedAt: remoteSettings?.clientUpdatedAt
                ?? checkpoint.settingsClientUpdatedAt,
            tipServerCursor: tipCursor,
            paycheckServerCursor: paycheckCursor,
            settingsServerUpdatedAt: settingsServerUpdatedAt
        )
        return PaydaySyncOutcome(
            report: try Self.cachedReport(context: context, userID: userID),
            requiresFollowUpSync: !tipsChangedDuringSync.isEmpty
                || !paychecksChangedDuringSync.isEmpty
                || settingsChangedDuringSync
        )
    }

    static func reconcile(
        snapshot: PaydayRemoteSnapshot,
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        forceRemoteRows: Bool = false,
        forceRemoteSettings: Bool = false
    ) throws -> (tipIDs: Set<UUID>, paycheckIDs: Set<UUID>) {
        let tipIDs = try reconcileTips(snapshot.tips, in: context, forceRemote: forceRemoteRows)
        let paycheckIDs = try reconcilePaychecks(snapshot.paychecks, in: context, forceRemote: forceRemoteRows)
        apply(
            snapshot.settings,
            scheduleStore: scheduleStore,
            preferencesStore: preferencesStore,
            moveLedgerStore: moveLedgerStore,
            force: forceRemoteSettings
        )
        try context.save()
        return (tipIDs, paycheckIDs)
    }

    private static func verifyServerContainsLocalSnapshot(
        localTipIDs: Set<UUID>,
        localPaycheckIDs: Set<UUID>,
        snapshot: PaydayRemoteSnapshot
    ) throws {
        let remoteTipIDs = Set(snapshot.tips.map(\.id))
        let remotePaycheckIDs = Set(snapshot.paychecks.map(\.id))
        guard localTipIDs.isSubset(of: remoteTipIDs) else { throw PaydayMigrationError.tipEntryMismatch }
        guard localPaycheckIDs.isSubset(of: remotePaycheckIDs) else { throw PaydayMigrationError.paycheckMismatch }
    }

    private static func verifyServerContainsChangedRows(
        changedTipIDs: Set<UUID>,
        changedPaycheckIDs: Set<UUID>,
        confirmedTips: [RemoteTipEntry],
        confirmedPaychecks: [RemotePaycheckRecord]
    ) throws {
        guard changedTipIDs.isSubset(of: Set(confirmedTips.map(\.id))) else {
            throw PaydayMigrationError.tipEntryMismatch
        }
        guard changedPaycheckIDs.isSubset(of: Set(confirmedPaychecks.map(\.id))) else {
            throw PaydayMigrationError.paycheckMismatch
        }
    }

    private static func merged<Row>(
        _ changed: [Row],
        _ confirmed: [Row],
        id: KeyPath<Row, UUID>
    ) -> [Row] {
        var rows: [UUID: Row] = [:]
        for row in changed { rows[row[keyPath: id]] = row }
        for row in confirmed { rows[row[keyPath: id]] = row }
        return Array(rows.values)
    }

    static func reconcileTips(
        _ rows: [RemoteTipEntry],
        in context: ModelContext,
        localVersionsAtStart: [UUID: String]? = nil,
        locallyDeletedDuringSync: Set<UUID> = [],
        forceRemote: Bool = false
    ) throws -> Set<UUID> {
        let local = try context.fetch(FetchDescriptor<TipEntry>())
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var activeIDs: Set<UUID> = []
        for row in rows {
            guard !locallyDeletedDuringSync.contains(row.id) else { continue }
            guard let modifiedAt = PaydayRemoteDate.parseInstant(row.clientUpdatedAt) else {
                throw PaydayMigrationError.invalidRemoteData
            }
            if let entry = byID[row.id] {
                if let localVersionsAtStart {
                    // A row fetched after this sync's upload/readback is the
                    // canonical server result, regardless of device clock.
                    // Preserve only a genuine edit made while network work
                    // was suspended.
                    if PaydaySyncState.localRowChangedDuringSync(
                        id: row.id,
                        currentClientUpdatedAt: PaydayRemoteDate.instant(entry.modifiedAt),
                        capturedClientUpdatedAt: localVersionsAtStart
                    ) {
                        activeIDs.insert(row.id)
                        continue
                    }
                } else if !forceRemote, entry.modifiedAt > modifiedAt {
                    activeIDs.insert(row.id)
                    continue
                }
            }
            if row.deletedAt != nil {
                if let entry = byID.removeValue(forKey: row.id) { context.delete(entry) }
                continue
            }
            if localVersionsAtStart == nil,
               let entry = byID[row.id], entry.modifiedAt == modifiedAt {
                activeIDs.insert(row.id)
                continue
            }
            guard let date = PaydayRemoteDate.parseDay(row.workDate),
                  let kind = TipKind(rawValue: row.kind)
            else { throw PaydayMigrationError.invalidRemoteData }
            let entry: TipEntry
            if let existing = byID[row.id] {
                entry = existing
            } else {
                entry = TipEntry(id: row.id, date: date, amountCents: row.amountCents, kind: kind)
                context.insert(entry)
                byID[row.id] = entry
            }
            entry.date = date
            entry.amountCents = row.amountCents
            entry.kind = kind
            entry.note = row.note
            entry.recordedAt = row.recordedAt.flatMap(PaydayRemoteDate.parseInstant)
            entry.isDouble = row.isDouble
            entry.hoursWorked = row.hoursWorked
            entry.tipOutCents = row.tipOutCents
            entry.salesCents = row.salesCents
            entry.shiftPeriod = row.shiftPeriod.flatMap(ShiftPeriod.init(rawValue:))
            entry.shiftID = row.shiftID
            entry.clockIn = row.clockIn.flatMap(PaydayRemoteDate.parseInstant)
            entry.clockOut = row.clockOut.flatMap(PaydayRemoteDate.parseInstant)
            entry.serverCount = row.serverCount
            entry.receiptMetrics = row.receiptMetrics
            entry.modifiedAt = modifiedAt
            activeIDs.insert(row.id)
        }
        return activeIDs
    }

    static func reconcilePaychecks(
        _ rows: [RemotePaycheckRecord],
        in context: ModelContext,
        localVersionsAtStart: [UUID: String]? = nil,
        locallyDeletedDuringSync: Set<UUID> = [],
        forceRemote: Bool = false
    ) throws -> Set<UUID> {
        let local = try context.fetch(FetchDescriptor<PaycheckRecord>())
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var activeIDs: Set<UUID> = []
        for row in rows {
            guard !locallyDeletedDuringSync.contains(row.id) else { continue }
            guard let modifiedAt = PaydayRemoteDate.parseInstant(row.clientUpdatedAt) else {
                throw PaydayMigrationError.invalidRemoteData
            }
            if let record = byID[row.id] {
                if let localVersionsAtStart {
                    if PaydaySyncState.localRowChangedDuringSync(
                        id: row.id,
                        currentClientUpdatedAt: PaydayRemoteDate.instant(record.modifiedAt),
                        capturedClientUpdatedAt: localVersionsAtStart
                    ) {
                        activeIDs.insert(row.id)
                        continue
                    }
                } else if !forceRemote, record.modifiedAt > modifiedAt {
                    activeIDs.insert(row.id)
                    continue
                }
            }
            if row.deletedAt != nil {
                if let record = byID.removeValue(forKey: row.id) { context.delete(record) }
                continue
            }
            if localVersionsAtStart == nil,
               let record = byID[row.id], record.modifiedAt == modifiedAt {
                activeIDs.insert(row.id)
                continue
            }
            guard let start = PaydayRemoteDate.parseDay(row.periodStart),
                  let end = PaydayRemoteDate.parseDay(row.periodEnd)
            else { throw PaydayMigrationError.invalidRemoteData }
            let record: PaycheckRecord
            if let existing = byID[row.id] {
                record = existing
            } else {
                record = PaycheckRecord(id: row.id, periodStart: start, periodEnd: end, paidTipsCents: row.paidTipsCents)
                context.insert(record)
                byID[row.id] = record
            }
            record.periodStart = start
            record.periodEnd = end
            record.paidTipsCents = row.paidTipsCents
            record.note = row.note
            record.hourlyRateCents = row.hourlyRateCents
            record.owedTipsCents = row.owedTipsCents
            record.grossPayCents = row.grossPayCents
            record.netPayCents = row.netPayCents
            record.regularWagesCents = row.regularWagesCents
            record.overtimeWagesCents = row.overtimeWagesCents
            record.gratuityCents = row.gratuityCents
            record.taxesCents = row.taxesCents
            record.modifiedAt = modifiedAt
            activeIDs.insert(row.id)
        }
        return activeIDs
    }

    private static func apply(
        _ settings: RemoteUserSettings,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        force: Bool = false
    ) {
        guard let timestamp = PaydayRemoteDate.parseInstant(settings.clientUpdatedAt),
              force || PaydaySettingsSyncClock.modifiedAt < timestamp
        else { return }
        preferencesStore.firstName = settings.firstName
        preferencesStore.baseHourlyWageCents = settings.baseHourlyWageCents
        preferencesStore.isSmartNudgeEnabled = settings.smartNudgeEnabled
        preferencesStore.isPaydayReminderEnabled = settings.paydayReminderEnabled
        if let frequencyRaw = settings.payFrequency,
           let frequency = PayFrequency(rawValue: frequencyRaw),
           let anchorRaw = settings.anchorPeriodEnd,
           let anchor = PaydayRemoteDate.parseDay(anchorRaw) {
            scheduleStore.schedule = PaySchedule(
                frequency: frequency,
                anchorPeriodEnd: anchor,
                payDelayDays: settings.payDelayDays,
                firstWeekday: settings.firstWeekday
            )
        } else {
            scheduleStore.schedule = nil
        }
        moveLedgerStore.replaceFromSupabase(settings.moveLedger.compactMapValues(PaydayRemoteDate.parseInstant))
        PaydaySettingsSyncClock.acceptRemoteTimestamp(timestamp)
    }

    private static func report(snapshot: PaydayRemoteSnapshot) throws -> PaydayMigrationReport {
        let tips = snapshot.tips.filter { $0.deletedAt == nil }.map(\.businessValue).sorted { $0.id.uuidString < $1.id.uuidString }
        let paychecks = snapshot.paychecks.filter { $0.deletedAt == nil }.map(\.businessValue).sorted { $0.id.uuidString < $1.id.uuidString }
        return PaydayMigrationReport(
            localTipEntryCount: tips.count,
            localPaycheckCount: paychecks.count,
            remoteTipEntryCount: tips.count,
            remotePaycheckCount: paychecks.count,
            tipEntryHash: try PaydayMigrationHash.value(tips),
            paycheckHash: try PaydayMigrationHash.value(paychecks)
        )
    }
}
