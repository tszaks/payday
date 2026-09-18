# P0, LIVE IN SHIPPED PAYDAY: an edit to an existing shift or paycheck never reaches the server

Found incidentally while implementing PR 2 slice S1. Independently confirmed twice: by a
standalone SwiftData probe, and by reading the shipped chain end to end. NOT a PaydayCore bug.

## The chain, every link verified in the shipped code on production

1. `TipEntry.modifiedAt` (Payday/Models/TipEntry.swift:53) is a plain stored property. It is
   stamped in `init` (:188) and otherwise ONLY by `didSet { modifiedAt = .now }` observers on the
   other fifteen properties (:48, :49, :54, :59, :64, :70, :78, :92, :99, :104, :113, :114, :123,
   :128, :152). `PaycheckRecord` uses the identical pattern.
2. **`didSet` never fires on a SwiftData `@Model` property.** Measured on a real store, four ways:
   a managed object edited and saved, a note edited and saved, an object never inserted, and an
   object refetched from disk. Every case: `modifiedAt` delta exactly `0.0`, observer calls `0`.
   The macro replaces the stored property with accessors, so the observer is dead code.
3. `RemoteTipEntry.init` sets `clientUpdatedAt = PaydayRemoteDate.instant(entry.modifiedAt)`
   (PaydayRemoteModels.swift:105); `RemotePaycheckRecord` the same at :206.
4. The upload set is `changedIDs(current:acknowledged:)`, which returns only ids whose version
   differs from the acknowledged version (PaydaySyncState.swift:204-211), where the version IS
   `clientUpdatedAt` (PaydaySyncService.swift:289, :294).
5. `changedTips = localTips.filter { changedTipIDs.contains($0.id) }` (:302) is what
   `repository.upsertTips(changedTips)` uploads (:321).

Therefore: once a row has been acknowledged by the server, editing it locally does not move its
`modifiedAt`, so its version still equals the acknowledged version, so it is excluded from the
upload set forever. The server's own gate is `excluded.client_updated_at >= existing` (the
preserve_hours_precision migration :140), so the write would have been accepted; nothing rejects
it, the client simply never sends it.

## What it costs Tyler, concretely

- Correcting a shift's tips, hours, tip-out, sales, note, times or receipt on one device never
  reaches the server, so no other device ever sees the correction.
- On reinstall or any cache rebuild, the baseline pull restores the server's stale row and the
  correction is gone for good.
- The agent API and any other device keep reading the pre-edit numbers indefinitely.
- INSERTS are safe (a fresh row carries a fresh `init` stamp). DELETES are safe (they go through
  the pending-deletion queue, PaydaySyncService.swift:306, not through `changedIDs`).
  So the damage is silent and specific to corrections, which is the worst shape: the user believes
  the app accepted the fix, and it did, locally.

## Fix, two parts, because one of them is a promise nobody can keep

(a) Stamp the clock explicitly at every mutation site so the uploaded `client_updated_at` actually
    advances: an explicit `touch()` on the model, called by the write paths (ShiftWriter,
    ShiftDetails.write, LogTipSheet save and live-edit, BackfillSheet, LogTipsIntent, the receipt
    and paycheck apply paths, DebugSeeder). Delete the dead `didSet` observers in the same change
    so nobody trusts them again.
(b) Do not let local change detection depend on anyone remembering (a). Make the version a content
    fingerprint of the row's synced fields rather than a timestamp, compared against the
    acknowledged fingerprint. A missed `touch()` then costs nothing. `client_updated_at` stays a
    real timestamp for the server's conflict gate.

Regression tests: `anEditedTipIsInTheUploadSet`, `anEditedPaycheckIsInTheUploadSet`,
`aMissedTouchStillUploadsBecauseTheFingerprintChanged`, and a characterization test
`didSetOnAModelPropertyNeverFires` so the pattern is never reintroduced.

Also fixed by (a)+(b), from the PR 2 design's own section 6.4: its safety argument assumed
`MigrationRunner` steps 1 and 2 bump `modifiedAt` and therefore push the backfilled `shift_id` to
the server. They do not, so that argument is void until this lands, and two of its tests would
pass vacuously.
