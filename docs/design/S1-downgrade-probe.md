# MEASURED 2026-09-17: the S1 downgrade probe (design section 13, S1 gate)

Question the design asked: does a 1.0 build (schema [TipEntry, PaycheckRecord]) still open an
App Group store that CONTAINS ShiftRecord rows, or does it fall back to in-memory and set
`openingFailed` (the "goes dark" premise that killed shape 2)?

Method: standalone SwiftPM executable, macOS, real SwiftData, three minimal @Model types
standing in for the shapes that matter. /tmp/sd-probe. Same store file throughout.

## Result: the app does NOT go dark, but the downgrade SILENTLY DESTROYS every ShiftRecord.

```
STEP 1 new-build schema [Tip, Paycheck, Shift]: wrote 3 rows OK
CoreData: error: Persistent History (1) has to be truncated due to the following entities
          being removed: ( Shift )
CoreData: warning: Dropping Indexes for Persistent History
CoreData: warning: Dropping Transactions prior to 1 for Persistent History
STEP 2 old 1.0 schema [Tip, Paycheck] on a store containing Shift: OPENED. tips=1 paychecks=1
STEP 3 old schema wrote a new Tip: OK, tips now 2
STEP 4 back on the new schema: shifts=0 cash=-1 tips=2
```

Two facts, both load-bearing:
1. **Opening succeeds.** No throw, no in-memory fallback, no `openingFailed`. Shape 3 does not
   die on downgrade the way shape 2 died on lockout.
2. **The dropped entity's rows are gone for good.** `shifts=0` after re-upgrading. TipEntry and
   PaycheckRecord rows survive intact (tips 1 -> 2 -> 2), so only the omitted entity is purged.

## Mandatory design consequence (not optional, not a Tyler decision)

Downgrade is an ordinary path: TestFlight lets you install an older build, a second device may
lag, a restore can land an old binary. So a PR 2 device can legitimately find itself with a full
TipEntry history and ZERO ShiftRecords, through no sync event.

Shape 3's core rule is that the device NEVER derives a shift; only the server does. Therefore the
recovery MUST be a forced baseline re-pull, and the shift checkpoint cannot be trusted to notice,
because from its point of view the account is already fully synced.

Required, to be built in S1 and S7 (sync):
- On container open, if the account is marked converted (server audit row seen) and the local
  ShiftRecord count is 0 while TipEntry rows exist, treat it as a wiped cache: clear the shift
  cursor and `shiftServerAckedIDs`, and force a baseline shift pull before any screen reads.
- The reader must stay on the strictly sequential legacy projection until that baseline lands, so
  no screen shows $0 for a month the user actually worked.
- Test: `aDowngradeThatPurgesShiftRecordsForcesABaselinePullAndNeverShowsZero`, driven by deleting
  every ShiftRecord out from under a synced store rather than by simulating a schema change.
- The probe output above goes verbatim in the S1 PR body, per the design's S1 gate.
