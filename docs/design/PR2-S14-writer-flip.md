# PR 2, S14: the writer flip

The single moment `ShiftRecord` becomes the source of truth. Staged as a
design first, deliberately: PR 2's shape died twice under review, and the
lesson recorded in the goal file is that when each round finds new defects in
the last round's fixes, the approach is wrong rather than under-polished. So
the approach gets read before two thousand lines get written.

## What makes this one PR and not six

Every alternative was tried and measured, and each failed for a reason worth
keeping:

**Per-reader source switches (retired).** The plan was six small PRs, each
teaching one reader to branch on `shiftsAreAuthoritative`. It worked for
`SmartNudgeScheduler` (#40) because that reader consumes rows and returns a
`Date`. It collapses for the rest, because every shared money helper reaches a
reader whose rows are also **edit and delete targets**:

| Helper | Consumers | Reaches an edit/delete target? |
|---|---|---|
| `CalendarEarnings` | CalendarView, **DayDetailSheet** | yes |
| `HistoryEarnings` | DashboardEarnings, InsightsEarnings, **PeriodDetailView**, PeriodsView | yes |
| `DashboardEarnings` | **DashboardView**, InsightsEarnings | yes |
| `InsightsEarnings` | InsightsNumbersGrid, InsightsView | via the two above |

**Why an edit/delete target cannot switch early.** `ProjectedShiftRow` is a
struct, deliberately: its own header says so, "it cannot be inserted into a
`ModelContext`, so double-counting a shift by accidentally persisting its
projection is a compile error rather than something a reviewer has to notice."
That guard is right, and it is also what blocks the switch, because
`DayDetailSheet.shiftRow` does this with the live object:

```swift
sheetTarget = .edit(anchor)                       // the edit sheet needs a live model
undoState.delete(group.items, in: modelContext)   // context.delete needs live objects
.shiftContextMenu(group.items, ...)               // same
```

You cannot `context.delete` a projection. Switching those rows before the
writer flips hands the user rows they can neither edit nor delete, which is
worse than the double-count the struct prevents. Measured per reader by
counting `.edit(` / `undoState.delete(` / `shiftContextMenu(` sites:
`DayDetailSheet` 3, `DashboardView` 3, `PeriodDetailView` 2, `CalendarView` 0,
`HistoryView` 0.

**Money-half-only switches (rejected on review).** Switching a screen's total
to the engine while its rows stay legacy creates a screen whose total and rows
come from two different sources. For a healthy account they agree, which is
the whole no-op premise — but it manufactures a seam where, under any bug, a
day shows one total over rows summing to something else. Criterion 5 is "the
tile, the day sheet's hero, that day's rows and the chart point are one
figure"; a money-half-only switch breaks that sentence by construction, on the
most scrutinised screen in the app. So money and rows move together, per
reader, here.

**Conclusion.** The writer flip is the atomic moment the source of truth
changes. Everything that must change with it belongs in the same, most heavily
gated PR rather than smeared across intermediate seams. Concentrate the risk
where the gate is strongest.

## What is already true, so the flip does not have to prove it

Each of these landed separately and is a load-bearing part of the flip's
no-op proof:

- **Digest identity.** `InputManifest` canonicalizes `tipOutCents ?? 0`, so one
  shift fingerprints the same whichever adapter reads it
  (`ManifestPathAgreementTests`). Before this, the explicit-zero case digested
  differently through `ShiftInputAdapter` than through `LegacySnapshotBridge`,
  and the flip could not have asserted digest-identity without an exception.
- **Money equivalence.** The store's adapter and the bridge agree to the cent
  and the minute across a zero day, a negative after tip-out, a multi-shift
  day, the 6.3833 precision case, an overtime week, a changed rate history and
  a period boundary (`AdapterEquivalenceTests`).
- **The total join.** `dayResult.shiftIDs.compactMap { groupsByID[$0] }` drops
  nothing, including a wage-only shift (`FlipJoinGateTests`). Both sides key
  on `record.id`.
- **The device zone cannot reach a valued path**
  (`DeviceZoneReachabilityTests`, lint rule 21).
- **The deletion queue is not transactional**, so a queue write must follow a
  successful save (`DeletionQueueAtomicityTests`, lint rule 20).

## The changes, by file

**The writer.** `LogTipSheet`'s four write paths move to `ShiftCommands`:
`saveNew` → `create`, `commitLiveEdit` → `update`, `delete` → `delete`,
`pruneZeroedRows` → deleted outright (a `ShiftRecord` has no zeroed sibling
rows to prune; the concept exists only in the two-row model).
`BackfillSheet.performSave` likewise.

**The rows.** `DayDetailSheet`, `DashboardView` and `PeriodDetailView` render
`ShiftRecord` and hand `ShiftRecord` to the edit sheet, the undo toast and the
context menu. `TipEntrySheetTarget.edit` changes payload type; `UndoDeleteToast`
gains a `ShiftRecord` path beside its `TipEntry` one, since old accounts still
need the legacy one until conversion completes.

**The money.** Screens stop building ad-hoc snapshots through
`LegacySnapshotBridge` and read `earningsStore.snapshot`, one line each, per
PR 5's design. One snapshot means every screen agrees by construction, which is
a stronger guarantee than six independent projections.

**The just-written paths.** `BackfillSheet` and `LogTipSheet` pass
`allEntries + sessionEntries` / `+ newEntries` because `@Query` has not
refreshed by the time `onDisappear` fires. Those become
`shiftRecords + the records just created`. This is a **merge gate**, not a
note: forgetting it means the nudge scheduler tells a user "you haven't logged
today" immediately after they logged.

**The flag.** Accounts may become authoritative.

## Gates. This PR does not merge without all of them

1. **Logged this session, not yet in `@Query`.** A shift created in the current
   sheet session satisfies the nudge check, the day total and the row list,
   before `@Query` has refreshed. Absent this, the flip reintroduces the exact
   "you haven't logged today" bug #40 switched the scheduler to prevent.

2. **Reachability, with a WITNESS per command.** This is the gate that closes
   the hazard rather than documenting it. The danger is precise: every
   read-side test can pass while the writer still silently runs the legacy
   `LogTipSheet.saveNew` path, because a correct read of a correctly-written
   legacy row is indistinguishable from a correct read of a new one. So each
   command asserts the witness of the new path, not merely that the operation
   appeared to work. On an authoritative account:
   - `create` writes a `ShiftRecord` **and writes no `tip_entries` row**
   - `update` mutates the `ShiftRecord` **in place** (same id, no second row)
   - `delete` removes the `ShiftRecord` **and enqueues its deletion**
   - `restore` brings the `ShiftRecord` back **and resurrects no `TipEntry`**

   `restore` is the fourth zero-caller command and is exercised by
   `UndoDeleteToast`'s `ShiftRecord` path, so it gets its own gate rather than
   shipping unreached behind the same wiring risk as the other three.

3. **A day with a total drops no rows.** Already written
   (`FlipJoinGateTests`), re-run here over the flipped path.

4. **Digest identity across the flip.** The same dataset fingerprints
   identically before and after, which is only assertable because the
   canonicalization landed first (#45).

5. **Cross-surface, one fixture, one natively-logged shift**: it appears in
   the calendar tile, the day detail, history, the dashboard, the nudge check
   and the delete count. Per-surface tests cannot catch this; each stays
   internally consistent with whatever source it reads. This is also where
   gate 2's `create` witness lives -- the fixture asserts the `ShiftRecord`
   exists and that no `TipEntry` was written.

6. **Edit and delete still work on a flipped row**, which is the whole reason
   the class-B readers could not move early. Including the parity case that
   pins `pruneZeroedRows`' removal as intended: on an authoritative account,
   editing a shift to zero persists **exactly one zeroed `ShiftRecord`** --
   not deleted, not duplicated.

7. **A non-authoritative account is byte-identical.** Every shipped account
   today, so this PR ships no behaviour change to anyone.

## Hazards carried forward

- `ShiftCommands.create`/`update`/`delete`/`restore` have **zero production
  callers** today. The flip is therefore a reachability change as much as a
  behaviour change, and it must prove the write path is now *reached*, not
  merely that readers read — the same coverage-versus-reachability distinction
  that hid the `shiftsAreAuthoritative` wiring bug for three slices.
- `tip_entries` remains the legacy write surface for shipped 1.0 builds and is
  never rewritten. The flip changes what THIS build writes, not what the
  server accepts.
- `pruneZeroedRows` disappears, and it is safe, established by reading the
  code rather than by arguing from the model. It is guarded by
  `guard rows.count > 1 else { return }`, so it only ever acts when one shift
  has multiple `TipEntry` rows -- precisely the two-row model that ceases to
  exist under one record per shift. It is already a no-op there. And the
  behaviour a reader might fear losing, "the user zeroes a shift", is
  preserved for free: the old code's "every row is zero" branch KEPT the
  anchor rather than deleting the shift, and editing the one `ShiftRecord` to
  zero simply persists one zeroed record. Same outcome. Gate 6 pins it so the
  absence reads as designed.

- **The queue-ordering bug was in four places, and the flip makes two of them
  reachable.** `ShiftCommands.delete` and `.restore` wrote their App Group
  queues inside `perform`, so a failed save left a live shift with a permanent
  tombstone saying it was deleted (#51). Those two commands have zero
  production callers today, so the bug is latent and the flip is what would
  have activated it. Fixed ahead of the flip, with the injectable `saving`
  seam and `ShiftQueueOrderingTests`, and rule 20 widened to every queue
  symbol -- which then found a fourth site in `PaycheckEntrySheet`. The flip
  inherits the rule, so a new write path cannot reintroduce it.
