import Foundation
import SwiftData
import Testing
@testable import Payday

/// Counts `didSet` calls on a SwiftData `@Model` property. A global rather
/// than a stored property on the model itself: the macro rewrites stored
/// properties, and the point of the probe is to observe the macro's behavior
/// from outside it.
nonisolated(unsafe) var didSetProbeCallCount = 0

/// A minimal `@Model` built the same way `TipEntry` was: one property whose
/// `didSet` is supposed to stamp a mutation clock. Exists only so the
/// characterization test can prove that observer never runs.
@Model
final class DidSetProbeModel {
    var value: Int = 0 {
        didSet {
            didSetProbeCallCount += 1
            stampedAt = .now
        }
    }

    var stampedAt: Date = Date.now

    init(value: Int, stampedAt: Date) {
        self.value = value
        self.stampedAt = stampedAt
    }
}

/// The regression suite for the P0 "an edit never syncs" bug: a correction to
/// an already-acknowledged tip or paycheck must land in the delta upload set.
/// These tests drive the real change-detection path — `RemoteTipEntry` /
/// `RemotePaycheckRecord` version derivation, then
/// `PaydaySyncState.changedIDs` — rather than asserting on `modifiedAt`
/// directly, because the version is what `PaydaySyncService` actually
/// compares and uploads.
@MainActor
@Suite("Local edits reach the delta upload set")
struct SyncEditUploadTests {
    private static let userID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    /// A row the server accepted well before this edit. Stamped explicitly so
    /// the test measures change detection, not clock granularity.
    private static let acknowledgedStamp = Date(timeIntervalSince1970: 1_750_000_000)
    /// A work day stored the way the app really stores one: local midnight.
    /// The seeding tests need that, because seeding compares a locally derived
    /// version against the day string the SERVER holds, and those agree
    /// exactly for a local-midnight instant — see `PaydayRemoteDate.stableDay`.
    private static let storedWorkDay = Calendar.current.startOfDay(
        for: Date(timeIntervalSince1970: 1_749_000_000)
    )

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: TipEntry.self,
            PaycheckRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Exactly how `PaydaySyncService.synchronize` derives the version it
    /// compares against the checkpoint, and the version it writes back: the
    /// row's content fingerprint, not its clock.
    private func tipVersions(in context: ModelContext) throws -> [UUID: String] {
        try PaydayRowFingerprint.values(try context.fetch(FetchDescriptor<TipEntry>()))
    }

    private func paycheckVersions(in context: ModelContext) throws -> [UUID: String] {
        try PaydayRowFingerprint.values(try context.fetch(FetchDescriptor<PaycheckRecord>()))
    }

