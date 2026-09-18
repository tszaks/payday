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
    private let shiftColumns = "id,user_id,work_date,shift_period,cash_tips_cents,credit_tips_cents,tip_out_cents,sales_cents,hours_worked,clock_in,clock_out,server_count,receipt_metrics,note,recorded_at,client_updated_at,source,legacy_entry_ids,native_modified_at,deleted_at,deleted_reason,gratuity_fees_cents,non_wage_earnings_cents,version,updated_at"

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

    /// Every tip and paycheck row the account has, tombstones included, with
    /// no settings read. Split out of `fetchSnapshot` for the one-time
    /// fingerprint seeding, which needs server CONTENT and must not fail on
    /// an account whose `user_settings` row is somehow absent — that read is
    /// `.single()` and would throw.
    func fetchAllRows(userID: UUID) async throws -> (tips: [RemoteTipEntry], paychecks: [RemotePaycheckRecord]) {
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
        // A row updated while a long baseline is paging can legitimately
        // appear once at its old position and again at its newer server
        // timestamp. Keep the last (newest) occurrence so migration counts
        // and hashes describe one canonical row per UUID.
        return (deduplicated(tipRows, id: \.id), deduplicated(paycheckRows, id: \.id))
    }

    func fetchSnapshot(userID: UUID) async throws -> PaydayRemoteSnapshot {
        let rows = try await fetchAllRows(userID: userID)
        let settings: RemoteUserSettings = try await client
            .from("user_settings")
            .select(settingsColumns)
            .eq("user_id", value: userID)
            .single()
            .execute()
            .value
        return PaydayRemoteSnapshot(tips: rows.tips, paychecks: rows.paychecks, settings: settings)
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

    // MARK: - Shifts (PR 2 slice S6)

    /// Writes shifts and RETURNS what the server did with each one.
    ///
    /// Unlike `upsertTips`, the result is not discarded, and that is the point
    /// of the RPC returning outcomes at all. `public.upsert_shifts` is total
    /// over arbitrary JSON: a row with money the column cannot hold, or no
    /// readable id or work date, comes back `invalid` while its batch mates are
    /// stored. A caller that threw the outcomes away would mark those rows
    /// synced and never retry them, which is the silent loss the outcome shape
    /// exists to prevent.
    ///
    /// `storedClientUpdatedAt` is likewise not decoration. The server clamps a
    /// future-dated `client_updated_at` to its own clock rather than gating on
    /// it, so the value the client must record is the one that came back, not
    /// the one it sent.
    @discardableResult
    func upsertShifts(_ rows: [RemoteShift]) async throws -> [ShiftWriteOutcome] {
        try await sendReturning(rows, function: "upsert_shifts")
    }

    /// The account's conversion record, or nil when the account has none.
    ///
    /// Nil is the ordinary case, not an error: `shift_migration_state` has a
    /// row only once the server has run a conversion for that account, so
    /// every account today reads nil. `ShiftReadAuthority.State()` with all
    /// four fields absent is correctly non-authoritative, so the caller can
    /// treat nil as "not converted" without a special case.
    ///
    /// NOT `.single()`. That throws when no row exists, which would turn the
    /// ordinary case into a sync failure -- the same trap
    /// `fetchAllRows`' header records for the `user_settings` read.
    func fetchShiftMigrationState(userID: UUID) async throws -> RemoteShiftMigrationState? {
        let rows: [RemoteShiftMigrationState] = try await client
            .from("shift_migration_state")
            .select(RemoteShiftMigrationState.columns)
            .eq("user_id", value: userID)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Tombstones shifts. The server stores the EARLIEST of the requested and
    /// the already-stored tombstone, so a replayed delete is a true no-op and
    /// a clock-skewed device cannot park a tombstone in the future.
    @discardableResult
    func softDeleteShifts(_ pending: [UUID: Date]) async throws -> [ShiftLifecycleOutcome] {
        var outcomes: [ShiftLifecycleOutcome] = []
        let groups = Dictionary(grouping: pending, by: \.value)
        for (date, rows) in groups {
            let values = rows.map(\.key)
            for start in stride(from: 0, to: values.count, by: batchSize) {
                let end = min(start + batchSize, values.count)
                let page: [ShiftLifecycleOutcome] = try await client
                    .rpc(
                        "soft_delete_shifts",
                        params: PaydayRPCPayload(
                            pRows: Array(values[start..<end]).map {
                                ShiftDeletionRow(id: $0, deletedAt: PaydayRemoteDate.instant(date))
                            }
                        )
                    )
                    .execute()
                    .value
                outcomes.append(contentsOf: page)
            }
        }
        return outcomes
    }

    /// Undo of a USER deletion. A `'converted'` tombstone comes back
    /// `refused`: it belongs to the fold's own un-delete arm, and reopening it
    /// here would resurrect a shift whose legacy source rows are gone.
    @discardableResult
    func restoreShifts(_ ids: [UUID]) async throws -> [ShiftLifecycleOutcome] {
        guard !ids.isEmpty else { return [] }
        var outcomes: [ShiftLifecycleOutcome] = []
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let end = min(start + batchSize, ids.count)
            let page: [ShiftLifecycleOutcome] = try await client
                .rpc("restore_shifts", params: PaydayRestoreParameters(ids: Array(ids[start..<end])))
                .execute()
                .value
            outcomes.append(contentsOf: page)
        }
        return outcomes
    }

    /// Shifts changed since `cursor`, on the same `(updated_at, id)` keyset the
    /// tip leg uses.
    ///
    /// Deliberately no `serverNow` watermark, though the slice's plan named
    /// one. A `statement_timestamp()` read in a SEPARATE statement from the
    /// page is not a safe fence: a transaction can commit with an `updated_at`
    /// earlier than that timestamp and still become visible only after the
    /// page was read, so a client that advanced a time watermark would skip
    /// those rows for good. That is exactly why Design 3's watermark is a
    /// server-issued monotonic `dataset_revision` and not a clock, and it
    /// lands with the snapshot work rather than being approximated here.
    /// Shifts changed since `cursor`, read through `fetch_shift_changes` so
    /// the page and the server's snapshot time arrive together.
    ///
    /// This replaces the plain table select S6 shipped. A keyset cursor over
    /// `updated_at` alone is not safe here: `updated_at` is the TRANSACTION
    /// timestamp and the fold runs at the end of a 1.0 build's batch, so a
    /// shift can be stamped seconds before it becomes visible, and a cursor
    /// that advanced past that stamp would filter the row out on every
    /// subsequent pass, forever, on every device. See `clampedShiftCursor`.
    ///
    /// Returns the MINIMUM `server_now` across the pages it read, not the
    /// last. Each page carries its own snapshot time and time moves forward,
    /// so the earliest one is the only value that is behind every row this
    /// call could have missed.
    func fetchShiftChanges(
        cursor: PaydaySyncState.ServerCursor?
    ) async throws -> (rows: [RemoteShift], serverNow: Date) {
        var collected: [RemoteShift] = []
        var earliestServerNow: Date?
        var after = cursor

        while true {
            let page: RemoteShiftPage = try await client
                .rpc("fetch_shift_changes", params: PaydayShiftFeedParameters(
                    afterUpdatedAt: after?.updatedAt,
                    afterID: after?.id,
                    limit: Self.shiftFeedPageSize
                ))
                .execute()
                .value

            guard let stamp = PaydayRemoteDate.parseInstant(page.serverNow) else {
                // Without a readable snapshot time there is no safe fence, and
                // advancing the cursor on a guess is the failure this whole
                // path exists to prevent. Refuse rather than proceed.
                throw PaydayMigrationError.invalidRemoteData
            }
            earliestServerNow = earliestServerNow.map { min($0, stamp) } ?? stamp

            collected.append(contentsOf: page.rows)
            guard page.rows.count == Self.shiftFeedPageSize,
                  let last = page.rows.last,
                  let lastUpdatedAt = last.serverUpdatedAt
            else { break }
            after = PaydaySyncState.ServerCursor(updatedAt: lastUpdatedAt, id: last.id)
        }

        guard let serverNow = earliestServerNow else {
            throw PaydayMigrationError.invalidRemoteData
        }
        return (deduplicated(collected, id: \.id), serverNow)
    }

    /// Every shift the account has, tombstones included, through the same
    /// fenced feed.
    func fetchShiftSnapshot() async throws -> (rows: [RemoteShift], serverNow: Date) {
        try await fetchShiftChanges(cursor: nil)
    }

    static let shiftFeedPageSize = 1_000

    func fetchShifts(userID: UUID, ids: Set<UUID>) async throws -> [RemoteShift] {
        try await fetchByIDs(table: "shifts", columns: shiftColumns, userID: userID, ids: ids)
    }

    /// `send`, but it decodes the RPC's returned rows instead of discarding
    /// them. Batching means a caller sees one flat list of outcomes across
    /// however many round trips the payload needed.
    private func sendReturning<T: Encodable, R: Decodable>(
        _ rows: [T],
        function: String
    ) async throws -> [R] {
        guard !rows.isEmpty else { return [] }
        var outcomes: [R] = []
        for start in stride(from: 0, to: rows.count, by: batchSize) {
            let end = min(start + batchSize, rows.count)
            let page: [R] = try await client
                .rpc(function, params: PaydayRPCPayload(pRows: Array(rows[start..<end])))
                .execute()
                .value
            outcomes.append(contentsOf: page)
        }
        return outcomes
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
            paycheckHash: try PaydayMigrationHash.value(paychecks),
            // Built from the LOCAL store, which holds no conversion state.
            // `synchronize` overwrites this with the value the shift-authority
            // leg read; see its call site. Answering 0 here instead of nil
            // would hide the banner on every pass that took this path.
            conversionPending: nil
        )
    }

    func synchronize(
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore
    ) async throws -> PaydaySyncOutcome {
        let userID = try await client.auth.session.user.id
        let repository = PaydayRemoteRepository(client: client)
        let localTipEntries = try context.fetch(FetchDescriptor<TipEntry>())
        let localPaycheckRecords = try context.fetch(FetchDescriptor<PaycheckRecord>())
        let localTips = localTipEntries.map { RemoteTipEntry(entry: $0, userID: userID) }
        let localPaychecks = localPaycheckRecords.map { RemotePaycheckRecord(record: $0, userID: userID) }
        let localSettings = RemoteUserSettings(
            userID: userID,
            scheduleStore: scheduleStore,
            preferencesStore: preferencesStore,
            moveLedgerStore: moveLedgerStore,
            policyStore: policyStore
        )
        let checkpoint = PaydaySyncState.snapshot(for: userID)
        // Versions are content fingerprints, not clocks — see
        // PaydayRowFingerprint. A row whose fields changed is in the upload
        // set whether or not the write path remembered to touch() it.
        let localTipVersionsAtStart = try PaydayRowFingerprint.values(localTipEntries)
        let localPaycheckVersionsAtStart = try PaydayRowFingerprint.values(localPaycheckRecords)

        // One sync per install: a checkpoint written under the shipped
        // timestamp scheme has no fingerprints, so ask the server what it
        // actually holds and let that be what "acknowledged" means. Costs one
        // extra full read, once, and finds every correction the timestamp bug
        // dropped. Deliberately NOT reused as this sync's download baseline:
        // it was read before the upload, so reconciling against it could
        // revert a row this sync just sent.
        var acknowledgedTipVersions = checkpoint.tipContentFingerprint
        var acknowledgedPaycheckVersions = checkpoint.paycheckContentFingerprint
        if PaydaySyncState.requiresFingerprintSeeding(checkpoint: checkpoint) {
            let serverRows = try await repository.fetchAllRows(userID: userID)
            acknowledgedTipVersions = PaydaySyncState.seededVersions(
                local: localTipVersionsAtStart,
                localClientUpdatedAt: Dictionary(
                    uniqueKeysWithValues: localTips.map { ($0.id, $0.clientUpdatedAt) }
                ),
                serverRows: try serverRows.tips.map { try $0.seedingRow },
                pulledThrough: checkpoint.tipServerCursor
            )
            acknowledgedPaycheckVersions = PaydaySyncState.seededVersions(
                local: localPaycheckVersionsAtStart,
                localClientUpdatedAt: Dictionary(
                    uniqueKeysWithValues: localPaychecks.map { ($0.id, $0.clientUpdatedAt) }
                ),
                serverRows: try serverRows.paychecks.map { try $0.seedingRow },
                pulledThrough: checkpoint.paycheckServerCursor
            )
            Self.logger.notice(
                "Sync fingerprint seeding against server content, for rows already pulled. serverTips=\(serverRows.tips.count) serverPaychecks=\(serverRows.paychecks.count) seededTips=\(acknowledgedTipVersions.count) seededPaychecks=\(acknowledgedPaycheckVersions.count)"
            )
        }

        let changedTipIDs = PaydaySyncState.changedIDs(
            current: localTipVersionsAtStart,
            acknowledged: acknowledgedTipVersions
        )
        let changedPaycheckIDs = PaydaySyncState.changedIDs(
            current: localPaycheckVersionsAtStart,
            acknowledged: acknowledgedPaycheckVersions
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
        let settingsChanged = Self.settingsNeedUpload(
            checkpointSettingsClientUpdatedAt: checkpoint.settingsClientUpdatedAt,
            localSettingsClientUpdatedAt: localSettings.clientUpdatedAt,
            adoptedPoliciesAwaitingUpload: policyStore.adoptedPoliciesAwaitingUpload
        )
        if settingsChanged {
            try await repository.upsertSettings(localSettings)
            // Only after the write returned. A thrown upload leaves the flag
            // set, so the next sync tries again rather than dropping the
            // adoption on the floor.
            policyStore.acknowledgePolicyUpload()
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

        let tipVersionsBeforeReconcile = try PaydayRowFingerprint.values(
            try context.fetch(FetchDescriptor<TipEntry>())
        )
        let paycheckVersionsBeforeReconcile = try PaydayRowFingerprint.values(
            try context.fetch(FetchDescriptor<PaycheckRecord>())
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
                policyStore: policyStore,
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

        let reconciledTipEntries = try context.fetch(FetchDescriptor<TipEntry>())
        let reconciledPaycheckRecords = try context.fetch(FetchDescriptor<PaycheckRecord>())
        let acknowledgedTips = reconciledTipEntries.map { RemoteTipEntry(entry: $0, userID: userID) }
        let acknowledgedPaychecks = reconciledPaycheckRecords.map { RemotePaycheckRecord(record: $0, userID: userID) }
        let acknowledgedTipFingerprints = try PaydayRowFingerprint.values(reconciledTipEntries)
        let acknowledgedPaycheckFingerprints = try PaydayRowFingerprint.values(reconciledPaycheckRecords)
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
        // `mutate`, never a fresh Snapshot. Writing one here would erase every
        // field this block does not name -- which is all seven shift fields --
        // at the end of every pass.
        PaydaySyncState.mutate(userID: userID) { checkpointToWrite in
            checkpointToWrite.tipEntryIDs = Set(acknowledgedTips.map(\.id))
            checkpointToWrite.paycheckIDs = Set(acknowledgedPaychecks.map(\.id))
            checkpointToWrite.migrationVerified = true
            // Written for a possible rollback to the timestamp scheme only.
            // Change detection compares the fingerprints below.
            checkpointToWrite.tipClientUpdatedAt = PaydaySyncState.acknowledgedVersions(
                current: Dictionary(uniqueKeysWithValues: acknowledgedTips.map {
                    ($0.id, $0.clientUpdatedAt)
                }),
                checkpoint: checkpoint.tipClientUpdatedAt,
                changedDuringSync: tipsChangedDuringSync
            )
            checkpointToWrite.paycheckClientUpdatedAt = PaydaySyncState.acknowledgedVersions(
                current: Dictionary(uniqueKeysWithValues: acknowledgedPaychecks.map {
                    ($0.id, $0.clientUpdatedAt)
                }),
                checkpoint: checkpoint.paycheckClientUpdatedAt,
                changedDuringSync: paychecksChangedDuringSync
            )
            // The prior versions here are the ones this sync actually compared
            // against — the SEEDED map on a seeding sync — so a row edited
            // while the network work was suspended stays eligible for the next
            // upload instead of being acknowledged on the strength of a
            // checkpoint that never held a fingerprint for it.
            checkpointToWrite.tipContentFingerprint = PaydaySyncState.acknowledgedVersions(
                current: acknowledgedTipFingerprints,
                checkpoint: acknowledgedTipVersions,
                changedDuringSync: tipsChangedDuringSync
            )
            checkpointToWrite.paycheckContentFingerprint = PaydaySyncState.acknowledgedVersions(
                current: acknowledgedPaycheckFingerprints,
                checkpoint: acknowledgedPaycheckVersions,
                changedDuringSync: paychecksChangedDuringSync
            )
            checkpointToWrite.settingsClientUpdatedAt = remoteSettings?.clientUpdatedAt
                ?? checkpoint.settingsClientUpdatedAt
            checkpointToWrite.tipServerCursor = tipCursor
            checkpointToWrite.paycheckServerCursor = paycheckCursor
            checkpointToWrite.settingsServerUpdatedAt = settingsServerUpdatedAt
        }
        // The read-authority leg: the ONE caller of the ONE writer.
        //
        // Extracted to `applyShiftAuthorityLeg` so a test can drive the REAL
        // leg -- the absent-row skip, the swallowed throw, the deferral
        // mapping -- by supplying the fetch, without a Supabase session.
        // Asserting the wiring by reading the source proved the wiring
        // EXISTS; it could not prove a deferral actually produces a second
        // attempt that promotes, and this is the slice that makes the flip
        // live.
        let authority = await Self.applyShiftAuthorityLeg(userID: userID) {
            try await repository.fetchShiftMigrationState(userID: userID)
        }

        // The ONE place the conversion count enters the report, and therefore
        // the one place the banner gets a source. `cachedReport` builds from
        // the local store and cannot know it; this is the only code in the
        // app that has both the row and the report in scope.
        var report = try Self.cachedReport(context: context, userID: userID)
        report.conversionPending = authority.remainingGroupCount

        return PaydaySyncOutcome(
            report: report,
            requiresFollowUpSync: !tipsChangedDuringSync.isEmpty
                || !paychecksChangedDuringSync.isEmpty
                || settingsChangedDuringSync
                // THE LIVENESS REQUIREMENT. Nothing inside the deferral
                // re-arms it, so a caller treating `.deferPromotion` as a
                // no-op would strand the account on the legacy representation
                // for the rest of the session -- a guard against a
                // few-seconds straddle turned into an indefinite one. Asking
                // for a follow-up pass is what makes the deferral a DELAY
                // rather than a cancellation.
                || authority.deferred
        )
    }

    /// The read-authority decision for one sync pass. Returns whether the
    /// promotion was DEFERRED, which the caller maps onto
    /// `requiresFollowUpSync`.
    ///
    /// `fetch` is injected with the real repository call supplied at the one
    /// production call site, the same shape as `ShiftCommands.perform`'s
    /// `saving` and the earnings builders' `representation`. It exists so the
    /// behaviour below can be tested rather than grepped for.
    ///
    /// ## An absent row must NOT reach the predicate
    ///
    /// `resolve` returns `.demote` on the `currentlyAuthoritative` branch
    /// whenever `isAuthoritative` is false, and `isAuthoritative` opens with
    /// `guard migratedAt != nil`. So an EMPTY `State` demotes a converted
    /// account, and an earlier draft of this leg substituted exactly that for
    /// a missing row.
    ///
    /// "Missing row" is not a loud failure. RLS on this table is
    /// `for select ... using (auth.uid() = user_id)`, so a request that fails
    /// to authenticate as the owner yields ZERO ROWS rather than an error: an
    /// auth blip is indistinguishable from "never converted" at the call
    /// site, which is what makes a defensive `?? State()` look reasonable
    /// while being a representation flip on every blip.
    ///
    /// Skipping is correct rather than merely cautious because of two facts
    /// about how the server communicates, not because of caution:
    ///
    /// 1. Nothing in any migration deletes from `shift_migration_state`; it
    ///    is rollback\'s only anchor.
    /// 2. Withdrawal is signalled by SETTING a column (`rollback_at`,
    ///    `conservation_failed_at`), never by removing the row.
    ///
    /// So an absent row can never legitimately mean "withdrawn", and skipping
    /// it discards no real signal. This is the one place the demotion
    /// asymmetry cuts the wrong way: never deferring a demotion is right when
    /// the server has genuinely withdrawn, and exactly wrong when we merely
    /// failed to ask.
    ///
    /// A thrown read is swallowed for the same reason, and additionally
    /// because by this point in a pass the rows are reconciled and the
    /// checkpoint written -- throwing would discard a successful sync over a
    /// fact that is only ever an optimisation.
    ///
    /// ## What the liveness guarantee actually is
    ///
    /// Precisely: **a deferral requests a retry UNLESS the next read fails.**
    /// Not "a deferral always produces a retry".
    ///
    /// The `catch` returns false, so if a follow-up pass's own migration-state
    /// read fails, no further follow-up is requested and the deferred
    /// promotion waits for the next natural sync instead. That is benign --
    /// legacy is the safe fallback and the account simply stays there a while
    /// longer -- but it is a weaker guarantee than the unconditional one, and
    /// stating it unconditionally is how a caveat becomes a surprise.
    @MainActor
    /// What one pass of the leg learned. Two facts, because the row carries
    /// two and an earlier version returned only one.
    ///
    /// It returned `Bool` -- the deferral -- and DISCARDED
    /// `remaining_group_count`. That is the whole reason
    /// `PaydayMigrationReport.conversionPending` was never assigned anywhere
    /// in the app: the only code that read the column threw the number away
    /// one line after reading it, so the banner's producer had no source and
    /// `isConversionPending` was false for every account forever. The banner
    /// was fully built and fully tested and could not appear.
    ///
    /// A struct rather than a tuple so adding a third fact later cannot
    /// silently reorder the two that exist.
    struct ShiftAuthorityLegResult: Equatable {
        /// Whether a promotion was held back; the caller maps this onto
        /// `requiresFollowUpSync`.
        let deferred: Bool
        /// Legacy groups the server has not folded yet, or nil when this pass
        /// learned nothing -- an absent row, or a read that failed.
        ///
        /// **nil and 0 are different answers and the banner treats them the
        /// same way only by coincidence.** nil is "no information"; 0 is "the
        /// server says it is finished". Collapsing nil to 0 would be
        /// harmless here and wrong in the next reader, so the distinction is
        /// kept at the type.
        let remainingGroupCount: Int?

        static let unknown = ShiftAuthorityLegResult(deferred: false, remainingGroupCount: nil)
    }

    static func applyShiftAuthorityLeg(
        userID: UUID,
        fetch: () async throws -> RemoteShiftMigrationState?
    ) async -> ShiftAuthorityLegResult {
        do {
            guard let row = try await fetch() else { return .unknown }
            // `authorityState()` THROWS on a present-but-unparseable
            // timestamp rather than collapsing it to nil, so that lands in
            // the catch below and changes nothing. See its header: a parse
            // failure read as nil demotes a promoted account, and would do so
            // on every pass rather than transiently.
            let state = try row.authorityState()
            let outcome = PaydaySyncState.applyShiftAuthority(state, for: userID)
            return ShiftAuthorityLegResult(
                deferred: outcome == .deferPromotion,
                // Read from the PARSED state, not from `row`, so the count
                // and the authority decision can never come from different
                // readings of the same response.
                remainingGroupCount: state.remainingGroupCount
            )
        } catch {
            // Deliberately swallowed, and deliberately not `try?` at the call
            // site: design-lint rule 19 bans `try?` on write paths, and
            // spelling the catch out is what lets this comment exist.
            //
            // `.unknown` rather than a zero count: a failed read must not
            // announce "conversion finished" to the banner, for the same
            // reason it must not demote the representation.
            return .unknown
        }
    }

    static func reconcile(
        snapshot: PaydayRemoteSnapshot,
        context: ModelContext,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore,
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
            policyStore: policyStore,
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
                        currentVersion: try PaydayRowFingerprint.value(entry),
                        capturedVersions: localVersionsAtStart
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

    /// The shift half of `reconcileTips`, copied field for field rather than
    /// reinvented.
    ///
    /// The design is explicit that copying the shipped shapes is near-zero
    /// risk and inventing a rule is not, so `localVersionsAtStart`,
    /// `localRowChangedDuringSync` and the `locallyDeletedDuringSync` set
    /// difference are used verbatim. Two things differ, and only two:
    ///
    /// **No `forceRemote`.** There is no path on this leg that wants the
    /// server to win unconditionally.
    ///
    /// **`restoringIDs`.** A shift the user undid is queued for
    /// `restore_shifts` and has not been confirmed yet, so the server still
    /// holds it tombstoned. Applying that tombstone would delete the row the
    /// user just restored, which is the undo silently failing. Those ids are
    /// exempt from the deletion arm until the restore confirms.
    ///
    /// **`locallyChangedBeforeSync` exists because this leg pulls BEFORE it
    /// pushes**, and that inversion is safe only with this guard. The tip leg
    /// pushes first, so a pulled row is always the device's own echo. Pull
    /// first and a shift the user edited an hour ago, still unpushed, would be
    /// overwritten by whatever the server holds -- including a refold.
    ///
    /// The exclusion applies to PULL-sourced rows only, which is why the
    /// caller makes two calls rather than passing one merged set. Excluding
    /// those ids from the readback too would mean never adopting the server's
    /// canonical result for the rows this device just wrote -- a
    /// server-clamped `client_updated_at`, a sanitised receipt payload, or a
    /// refold -- while still acknowledging the local value, so the row would
    /// read clean forever after and the divergence would be permanent and
    /// unpushable.
    static func reconcileShifts(
        _ rows: [RemoteShift],
        in context: ModelContext,
        localVersionsAtStart: [UUID: String]? = nil,
        locallyDeletedDuringSync: Set<UUID> = [],
        locallyChangedBeforeSync: Set<UUID> = [],
        restoringIDs: Set<UUID> = []
    ) throws -> Set<UUID> {
        let local = try context.fetch(FetchDescriptor<ShiftRecord>())
        var byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var activeIDs: Set<UUID> = []
        for row in rows {
            guard !locallyDeletedDuringSync.contains(row.id) else { continue }
            // Unpushed local edits win over a pull, because the push has not
            // happened yet on this leg. Steps 7 and 9 settle them.
            guard !locallyChangedBeforeSync.contains(row.id) else {
                activeIDs.insert(row.id)
                continue
            }
            guard let modifiedAt = PaydayRemoteDate.parseInstant(row.clientUpdatedAt) else {
                throw PaydayMigrationError.invalidRemoteData
            }
            if let record = byID[row.id], let localVersionsAtStart {
                // A row fetched after this sync's upload and readback is the
                // canonical server result, regardless of device clock.
                // Preserve only a genuine edit made while network work was
                // suspended.
                if PaydaySyncState.localRowChangedDuringSync(
                    id: row.id,
                    currentVersion: try PaydayRowFingerprint.value(record),
                    capturedVersions: localVersionsAtStart
                ) {
                    activeIDs.insert(row.id)
                    continue
                }
            }
            if row.deletedAt != nil {
                // The undo has not been confirmed by the server yet, so its
                // tombstone is stale by construction. Deleting here would
                // undo the user's undo.
                guard !restoringIDs.contains(row.id) else {
                    activeIDs.insert(row.id)
                    continue
                }
                if let record = byID.removeValue(forKey: row.id) { context.delete(record) }
                continue
            }
            guard let workDate = PaydayRemoteDate.parseDay(row.workDate) else {
                throw PaydayMigrationError.invalidRemoteData
            }
            let record: ShiftRecord
            if let existing = byID[row.id] {
                record = existing
            } else {
                record = ShiftRecord(id: row.id, workDate: workDate)
                context.insert(record)
                byID[row.id] = record
            }
            record.workDate = workDate
            record.shiftPeriod = row.shiftPeriod.flatMap(ShiftPeriod.init(rawValue:))
            record.cashTipsCents = row.cashTipsCents
            record.creditTipsCents = row.creditTipsCents
            record.tipOutCents = row.tipOutCents
            record.salesCents = row.salesCents
            record.hoursWorked = row.hoursWorked
            record.clockIn = row.clockIn.flatMap(PaydayRemoteDate.parseInstant)
            record.clockOut = row.clockOut.flatMap(PaydayRemoteDate.parseInstant)
            record.serverCount = row.serverCount
            record.receiptMetrics = row.receiptMetrics
            record.note = row.note
            record.recordedAt = row.recordedAt.flatMap(PaydayRemoteDate.parseInstant)
            // Provenance is adopted from the server, never invented locally:
            // `source` plus `legacyEntryIDs` is the rollback query, and a
            // device that guessed either would make a conversion artifact
            // unfindable.
            if let source = row.source.flatMap(ShiftRecordSource.init(rawValue:)) {
                record.source = source
            }
            if let legacyEntryIDs = row.legacyEntryIDs {
                record.legacyEntryIDs = Set(legacyEntryIDs)
            }
            record.modifiedAt = modifiedAt
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
                        currentVersion: try PaydayRowFingerprint.value(record),
                        capturedVersions: localVersionsAtStart
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

    /// Whether this pass owes the server a `user_settings` write.
    ///
    /// Two independent reasons, and the second one is why this is a named
    /// function rather than one inline comparison:
    ///
    /// 1. **The settings clock moved.** `clientUpdatedAt` comes from
    ///    `PaydaySettingsSyncClock`, which only a user edit advances, so a
    ///    checkpoint that disagrees with it means there is a local edit to
    ///    push.
    /// 2. **An adoption is waiting.** `PolicyStore.runMigrationsIfNeeded`
    ///    deliberately does NOT touch that clock (a read-time bump would make
    ///    untouched local defaults look newer than another device's real
    ///    settings and clobber them), so reason 1 is blind to it. On an
    ///    already-synced Payday 1.0 device the clock was therefore unchanged,
    ///    `upsertSettings` was never called, and
    ///    `user_settings.compensation_policies` stayed NULL indefinitely —
    ///    the frozen payroll zone and rate history did not follow the user to
    ///    a new phone, which is the whole reason the column exists. The flag
    ///    forces exactly one write, with the clock left where it was.
    ///
    /// Leaving the clock alone is what keeps that forced write recoverable
    /// rather than destructive: it does not win a future conflict, and a
    /// device with a genuinely newer clock re-uploads on its next pass,
    /// because its own checkpoint will then disagree with the value this
    /// write left on the server.
    /// Takes the two timestamps rather than the whole checkpoint and settings
    /// row, so a test can state the already-synced case in one line instead
    /// of standing up four stores to build a `RemoteUserSettings`.
    nonisolated static func settingsNeedUpload(
        checkpointSettingsClientUpdatedAt: String?,
        localSettingsClientUpdatedAt: String,
        adoptedPoliciesAwaitingUpload: Bool
    ) -> Bool {
        checkpointSettingsClientUpdatedAt != localSettingsClientUpdatedAt
            || adoptedPoliciesAwaitingUpload
    }

    private static func apply(
        _ settings: RemoteUserSettings,
        scheduleStore: PayScheduleStore,
        preferencesStore: UserPreferencesStore,
        moveLedgerStore: MoveLedgerStore,
        policyStore: PolicyStore,
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
        // Compensation policies are the one setting this device must NOT
        // clear on the word of a row that has nothing to say about them.
        // Payday 1.0 is shipped and writes no `compensation_policies`, so a
        // newer row from an old build arrives with nil; treating that as "no
        // policies" would delete this device's rate history — the migration
        // flags are already set, so nothing would re-create it — and put
        // every wage back to `.rateNotSet`. An explicitly empty payload is a
        // real state (a user who cleared their wage on another device) but it
        // is indistinguishable from a freshly migrated device that has not
        // uploaded yet, so both nil and empty leave the local copy alone.
        if let remotePolicies = settings.compensationPolicies, !remotePolicies.isEmpty {
            policyStore.replaceFromSupabase(remotePolicies)
        }
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
            paycheckHash: try PaydayMigrationHash.value(paychecks),
            // A remote snapshot carries tips, paychecks and settings; the
            // conversion row is fetched on its own leg and is not in it.
            conversionPending: nil
        )
    }
}