    @Test("an edited tip is in the upload set")
    func anEditedTipIsInTheUploadSet() throws {
        let context = try makeContext()
        let day = Date(timeIntervalSince1970: 1_749_000_000)
        let entry = TipEntry(
            date: day,
            amountCents: 8_000,
            kind: .credit,
            note: "as typed at the keypad",
            recordedAt: day,
            hoursWorked: 6,
            tipOutCents: 900,
            salesCents: 120_000,
            shiftPeriod: .dinner,
            shiftID: UUID()
        )
        context.insert(entry)
        entry.modifiedAt = Self.acknowledgedStamp
        try context.save()

        let acknowledged = try tipVersions(in: context)

        // The correction a real editor makes: LogTipSheet.commitLiveEdit's own
        // amount/note writes (:1509, :1521) followed by ShiftDetails.write
        // (:1527) for the shift-level fields.
        entry.amountCents = 9_150
        entry.note = "corrected from the printed slip"
        ShiftDetails.write(
            hoursWorked: 7.5,
            tipOutCents: 1_200,
            salesCents: 140_000,
            shiftPeriod: .lunch,
            clockIn: day,
            clockOut: day.addingTimeInterval(7.5 * 3_600),
            serverCount: 5,
            into: [entry]
        )
        try context.save()

        let current = try tipVersions(in: context)
        let changed = PaydaySyncState.changedIDs(current: current, acknowledged: acknowledged)

        #expect(entry.amountCents == 9_150)
        #expect(changed.contains(entry.id))
        // Part (a): the uploaded client_updated_at has to advance too. The
        // deployed upsert has no clock predicate to reject a stale one, but it
        // is what orders two writers, what the agent API reads, and what the
        // seeding uses to tell a local correction from someone else's newer
        // edit.
        #expect(entry.modifiedAt > Self.acknowledgedStamp)
        #expect(
            RemoteTipEntry(entry: entry, userID: Self.userID).clientUpdatedAt
                != PaydayRemoteDate.instant(Self.acknowledgedStamp)
        )
    }

    @Test("an edited paycheck is in the upload set")
    func anEditedPaycheckIsInTheUploadSet() throws {
        let context = try makeContext()
        let record = PaycheckRecord(
            periodStart: Date(timeIntervalSince1970: 1_748_000_000),
            periodEnd: Date(timeIntervalSince1970: 1_749_000_000),
            paidTipsCents: 41_200,
            note: "as scanned",
            grossPayCents: 98_000,
            netPayCents: 72_000,
            regularWagesCents: 40_000,
            overtimeWagesCents: 0,
            gratuityCents: 0,
            taxesCents: 26_000
        )
        context.insert(record)
        record.modifiedAt = Self.acknowledgedStamp
        try context.save()

        let acknowledged = try paycheckVersions(in: context)

        // PaycheckEntrySheet.save's existing-record branch, field writes then
        // the explicit touch() it now ends with.
        record.paidTipsCents = 43_775
        record.note = "corrected from the stub"
        record.grossPayCents = 100_575
        record.netPayCents = 74_100
        record.taxesCents = 26_475
        record.touch()
        try context.save()

        let current = try paycheckVersions(in: context)
        let changed = PaydaySyncState.changedIDs(current: current, acknowledged: acknowledged)

        #expect(record.paidTipsCents == 43_775)
        #expect(changed.contains(record.id))
        #expect(record.modifiedAt > Self.acknowledgedStamp)
    }

    /// The whole point of part (b). A write path that forgets `touch()` still
    /// uploads, because the version is derived from the values themselves.
    /// Nothing here calls `touch()`, and `modifiedAt` is asserted NOT to have
    /// moved, so the test fails if it starts passing for the wrong reason.
    @Test("a missed touch still uploads because the fingerprint changed")
    func aMissedTouchStillUploadsBecauseTheFingerprintChanged() throws {
        let context = try makeContext()
        let day = Date(timeIntervalSince1970: 1_749_000_000)
        let entry = TipEntry(date: day, amountCents: 8_000, kind: .credit, recordedAt: day)
        context.insert(entry)
        entry.modifiedAt = Self.acknowledgedStamp
        try context.save()

        let acknowledged = try tipVersions(in: context)

        entry.tipOutCents = 1_450
        try context.save()

        let changed = PaydaySyncState.changedIDs(
            current: try tipVersions(in: context),
            acknowledged: acknowledged
        )

        #expect(entry.modifiedAt == Self.acknowledgedStamp)
        #expect(changed.contains(entry.id))
    }

    /// The fix must not degenerate into "upload everything, always". An
    /// untouched row is not in the upload set, and neither is a row whose
    /// clock was bumped without any field changing — over-calling `touch()`
    /// has to stay free, or every write path gains a cost for being careful.
    @Test("an unchanged row is not in the upload set")
    func anUnchangedRowIsNotInTheUploadSet() throws {
        let context = try makeContext()
        let day = Date(timeIntervalSince1970: 1_749_000_000)
        let untouched = TipEntry(date: day, amountCents: 8_000, kind: .credit, recordedAt: day)
        let clockBumpedOnly = TipEntry(date: day, amountCents: 3_100, kind: .cash, recordedAt: day)
        context.insert(untouched)
        context.insert(clockBumpedOnly)
        untouched.modifiedAt = Self.acknowledgedStamp
        clockBumpedOnly.modifiedAt = Self.acknowledgedStamp
        try context.save()

        let acknowledged = try tipVersions(in: context)

        clockBumpedOnly.touch()
        try context.save()

        let changed = PaydaySyncState.changedIDs(
            current: try tipVersions(in: context),
            acknowledged: acknowledged
        )

        #expect(clockBumpedOnly.modifiedAt > Self.acknowledgedStamp)
        #expect(changed.isEmpty)
    }

    /// A calendar pinned to one zone, for building the local-midnight instants
    /// this app actually stores. Never `Calendar.current`: the point of these
    /// tests is that the wire value does not depend on where the device is.
    private func calendar(in identifier: String) throws -> Calendar {
        guard let zone = TimeZone(identifier: identifier) else {
            throw TimeZoneUnavailable(identifier: identifier)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private struct TimeZoneUnavailable: Error { let identifier: String }

    private func midnight(_ day: DateComponents, in identifier: String) throws -> Date {
        guard let date = try calendar(in: identifier).date(from: day) else {
            throw TimeZoneUnavailable(identifier: identifier)
        }
        return date
    }

    /// `work_date` is inside the content fingerprint, so the version's day has
    /// to be a pure function of the stored instant. Every date Payday stores
    /// is local midnight in the zone that wrote it; rendered through the
    /// device's CURRENT zone instead, the same instant reads as the previous
    /// day from anywhere further west, so every row in the history would
    /// fingerprint differently the first time Tyler flew — and upload, past a
    /// server upsert that has no clock predicate.
    ///
    /// Swept across the inhabited offset range rather than by mutating
    /// `NSTimeZone.default`: this suite runs in parallel with ~600 other tests
    /// that read `Calendar.current`, and the sweep is the stronger assertion
    /// anyway — it pins the output to one expected string instead of to
    /// agreement between two renders, so it fails on a regression no matter
    /// which zone the test process happens to be in.
    @Test("a stored work day versions to the same day from every time zone")
    func aStoredWorkDayVersionsToTheSameDayFromEveryTimeZone() throws {
        let workDay = DateComponents(year: 2026, month: 9, day: 5)
        let zones = [
            "Pacific/Apia",         // UTC+13 all year, the eastern edge
            "Pacific/Auckland",
            "Australia/Sydney",
            "Asia/Tokyo",
            "Asia/Kolkata",         // a half-hour offset
            "Europe/Berlin",
            "UTC",
            "America/New_York",
            "America/Los_Angeles",
            "Pacific/Honolulu"      // UTC-10, the western edge
        ]

        for zone in zones {
            let storedMidnight = try midnight(workDay, in: zone)
            #expect(
                PaydayRemoteDate.stableDay(storedMidnight) == "2026-09-05",
                "a shift logged in \(zone) must stay on its own work day"
            )
        }
    }

    /// The documented limit, asserted so it stays deliberate. No function of
    /// the stored instant can name the right day everywhere — midnight Sep 5
    /// in Kiritimati (UTC+14) and midnight Sep 4 in Honolulu (UTC-10) are the
    /// same instant — so `stableDay` covers a 24-hour window and names the
    /// adjacent day outside it. That is survivable only because the WIRE value
    /// is a separate render: the row uploads once with content identical to
    /// what the server holds, and never a shifted date.
    @Test("outside the covered offsets the version shifts but the wire date does not")
    func outsideTheCoveredOffsetsTheVersionShiftsButTheWireDateDoesNot() throws {
        let workDay = DateComponents(year: 2026, month: 9, day: 5)
        let inKiritimati = try midnight(workDay, in: "Pacific/Kiritimati")   // UTC+14
        let inPagoPago = try midnight(workDay, in: "Pacific/Pago_Pago")      // UTC-11

        #expect(PaydayRemoteDate.stableDay(inKiritimati) == "2026-09-04")
        #expect(PaydayRemoteDate.stableDay(inPagoPago) == "2026-09-06")

        // What actually reaches the server is unchanged from the shipped
        // build: the day the device's own calendar names.
        for zone in ["Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let calendar = try calendar(in: zone)
            let storedMidnight = try midnight(workDay, in: zone)
            #expect(PaydayRemoteDate.day(storedMidnight, calendar: calendar) == "2026-09-05")
        }
    }

    /// The consequence that matters: after a move, an untouched row is not in
    /// the upload set — while a real date correction still is.
    ///
    /// Each pair is one work day's midnight twice: as the row was written in
    /// the zone the device was in, and as `reconcileTips` re-parses
    /// `work_date` after the device has moved (PaydaySyncService.swift:670
    /// parses in the current calendar). The version must not tell those apart.
    /// New York to Los Angeles is the move Tyler would actually make; Apia to
    /// Honolulu spans 23 hours, so those two instants land on different days
    /// in every real calendar, which is what makes this test fail if the
    /// version ever goes back to rendering in `Calendar.current`.
    @Test("moving time zones leaves an untouched row out of the upload set")
    func movingTimeZonesLeavesAnUntouchedRowOutOfTheUploadSet() throws {
        let workDay = DateComponents(year: 2026, month: 9, day: 5)
        let priorDay = DateComponents(year: 2026, month: 9, day: 4)

        for move in [("America/New_York", "America/Los_Angeles"), ("Pacific/Apia", "Pacific/Honolulu")] {
            let context = try makeContext()
            let asWritten = try midnight(workDay, in: move.0)
            let asReparsed = try midnight(workDay, in: move.1)
            #expect(asWritten != asReparsed)
            #expect(PaydayRemoteDate.stableDay(asWritten) == "2026-09-05")
            #expect(PaydayRemoteDate.stableDay(asReparsed) == "2026-09-05")

            let entry = TipEntry(date: asWritten, amountCents: 8_000, kind: .credit, recordedAt: asWritten)
            let record = PaycheckRecord(
                periodStart: asWritten,
                periodEnd: asWritten.addingTimeInterval(13 * 86_400),
                paidTipsCents: 41_200
            )
            context.insert(entry)
            context.insert(record)
            entry.modifiedAt = Self.acknowledgedStamp
            record.modifiedAt = Self.acknowledgedStamp
            try context.save()

            let acknowledgedTips = try tipVersions(in: context)
            let acknowledgedPaychecks = try paycheckVersions(in: context)

            // The flight, and the delta pull that follows it.
            entry.date = asReparsed
            record.periodStart = asReparsed
            record.periodEnd = asReparsed.addingTimeInterval(13 * 86_400)
            try context.save()

            #expect(PaydaySyncState.changedIDs(
                current: try tipVersions(in: context),
                acknowledged: acknowledgedTips
            ).isEmpty, "a flight from \(move.0) to \(move.1) must not queue an untouched tip")
            #expect(PaydaySyncState.changedIDs(
                current: try paycheckVersions(in: context),
                acknowledged: acknowledgedPaychecks
            ).isEmpty, "a flight from \(move.0) to \(move.1) must not queue an untouched paycheck")

            // A genuine date correction is a different day, a full 24 hours
            // away, and still uploads.
            entry.date = try midnight(priorDay, in: move.1)
            entry.touch()
            try context.save()

            #expect(PaydaySyncState.changedIDs(
                current: try tipVersions(in: context),
                acknowledged: acknowledgedTips
            ) == [entry.id])
        }
    }

    /// Where the device's delta cursor stood, and the two server stamps that
    /// sit either side of it.
    private static let pulledThrough = PaydaySyncState.ServerCursor(
        updatedAt: "2026-09-10T00:00:00.000Z",
        id: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
    )
    private static let beforeTheCursor = "2026-09-05T00:00:00.000Z"
    private static let afterTheCursor = "2026-09-12T00:00:00.000Z"

    /// A server row exactly as `fetchAllRows` would hand it to the seeding:
    /// the content the server holds, plus the two clocks that say whether this
    /// device has read that content. Built from a real `RemoteTipEntry` so the
    /// fingerprint is the production digest, not a stand-in.
    private func serverRow(
        _ entry: TipEntry,
        serverUpdatedAt: String,
        clientUpdatedAt: String? = nil,
        isDeleted: Bool = false
    ) throws -> PaydaySyncState.SeedingServerRow {
        let remote = RemoteTipEntry(entry: entry, userID: Self.userID)
        return PaydaySyncState.SeedingServerRow(
            id: remote.id,
            contentFingerprint: try remote.contentFingerprint,
            clientUpdatedAt: clientUpdatedAt ?? remote.clientUpdatedAt,
            serverUpdatedAt: serverUpdatedAt,
            isDeleted: isDeleted
        )
    }

    /// The upgrade path, with four rows that disagree.
    ///
    /// An install carrying a checkpoint written under the shipped timestamp
    /// scheme has no fingerprint for any row, and the corrections the bug
    /// already dropped are indistinguishable locally — the local clock is
    /// stale on an edited row and on an untouched one alike. So the seeding
    /// sync asks the server what it holds and compares content.
    ///
    /// But "local differs from server" only means "unsent local correction"
    /// for a row this device has already pulled. For a row the server changed
    /// afterwards it means the opposite, and uploading the local side would
    /// destroy the newer edit for good, because the deployed upsert has no
    /// clock predicate. So exactly one of these four uploads.
    @Test("the first sync after upgrade uploads edited rows once and not the whole history")
    func theFirstSyncAfterUpgradeUploadsEditedRowsOnceAndNotTheWholeHistory() throws {
        let context = try makeContext()
        let day = Self.storedWorkDay
        let locallyEdited = TipEntry(date: day, amountCents: 8_000, kind: .credit, recordedAt: day)
        let newerOnServer = TipEntry(date: day, amountCents: 3_100, kind: .cash, recordedAt: day)
        let newerClientClock = TipEntry(date: day, amountCents: 4_200, kind: .credit, recordedAt: day)
        let untouched = TipEntry(
            date: day.addingTimeInterval(-86_400),
            amountCents: 5_500,
            kind: .credit,
            recordedAt: day.addingTimeInterval(-86_400)
        )
        let all = [locallyEdited, newerOnServer, newerClientClock, untouched]
        for entry in all {
            context.insert(entry)
            entry.modifiedAt = Self.acknowledgedStamp
        }
        try context.save()

        // Row 2's server copy: a correction another device already rescued and
        // wrote, after this device's last pull. Captured from the newer content
        // and then reverted locally, so local is genuinely the stale side.
        newerOnServer.amountCents = 3_575
        try context.save()
        let newerOnServerRow = try serverRow(newerOnServer, serverUpdatedAt: Self.afterTheCursor)
        newerOnServer.amountCents = 3_100
        try context.save()

        // Row 3's server copy: the agent API edited it (payday-api sets
        // client_updated_at = now()) and the row's server timestamp happens to
        // be no help — it sits at or before the cursor. Its content differs
        // from local exactly as row 1's does, so only the writer's clock
        // distinguishes the two.
        newerClientClock.amountCents = 4_777
        try context.save()
        let newerClientClockRow = try serverRow(
            newerClientClock,
            serverUpdatedAt: Self.beforeTheCursor,
            clientUpdatedAt: "2026-09-14T09:00:00.000Z"
        )
        newerClientClock.amountCents = 4_200
        try context.save()

        // What the server holds for the rest: each row as it was last
        // accepted, at or before the cursor this device pulled through.
        let serverRows = [
            try serverRow(locallyEdited, serverUpdatedAt: Self.beforeTheCursor),
            newerOnServerRow,
            newerClientClockRow,
            try serverRow(untouched, serverUpdatedAt: Self.beforeTheCursor)
        ]

        // The correction the shipped build saved locally and never sent. It
        // predates the upgrade, so it carries no fresh clock either.
        locallyEdited.amountCents = 9_150
        locallyEdited.tipOutCents = 1_200
        try context.save()

        let localRemote = try context.fetch(FetchDescriptor<TipEntry>())
            .map { RemoteTipEntry(entry: $0, userID: Self.userID) }
        let checkpoint = PaydaySyncState.Snapshot(
            tipEntryIDs: Set(all.map(\.id)),
            tipClientUpdatedAt: Dictionary(
                uniqueKeysWithValues: localRemote.map { ($0.id, $0.clientUpdatedAt) }
            ),
            versioningScheme: 0,
            tipServerCursor: Self.pulledThrough,
            paycheckServerCursor: Self.pulledThrough,
            settingsServerUpdatedAt: "2026-09-04T12:34:56.123Z"
        )
        #expect(PaydaySyncState.requiresFingerprintSeeding(checkpoint: checkpoint))

        let local = try tipVersions(in: context)
        let localClocks = Dictionary(
            uniqueKeysWithValues: localRemote.map { ($0.id, $0.clientUpdatedAt) }
        )
        let seeded = PaydaySyncState.seededVersions(
            local: local,
            localClientUpdatedAt: localClocks,
            serverRows: serverRows,
            pulledThrough: checkpoint.tipServerCursor
        )
        let firstUpload = PaydaySyncState.changedIDs(current: local, acknowledged: seeded)

        #expect(firstUpload == [locallyEdited.id])
        #expect(!firstUpload.contains(newerOnServer.id))
        #expect(!firstUpload.contains(newerClientClock.id))
        #expect(!firstUpload.contains(untouched.id))

        // Once, not forever: the checkpoint this sync writes records the
        // fingerprints, so the second sync uploads nothing and never seeds
        // again.
        let afterFirstSync = PaydaySyncState.Snapshot(
            tipEntryIDs: checkpoint.tipEntryIDs,
            tipContentFingerprint: PaydaySyncState.acknowledgedVersions(
                current: local,
                checkpoint: seeded,
                changedDuringSync: []
            ),
            tipServerCursor: Self.pulledThrough,
            paycheckServerCursor: Self.pulledThrough,
            settingsServerUpdatedAt: "2026-09-04T12:34:56.123Z"
        )

        #expect(!PaydaySyncState.requiresFingerprintSeeding(checkpoint: afterFirstSync))
        #expect(PaydaySyncState.changedIDs(
            current: try tipVersions(in: context),
            acknowledged: afterFirstSync.tipContentFingerprint
        ).isEmpty)
    }

    /// With no delta cursor to compare against, the seeding cannot prove it
    /// has read any server row, and this sync's download is a full baseline
    /// that will heal local anyway. So it uploads nothing rather than risk
    /// overwriting a newer server row it has never seen.
    @Test("the seeding uploads nothing when it cannot prove what the device has pulled")
    func theSeedingUploadsNothingWhenItCannotProveWhatTheDeviceHasPulled() throws {
        let context = try makeContext()
        let day = Self.storedWorkDay
        let entry = TipEntry(date: day, amountCents: 8_000, kind: .credit, recordedAt: day)
        context.insert(entry)
        entry.modifiedAt = Self.acknowledgedStamp
        try context.save()

        let serverRows = [try serverRow(entry, serverUpdatedAt: Self.beforeTheCursor)]
        entry.amountCents = 9_150
        try context.save()

        let local = try tipVersions(in: context)
        let seeded = PaydaySyncState.seededVersions(
            local: local,
            localClientUpdatedAt: [entry.id: PaydayRemoteDate.instant(Self.acknowledgedStamp)],
            serverRows: serverRows,
            pulledThrough: nil
        )

        #expect(PaydaySyncState.changedIDs(current: local, acknowledged: seeded).isEmpty)
    }

    /// The seeding read returns tombstones too. A row another device deleted
    /// must not be uploaded back to life by the one sync that compares against
    /// server content — the delta pull in that same sync is what applies the
    /// deletion.
    @Test("the seeding never resurrects a row another device deleted")
    func theSeedingNeverResurrectsARowAnotherDeviceDeleted() throws {
        let context = try makeContext()
        let day = Self.storedWorkDay
        let deletedElsewhere = TipEntry(date: day, amountCents: 8_000, kind: .credit, recordedAt: day)
        context.insert(deletedElsewhere)
        deletedElsewhere.modifiedAt = Self.acknowledgedStamp
        try context.save()

        // A tombstone the device HAS pulled through, and a local correction on
        // top of it, so nothing but the deletion itself keeps this row out of
        // the upload set.
        let tombstone = try serverRow(
            deletedElsewhere,
            serverUpdatedAt: Self.beforeTheCursor,
            isDeleted: true
        )
        deletedElsewhere.amountCents = 9_150
        try context.save()

        let local = try tipVersions(in: context)
        let seeded = PaydaySyncState.seededVersions(
            local: local,
            localClientUpdatedAt: [
                deletedElsewhere.id: PaydayRemoteDate.instant(Self.acknowledgedStamp)
            ],
            serverRows: [tombstone],
            pulledThrough: Self.pulledThrough
        )

        #expect(PaydaySyncState.changedIDs(current: local, acknowledged: seeded).isEmpty)
    }

    /// A checkpoint persisted by the shipped build has to keep decoding. It
    /// carries the pending-sync state — known ids, server cursors, settings
    /// watermark — and dropping it would force a full baseline and re-upload.
    /// Encoded through a mirror of the shipped field set, so this exercises
    /// the real on-disk shape rather than a hand-typed guess at it.
    @Test("an existing persisted checkpoint still decodes")
    func anExistingPersistedCheckpointStillDecodes() throws {
        /// The Snapshot as shipped: no fingerprints, no versioning scheme.
        struct ShippedSnapshot: Codable {
            var tipEntryIDs: Set<UUID>
            var paycheckIDs: Set<UUID>
            var migrationVerified: Bool
            var tipClientUpdatedAt: [UUID: String]
            var paycheckClientUpdatedAt: [UUID: String]
            var settingsClientUpdatedAt: String?
            var tipServerCursor: PaydaySyncState.ServerCursor?
            var paycheckServerCursor: PaydaySyncState.ServerCursor?
            var settingsServerUpdatedAt: String?
        }
        let tipID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let paycheckID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let cursor = PaydaySyncState.ServerCursor(
            updatedAt: "2026-09-04T12:34:56.123Z",
            id: tipID
        )
        let data = try JSONEncoder().encode(ShippedSnapshot(
            tipEntryIDs: [tipID],
            paycheckIDs: [paycheckID],
            migrationVerified: true,
            tipClientUpdatedAt: [tipID: "2026-09-01T00:00:00.000Z"],
            paycheckClientUpdatedAt: [paycheckID: "2026-09-02T00:00:00.000Z"],
            settingsClientUpdatedAt: "2026-09-03T00:00:00.000Z",
            tipServerCursor: cursor,
            paycheckServerCursor: cursor,
            settingsServerUpdatedAt: "2026-09-04T12:34:56.123Z"
        ))

        let decoded = try JSONDecoder().decode(PaydaySyncState.Snapshot.self, from: data)

        #expect(decoded.tipEntryIDs == [tipID])
        #expect(decoded.paycheckIDs == [paycheckID])
        #expect(decoded.migrationVerified)
        #expect(decoded.tipClientUpdatedAt[tipID] == "2026-09-01T00:00:00.000Z")
        #expect(decoded.paycheckClientUpdatedAt[paycheckID] == "2026-09-02T00:00:00.000Z")
        #expect(decoded.settingsClientUpdatedAt == "2026-09-03T00:00:00.000Z")
        #expect(decoded.tipServerCursor == cursor)
        #expect(decoded.paycheckServerCursor == cursor)
        #expect(decoded.settingsServerUpdatedAt == "2026-09-04T12:34:56.123Z")
        // Absent, not defaulted to the current scheme: an old checkpoint must
        // announce itself as old so the seeding runs exactly once.
        #expect(decoded.tipContentFingerprint.isEmpty)
        #expect(decoded.paycheckContentFingerprint.isEmpty)
        #expect(decoded.versioningScheme == 0)
        #expect(PaydaySyncState.requiresFingerprintSeeding(checkpoint: decoded))
    }

    /// Characterization, not a wish: SwiftData's `@Model` macro replaces a
    /// stored property with computed accessors, so a `didSet` observer written
    /// on it is dead code. Asserting the observer does NOT fire keeps anyone
    /// from reintroducing the `didSet { modifiedAt = .now }` pattern in the
    /// belief that it works. If a future SwiftData starts calling it, this test
    /// fails loudly and the sync clock can be simplified on purpose.
    @Test("didSet never fires on a @Model property")
    func didSetOnAModelPropertyNeverFires() throws {
        let container = try ModelContainer(
            for: DidSetProbeModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        // Case 1: a managed, inserted, saved object.
        didSetProbeCallCount = 0
        let managed = DidSetProbeModel(value: 1, stampedAt: stamp)
        context.insert(managed)
        try context.save()
        managed.value = 2
        try context.save()

        #expect(managed.value == 2)
        #expect(didSetProbeCallCount == 0)
        #expect(managed.stampedAt == stamp)

        // Case 2: an object that was never inserted into a context.
        didSetProbeCallCount = 0
        let detached = DidSetProbeModel(value: 1, stampedAt: stamp)
        detached.value = 3

        #expect(detached.value == 3)
        #expect(didSetProbeCallCount == 0)
        #expect(detached.stampedAt == stamp)

        // Case 3: an object refetched from the store.
        didSetProbeCallCount = 0
        guard let refetched = try context.fetch(FetchDescriptor<DidSetProbeModel>()).first else {
            Issue.record("the saved probe row could not be refetched")
            return
        }
        refetched.value = 4
        try context.save()

        #expect(refetched.value == 4)
        #expect(didSetProbeCallCount == 0)
        #expect(refetched.stampedAt == stamp)
    }
}
