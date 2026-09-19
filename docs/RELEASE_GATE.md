# PaydayCore release gate

Pass/fail, not a score. No line is satisfied by an argument; each names the command or the act that produces it. Tied to a specific release-candidate commit, not to "the branch".

Two kinds of line. **Machine lines** a session can run and must keep green. **Human lines** that physically need Tyler's phone, his pay period, or a professional's judgement, and that no session may mark done. A goal that reports complete with an open human line is lying.

Status legend: `[ ]` not yet, `[x]` green with evidence recorded below it, `[H]` human line, never checkable here.

---

## Branch protection on `production` -- PULLED OUT OF PR 8, ready to run

`gh api repos/tszaks/payday/branches/production/protection` returns
**404 Branch not protected**. So "merge each PR as CI goes green" has been a
CONVENTION enforced by whoever merged choosing to look, and never an
enforcement, for every merge in this project to date. On 2026-09-18 that cost
a merge: #65 landed while its checks were still `in_progress`, because
`gh pr merge --auto` means "do not block on a human", not "wait for green",
and with no required checks those requirements are met vacuously.

**This was scoped inside PR 8 and that is a sequencing error.** PR 8 is
blocked behind its entry condition (the records arm must reach legacy's
mutation catch count before the deletions land). Branch protection has no
dependency on that whatsoever, so the one change that prevents this entire
class was sitting behind a gate unrelated to it.

The failure mode when enabling is that a MISNAMED required check blocks every
merge forever, which is worse than the problem being fixed. So the names
below are copied verbatim from
`gh api repos/tszaks/payday/commits/<sha>/check-runs`, not from the workflow
file and not from memory:

```
Design lint
Payday app + widget (xcodebuild test)
PaydayCore (swift test)
Supabase migrations (db reset)
payday-api (deno test)
```

Not enabled yet, and NOT because nobody tried: the write
(`gh api -X PUT .../branches/production/protection`) is a repository-settings
change and the permission layer refused it. It goes to Tyler as a
two-command change with the payload above already written down. Set
`enforce_admins: false` -- a misnamed required check with admins enforced is
a repo-wide outage somebody has to diagnose under pressure while merges pile
up, whereas admin bypass leaves the protection doing its only job (stopping
an accidental red merge) while its own misconfiguration stays recoverable in
one action. Choose which way you fail.

### How to verify it, and why "both directions" was the wrong instruction

An earlier version of this section said to verify both directions and called
one direction "not a test". That is wrong in a way that matters, because it
would be followed: **the two directions are not equally informative.**

- **A pending required check and a MISNAMED one are indistinguishable.** Both
  leave the PR blocked. A name that will never be reported blocks forever and
  looks exactly like a job that is merely slow. So observing "red or pending
  is blocked" confirms nothing about whether the names are right -- which is
  the failure this whole precaution exists to avoid.
- **Only `green becomes mergeable` distinguishes them.** If every job
  concludes success and the PR flips to `CLEAN` and merges, then every
  required name was matched by something that actually reported. That single
  observation is the test.

So: one PR, two pushes. Push a commit that deliberately fails a job and
confirm the PR reports blocked; fix it on the same PR and confirm it goes
`CLEAN` and merges. The second push is the evidence; the first only confirms
the block engages at all.

Written down because the wrong version of this instruction is one a person
would carry out and then believe they had verified something. That is the
difference between a test and a ritual.


## Candidate

- Commit: _fill in at candidate time_
- Build number: _MDDYY+seq_
- Date: _fill in_

## Evidence recorded 2026-09-18 (later), against `paydaycore/s15-sync-leg` at 5755771

Superseding the numbers in the section below, which were taken at `5a5db7e`
before PR 2 slices S14 and S15. Added as a NEW dated block rather than edited
over the old one, because rule 4 makes every line re-runnable against the
final candidate and the earlier measurement is evidence of what was true when
it was taken.

```
$ swift test --package-path Packages/PaydayCore
Test run with 250 tests in 32 suites passed

$ PAYDAYCORE_RELEASE_GATE=1 swift test --package-path Packages/PaydayCore
Test run with 250 tests in 32 suites passed
✔ Test "knownIssueCountIsZero" passed

$ cat Packages/PaydayCore/Tests/PaydayCoreTests/Fixtures/KnownIssues.json
[]

$ xcodebuild test -scheme Payday -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
Test run with 1127 tests in 197 suites passed          # Swift Testing total, not "Executed N"

$ ./scripts/design-lint.sh
=== Design lint passed ===        # 30 [PASS], 0 [FAIL]

$ ls Packages/PaydayCore/Tests/PaydayCoreTests/Fixtures/*.json | grep -v KnownIssues | wc -l
14
```

**The release gate is proven in BOTH directions, which a green run alone does
not establish.** Planting `["W1"]` in `KnownIssues.json` makes the armed run
fail with `Release blocked: known issues pending ["W1"]`, and the unarmed run
still fails its shrink guarantee. So the green above is green because the
list is empty, not because the gate is inert.

**The 14 fixtures now GATE their money, which they did not before.** Measured
by mutation: bump every `*Cents` value under a fixture's `expected` block and
re-run.

| | Before | After |
|---|---|---|
| Fixtures whose money is gated | **8 of 14** | **14 of 14** |

The six that gated nothing were W3, M1, H1, P1, S2 and C1 -- 141 money values
that could be changed with the suite still passing. `FixtureMoneyGateTests`
closed them, and found a wrong number in `C1.json` on its first run (an
hours-missing shift declaring `regularMinutes: 0` beside its own
`minutesWorked: null`).

**Never a test helper, verified rather than asserted.** The fixture gates call
`CompensationLedger.evaluate` (x4), `PaycheckReconciler.proposal` (x2) and
`HoursFormatting.{minutes,decimalHours,clockHours}` -- all production types
from `PaydayCore`. A grep for a test-local cents function, `* 100`, `/ 60` or
`roundCents` in those files returns nothing.

**What this block does NOT establish**, so no one reads it as more than it is:
criterion 1 (PR 2 has slices remaining; PRs 3-8 are not merged) and criterion
6's deletion half (the legacy helpers survive as the legacy arm until PR 8).
Criterion 6's LINT half is green, at 30 rules.

## Evidence recorded 2026-09-18 (earlier), against `production` at 5a5db7e

Filled in per rule 1 of this document: the command and its output, not the
word "verified". This is an interim record against `production` rather than a
release candidate, so **rule 4 still applies** -- every line here must be
re-run against the final candidate commit. It is recorded now because the
measurements were otherwise living only in a session transcript.

**Green, with output.**

```
$ swift test --package-path Packages/PaydayCore
Test run with 246 tests in 31 suites passed

$ xcodebuild test -scheme Payday -destination 'platform=iOS Simulator,id=E4FC6A8A-...'
Test run with 1046 tests in 182 suites passed          # Swift Testing total, not "Executed N"

$ cat Packages/PaydayCore/Tests/PaydayCoreTests/Fixtures/KnownIssues.json
[]
$ PAYDAYCORE_RELEASE_GATE=1 swift test --package-path Packages/PaydayCore --filter KnownIssuesGate
Test run with 3 tests in 1 suite passed

$ grep -rh '^import ' Packages/PaydayCore/Sources/ | sort -u
import CryptoKit
import Foundation

$ ./scripts/design-lint.sh | tail -1
=== Design lint passed ===        # 26 [PASS] rules
```

**The 14 fixtures, and which engine each runs against.** W1-W3, M1, H1, P1,
S2, Z1, T1 and C1 run against the Swift ledger and snapshot. N1-N3 run against
the real `private.derive_shifts` in `supabase/tests/shift_deriver_test.sql`,
which names each of them. E1 runs against the real CSV exporter
(`CSVExporterTests`, "E1: the exported row carries 6.3833, 6:23 and the
engine's components"). None runs against a test helper.

Four of them -- N1, N2, N3, E1 -- asserted their expected values in the
language where their engine lives rather than reading the `.json`, so the file
documented an expectation and gated nothing. `FixtureGateTests` closed that:
editing `N2.json`'s gratuity now fails a test.

**Parity, on real adapters**, by the suite that holds each clause:

| Clause | Suite |
|---|---|
| calendar day == day detail == that day's rows == chart point | `CalendarSnapshotParityTests` (10) |
| month == sum of its days | `CalendarSnapshotParityTests`, `EarningsParityTests` (9) |
| Dashboard period == History row == period detail | `DashboardParityTests` (22), `HistoryParityTests` (27) |
| Siri == widget == app | `AmbientParityTests` (6) |

**NOT green, stated plainly rather than left ambiguous.**

- **Every superseded calculation path deleted.** No. `PeriodIncome` has left
  the shippable build (it is a frozen test-only oracle now, because six parity
  suites use it as the reference for the number the engine must *not* return).
  `TipEntry`, `ShiftDetails`, `TipBreakdown` and `ShiftDays.groupedByShift`
  are still live, because the screens still read through them. They cannot go
  until the writer flip lands. `WageEstimate` is down to one caller,
  `StatsEngine:598`, and pairs with StatsEngine's own migration.
- **Data lifecycle.** Not started; that is PR 7.
- **Shadow comparison.** Not built.
- **Production Supabase migrations applied.** Held for Tyler's own word.
  Runbook staged at `~/payday-status/TONIGHT.md`: snapshot first, row counts
  either side, one-line rollback.
- **The honesty-of-state lines** that need a debug build or a device are not
  machine-checkable here and belong with the human lines below.

## Criterion 1, measured rather than taken from the status line (2026-09-18)

`docs/PAYDAYCORE_GOAL.md` says "(0, 1 done; PR 2 is 3 of 13 slices)". That
described the tree when the contract was written and is now stale in the
UNDERSTATING direction -- the same artifact-rot family this file records
elsewhere, this time in a status line rather than a test or a doc.

Measured against `production` at `c77bb57`:

| PR | State | Evidence |
|---|---|---|
| 0, 1 | merged | package, CI, metric registry |
| 2 | S1-S9 landed; S10 reclassified to PR 8; S11, S12 done; **S13's VIEW remains** | `ShiftRecord`, the flip, the sync leg, `agent_api_shifts_test.sql`, `ScreenNumberParityTests` |
| 3 | merged | `CompensationLedger`, `PolicyStore` |
| 4 | merged | `EarningsSnapshot`, `EarningsStore` |
| 5 | merged | 14 views read the engine |
| 6 | mostly merged; **group 2.14 unbuilt** | widget and Siri reach `buildOnce`; CSV uses `HoursFormatting`; but `earnings_snapshots`, `upsert_earnings_snapshot` and `SnapshotUploader` do not exist |
| 7 | not started | atomic save landed with S9; the rest is open |
| 8 | gated | behind the catch-count entry condition above |

**So criterion 1's remainder is four things, not ten slices:**

1. **PR 6 group 2.14**, the snapshot upload. The largest buildable piece:
   `earnings_snapshots`, `upsert_earnings_snapshot` with the
   server-revision acceptance rule, `SnapshotUploader`, and `/v1/summary`
   reading the stored payload with `stale`. **Nothing of it exists**, including
   `dataset_revision` itself.

   Corrected within the hour: an earlier line here said "`dataset_revision`
   exists". It does not. `grep -rl dataset_revision supabase/migrations/`
   returns one file, and the match is a COMMENT in the S8 change-feed
   migration explaining that the keyset cursor "is not interchangeable with
   the snapshot design's `dataset_revision` watermark -- they solve
   different problems. This is the missing half."

   Fourth instance of the same instrument error in one session, and the
   first caught inside an hour of committing it, by drilling into the match
   instead of counting files. `grep -l` answers "does this string appear",
   which is not "does this thing exist" -- the same invalid inference as
   "no match, therefore untested", pointed the other way.
2. **PR 7**, lifecycle hardening.
3. **PR 8**, the deletions, behind the catch-count condition.
4. **S13's view**, which the slice gates on "a design review on renders
   before done" -- its state, copy and tests are already built and green
   (`PaydayConversionBanner`, `ConversionBannerTests`), so what remains is
   the render and the review, and the review needs Tyler.

## Machine-line status, measured on `production` at `c77bb57` (2026-09-18)

Re-run rather than re-read, per rule 4 — production moved four times today.
A box is ticked only where a command and its number are recorded, and where
the check has been shown to FAIL on purpose at least once.

### GREEN, with the command and the number

**MEASURED AT `bdb47e9`, 2026-09-19.** Every row below is a reading taken at
that commit, not a standing property of the repo.

A row here says "this command printed this number once, on this tree". It
does not say "this is true now". Those are different claims and only the
first one is evidence. An undated "still green" is a false-alarm generator
with a timer on it: the baseline drifts, the assertion does not, and the
artifact goes from informative to actively misleading without anyone
touching it.

Paid for twice in one day. The app-suite row below read `1141 tests in 200
suites` until this commit, which was accurate when written and wrong three
hours later once #65 added tests -- nobody re-derived it because a number
that specific reads as care. And a fleet watchdog elsewhere held a stale
expected version, which made a correctly-behaving system look like three
unauthorised deploys. **A watchdog with a stale baseline does not fail
quietly, it fails loudly**, and crying wolf on a healthy system is worse
than no watchdog, because it teaches the reader to discount the next alarm.

**So: re-run the command before citing a row. If you update a number, update
the commit and date in this heading in the same edit.**

| Line | Evidence (at `bdb47e9`) |
|---|---|
| PaydayCore green | `swift test --package-path Packages/PaydayCore` → `255 tests in 33 suites passed` |
| App suite green, at/above baseline | `1163 tests in 202 suites passed`; baseline 1082/192. Has read `1141/200` and `1144/200` at earlier commits -- the drift that produced the dating rule above, and the reason this heading names a tree |
| 14 fixtures vs the real engine | mutation sweep: **14/14 money-gated** (was 8/14). Gates call `CompensationLedger.evaluate`, `PaycheckReconciler.proposal`, `HoursFormatting.*`; grep for test-local cents arithmetic returns nothing |
| Release gate armed | `PAYDAYCORE_RELEASE_GATE=1` green, `knownIssueCountIsZero` passed, `KnownIssues.json` = `[]`. Proven BOTH ways: planting `["W1"]` fails with `Release blocked` |
| Dashboard == History == period detail | per-arm mutation; records 2 suites/14 tests, legacy 5/32 |
| Calendar day == detail == Σ shifts == chart point | four-way identity on records, `ScreenNumberParityTests` + `FlipGates3And4Tests` |
| Month == Σ its days; YTD clips | snapshot-level and arm-independent: `EarningsSnapshotTests` "range equals the sum of its days", "month plus month equals the containing range", "year to date clips a pay period that crosses the year boundary" |
| Siri == widget == app | ambient `asOf` mutation fails the records arm, the legacy arm AND `AmbientParityTests` |
| Money-boundary lint green and PROVEN to fire | `design-lint.sh` 30 PASS / 0 FAIL; a planted probe fires 3 representative rules and leaves prose alone |
| Package imports | `grep -rh '^import ' Packages/PaydayCore/Sources/` → exactly `CryptoKit`, `Foundation` |
| Pillar 8 truthful | four contradictions closed; zero active-false statements; the overtime guarantee stated exactly once |

### NOT green, and why — none of these is a note

| Line | Why it is open |
|---|---|
| Every superseded path deleted | **PR 8**, and it now has a numeric entry condition above: the records arm must reach the legacy arm's catch count (currently 5 suites/32 tests against 2/14) before deletion is permitted, because deleting legacy deletes the 32 with it |
| Data lifecycle (interrupted save, replay, offline, account switch, rollover, timezone) | PR 7, not started |
| Downgrade purges `ShiftRecord` and re-baselines without `$0` | needs a device |
| Production migrations applied with row counts | needs the production database |
| Shadow comparison, every inventory number, no unexplained cent | PR 8 |

### Machine lines: where they actually stand, 2026-09-19 at `9e3c06e`

**13 of 34 machine lines are green with their evidence recorded inline.**
The contract asks that only the HUMAN lines remain open. They do not yet,
and saying otherwise would be the failure this document exists to prevent.
The 21 that are open fall into four kinds, and only one kind is waiting on
Tyler:

**Needs hardware, cannot run from any machine here (4).** The honesty-of-state
lines: a failed read never rendering as `$0`, `.partial` never saying
"Total", the estimated-rate caption, the overtime disclaimer. Plus the
downgrade purge. These are machine-checkable in principle and need a build
on a device.

**Needs Tyler's database (1).** Production migrations applied with row
counts before and after.

**Blocked behind PR 8, which is itself blocked (6).** Superseded paths
deleted; the ten old calculation paths; the shadow comparison; the
money-boundary allowlist reaching its final state. PR 8 has two conditions
and one is unmet -- see `FLIP-BLOCKER-DELETION-FLUSH`.

**Genuinely remaining work nobody is blocked on (10).** The lifecycle sweep
under fault injection, the TestFlight store-fixture upgrade, the change-feed
migration reaching production, Pillar 8 re-verified against current tests,
and the release-candidate CI record.

The honest one-line summary: **the engine is measured and correct, the
deletions are blocked on a real defect, and the device lines are the only
ones that need a person.**

## Machine lines that need a DEVICE, so no CI run can close them

Honesty-of-state is machine-checkable in principle and not from here: breaking
the widget's store access to see "Couldn't load" rather than `$0`, removing
hours from one shift to read `.partial` never saying "Total", the estimated-rate
caption, and the overtime disclaimer all require a build on hardware. They are
listed under the machine lines below because a debug build CAN verify them —
just not this session.

## Machine lines

### Engine correctness
- [x] `swift test --package-path Packages/PaydayCore` green. Record the `Test run with N tests in M suites` line. **GREEN at `9e3c06e`, 2026-09-19:** `Test run with 255 tests in 33 suites passed`.
- [x] App suite green. Record the **Swift Testing** total, not the `Executed N tests` lines, which count only the two XCTest files and have hidden a real failure before. Must be at or above the then-current baseline. **GREEN at `9e3c06e`:** `Test run with 1163 tests in 202 suites passed`, against a baseline of 1082/192.
- [x] All 14 golden fixtures (W1-W3, N1-N3, M1, H1, P1, E1, S2, Z1, T1, C1) pass **against the real production engine and screen adapters**, not a test helper. The original `CalendarDayTotalTests` passed for years while testing a formula the calendar did not use. **GREEN:** 14 fixture files present, and `FixtureMoneyGateTests` drives them through `CompensationLedger.evaluate` -- the production engine, not a helper.
- [x] `PAYDAYCORE_RELEASE_GATE=1 swift test --package-path Packages/PaydayCore --filter KnownIssuesGate` green, with `Fixtures/KnownIssues.json` empty. A pending known issue blocks the release; it is not a note. **GREEN, measured 2026-09-19:** `Test run with 3 tests in 1 suite passed`, `knownIssueCountIsZero` passed, `KnownIssues.json` is `[]`.

### Parity, on real adapters
- [x] Dashboard period income == History period row == period detail. **GREEN:** `ScreenNumberParityTests` -- "Dashboard, History rows, period detail and Calendar agree across both arms".
- [x] Calendar day == day detail == sum of that day's shifts == the chart point for the same metric. **GREEN:** "the tile, the day sheet's hero, that day's rows and the chart point are one figure".
- [x] Month == sum of its days. Pay period == sum of its eligible ledger entries. YTD clips periods crossing the year boundary rather than summing whole overlapping periods. **GREEN:** `EarningsSnapshotTests` -- "range equals the sum of its days", "month plus month equals the containing range", "year to date clips a pay period that crosses the year boundary".
- [x] Siri == widget == in-app current period, for the same `asOf` and source revision. **GREEN:** `AmbientParityTests` -- "the ambient figure is the app's own pay-period result".
- [x] A shift's wages sum across day, month, pay period and year to the same cents, including a workweek that straddles a month boundary. **GREEN:** fixture W2, the 48h week straddling a month boundary; the month-first answer 13585 is asserted WRONG.

### Honesty of state
- [ ] A failed read is never rendered as `$0`. Verified by breaking the widget's store access in a debug build and seeing "Couldn't load".
- [ ] `.partial` completeness never renders the word "Total". Verified by removing hours from one shift and reading the headline.
- [ ] Wages estimated from the legacy rate carry their caption until the rate-history prompt is answered.
- [ ] The overtime policy is presented as an estimate everywhere it appears.

### Boundaries
- [x] Money-boundary lint rules green, and each one proven to fire by planting a violation in a scratch copy. **GREEN, both directions, 2026-09-19:** planting `100 - (tipOutCents ?? 0)` in an unallowlisted file fires; planting `State(initialValue: tipOutCents ?? 0)` does not. Allowlist 6 and ratcheting.
- [ ] Every superseded calculation path deleted, not wrapped. `grep` for the retired symbols returns nothing outside the engine and its adapters.
- [x] Package imports Foundation and CryptoKit only. **GREEN:** `grep -rh '^import ' Packages/PaydayCore/Sources/` returns exactly `CryptoKit` and `Foundation`.
- [ ] `docs/PRODUCT.md` Pillar 8 describes what the engine actually guarantees, with no claim the tests do not back.

### Data lifecycle
- [ ] Interrupted save, retry replay, offline edit then reconnect, delete then sync, account switch mid-request, midnight rollover, and a device timezone change all pass with no lost, duplicated, or cross-account record.
- [x] A shift moved across a workweek boundary re-values both weeks. **GREEN:** added in #80; the source week's overtime must disappear, mutation-proven by collapsing the workweek grouping.
- [ ] An upgrade from the current TestFlight build's store fixture migrates and verifies.
- [ ] A downgrade purges `ShiftRecord` rows (measured; see `docs/design/S1-downgrade-probe.md`) and the next launch forces a baseline re-pull without ever showing `$0`.
- [ ] Production Supabase migrations applied, each with the affected-table row counts before and after, and each verified first on a scratch local cluster from clean.

### Shadow comparison
- [ ] Every inventory number computed by the pre-PaydayCore path and by the engine over the same store; every difference maps to a named fixture ID. No unexplained cent.

## Tracked known-failing tests (each must be deleted, not skipped)

A parity test written before its fix is the honest way to hold the line: it names the bug, names the PR that closes it, and fails until then. Every entry here must be GONE at release, with its `withKnownIssue` wrapper deleted rather than its assertion weakened.

| Test | Why it fails today | Closes in |
|---|---|---|
| `EarningsParityTests` (the calendar-day parity assertion, `PaydayTests/EarningsParityTests.swift:235`) | `CalendarView` slices the ledger per day (`CalendarView.swift:49`), so a week's overtime never reaches a tile. This is the audit's original bug, now pinned by a test instead of a document. | PR 5, when every consumer reads `EarningsSnapshot` over the whole dataset |

- [ ] Zero entries remain in this table, and no fixture is suppressed. Measure it with the JSON and the gate, NOT with a bare grep:
      `cat Packages/PaydayCore/Tests/PaydayCoreTests/Fixtures/KnownIssues.json` must print `[]`, and
      `PAYDAYCORE_RELEASE_GATE=1 swift test --package-path Packages/PaydayCore --filter KnownIssuesGate` must pass.
      The grep this line used to name was wrong twice over: it searched `PaydayTests/` while the mechanism lives in
      `Packages/PaydayCore/Tests/PaydayCoreTests/Support/KnownIssues.swift`, and it counted a COMMENT recording the
      wrapper's own removal as a live suppression. A gate command that manufactures a positive is the same defect as
      one that manufactures an absence (see the merge-commit section).

## The shift cursor fence — machine-checkable, and it blocks a ship

Added 2026-09-18 after a retraction. S6 shipped the shift read path without
this fence, and applying the fold to production does **not** expose a live
user to it, because no shipped build reads `public.shifts` and no migration
runs a backfill. It becomes live the moment a build ships that reads shifts.

The bug it prevents is permanent and silent. `updated_at` is the transaction
timestamp, and the fold runs at the end of a 1.0 build's batch, so a shift can
be stamped seconds before it is visible. A client that advances its cursor to
the newest `updated_at` it pulled then filters that shift out forever, on
every device, with nothing indicating a fault. It is fatal on this leg alone
because `shifts` is the only read surface there, the writer is a third party
so the post-push readback cannot cover it, and the cache check compares ID
sets so a present-but-stale shift never forces a re-baseline.

- [ ] The client clamps the shift cursor to
      `min(max(updated_at) among pulled rows, server_now - shiftCursorSafetyWindow)`,
      where `server_now` comes from `public.fetch_shift_changes` **in the same
      statement as the page**, never a separate read.
- [ ] `scripts/db-test-race.sh` case 10 passes **both** arms: the folded shift
      is MISSING with the unclamped cursor and ARRIVES, with its money, with
      the clamped one. One arm alone proves nothing.
- [ ] `20260918120000_add_shift_change_feed.sql` is applied to production
      before, or in the same batch as, the first build that reads shifts.

**No build that reads `public.shifts` ships until all three are green.** This
is the guard; migration ordering is not, because the clamp is client code and
the migration only supplies a timestamp.

## The money boundary — machine-checkable, and it is what makes item 6 real

Added 2026-09-18. `design-lint.sh` rule 15c fails on money computed outside
`Packages/PaydayCore`, across five patterns drawn from divergences that
actually happened: `.netCents` summed row by row, `cashTipsCents +` assembling
a total, `tipOutCents ??` defaulting a tip-out locally, `* 1.5` applying an
overtime multiplier, and `/ 100 / hours` deriving a rate.

The rule landed BEFORE the deletions, with the tree's existing violators
allowlisted, so it was written against real violations rather than fitted to
an already-clean tree. **The allowlist ratchets:** an entry that no longer
violates anything is itself a failure, so it cannot quietly stop shrinking
into permanent permission.

- [ ] `bash scripts/design-lint.sh` passes with the money-boundary allowlist
      **empty**. Seven files remain as of 2026-09-18: `TipEntry`,
      `LegacyShiftRow`, `ShiftRecord`, `PaycheckAudit`, `TipBreakdown`,
      `StatsEngine`, `LogTipSheet`.
- [ ] The ten old calculation paths are deleted, not merely wrapped:
      `TipEntry`, `TipBreakdown`, `ShiftDetails`, `ShiftDays.groupedByShift`,
      `WageEstimate`, `PeriodIncome`, `PredictedPaycheck`, `PaycheckAudit`,
      `TipRecord`, `ShiftWriter`.

Both were verified to FAIL when they should, not merely to pass: a synthetic
violation in a non-allowlisted file was caught on all three of its patterns,
and an allowlisted file made artificially clean tripped the ratchet. A lint
nobody has watched fail is a lint nobody should trust.

## Merge-commit CI — and what a green tick here does not earn

The goal contract's first item reads "PRs 0-8 merged to `production` with CI green on each merge commit." As written, that line was **unfalsifiable**, and the reason is worth recording, because fixing it changed what the line can honestly claim.

`ci.yml` keyed `concurrency.group` on `github.ref` with `cancel-in-progress: true`. For a pull request that is correct: the ref is the PR's head, so a new push should supersede the run it replaced. For a push to `production` the ref is a **constant** — every merge lands on `refs/heads/production` — so consecutive merge commits shared one slot and each cancelled its predecessor. Three commits in PRs 0-8's history carry no green verdict:

| Commit | What it merged | Verdict | Cause |
|---|---|---|---|
| `8260f7d` | #28, the CSV hours fix | cancelled | next merge 105s later, same concurrency slot |
| `852f36a` | #11 follow-up, PR 4 | cancelled | next merge 8s later, same slot |
| `c800493` | #20, PR 5 wave 1 | failure | `Failed to resolve latest Supabase CLI release: rate limit exceeded`; its other four jobs were green |
| `013de83` | PR 5 wave 2's internal integration merge | **no run at all** | never triggered; found only by querying per-SHA rather than per-branch |

Neither cause is a code failure. Two were a race in our own workflow; one was a GitHub API rate limit while `supabase/setup-cli` resolved `version: latest`. Both are fixed: pushes key the concurrency group on `github.sha`, so no merge commit can cancel another, and the CLI is pinned to an explicit version so `supabase db reset` cannot change behaviour with no change in this repo.

### Re-running those three commits cannot fix the record, and here is the measurement

A re-run replays the workflow **as it was at that commit**, not the workflow as it stands now. Measured on the re-run of `852f36a` (run 35333038807): `gh api` reports `head_sha=852f36aa0`, `path=.github/workflows/ci.yml`, `run_attempt=2`, and that commit's own `ci.yml` still contains `version: latest` and the ref-keyed `cancel-in-progress: true`. So the attempt runs the unpinned CLI, re-inheriting the exact flake that reddened `c800493`.

That rules out both tempting claims. A green re-run does **not** prove "CI was green when this commit merged" — that verdict was cancelled or flaked and cannot be reconstructed. And it does **not** prove "this commit's tree passes CI on the current workflow" either, because the current workflow is not what runs.

### The claim that is true, and is the one that matters

The current `production` tree passes CI in full, and every line those three commits introduced is contained in that tree. A break shipped through any of them would surface in every later full rebuild, and there are consecutive green production merge commits after all three. So the three unverified commits are covered **transitively**, by later green rebuilds of the tree that contains them — not by any individual re-run.

That is weaker than a per-commit historical verdict and stronger than nothing, and it is the claim that governs shipping: what ships is the current tree.

### Two ways to audit this wrong, both measured

**`gh run list --branch production` manufactures false absences.** It returns only **push**-event runs. A `pull_request` run's `headBranch` is the PR's head branch, never `production`, so that query drops them. Run against this history it reports five merge commits with no run at all — `a83dd0e`, `e39aba1`, `2d1a8c7`, `540ab14`, `013de83` — and **four of those five are in fact green**, under `pull_request`. Only `013de83` is genuinely unrun. A check that invents absences is as misleading as one that invents passes, so the audit line below queries per SHA and accepts a run under any event.

**A green re-run is not evidence about the current workflow, even when it passes.** The `852f36a` re-run (run `35333038807`, `run_attempt=2`) came back `completed/success`, its migrations job included — on the **old** workflow, still carrying `version: latest`. The unpinned CLI simply did not hit the rate limit that time. So the flake is intermittent rather than absent there, which is precisely why the pin matters and precisely why that green tick says nothing about the workflow in the tree today.

- [ ] The current release-candidate commit's full CI is green. Record the run id and every job's conclusion.
- [x] Every merge commit after the concurrency fix has a completed, successful run — no `cancelled`, no `failure`, and none missing. Audit **per SHA**, not per branch: **MEASURED 2026-09-19 across all 19 production merge commits since 2026-09-18T20:00Z: zero cancelled, zero missing, zero failed.** One exception, recorded rather than swept: `0f4f1bc` (#72, the watermark migration) has a `Supabase migrations (db reset)` job that never completed -- it WEDGED, which is the defect that forced the revert. It can never be green, because its content is the bug. Its verdict is superseded by `c93489d`, the revert, which is green on all five. A reverted commit's red is not an outstanding failure; it is the record of why the revert exists.

      ```
      for s in $(git log origin/production --merges --format=%H | head -40); do
        printf "%s  " "${s:0:9}"
        gh api "repos/tszaks/payday/actions/runs?head_sha=$s" \
          -q 'if (.workflow_runs|length)==0 then "NO RUN"
              else ([.workflow_runs[] | "\(.event):\(.status)/\(.conclusion // "pending")"] | join(" ")) end'
      done
      ```
      `status` is printed alongside `conclusion` deliberately: an in-progress
      run has `conclusion: null`, which renders as an empty field and reads
      like a missing run. This form distinguishes all four states that matter
      — `NO RUN`, `in_progress/pending`, `completed/success`,
      `completed/cancelled` — and was run against this history before being
      written down here.
- [ ] The four commits without their own green verdict (`8260f7d`, `852f36a`, `c800493`, `013de83`) are recorded here as transitively covered, with the later green merge commit that covers each one named — `013de83` is covered by `4d631c9`. They are **not** to be ticked as individually verified, because they cannot be.
- [ ] No merge commit's run is `cancelled`, and none is missing entirely. A cancelled run is not a pass and not a failure; it is an absence, and in a listing an absence reads like neither. That is exactly how these went unnoticed.

## PR 7 status, measured 2026-09-19 at `c752597`

**PR 7 was recorded as "not started". That is wrong, and most of it was
already done before tonight.** Measured item by item against the plan's own
list rather than summarised, because "not started" on a release card is the
kind of claim that gets planned around.

| PR 7 item | State | Evidence |
|---|---|---|
| Atomic logical-shift save, rollback on throw | **DONE, pre-existing** | `ShiftCommands.swift:105` performs the rollback; `ShiftCommandsTests.swift:92` `editThatThrowsChangesNothing()`, plus `AutosaveOffPersistenceTests.swift:207` (the rollback survives a reopen) and `DeletionQueueAtomicityTests.swift:57` `rollbackDoesNotUndoTheQueueWrite` |
| Idempotent retries on `id` | **DONE, pre-existing** | `on conflict (user_id, id) do update` in `add_shift_write_rpcs.sql` |
| Last-client-write-wins by `client_updated_at` | **DONE, pre-existing** | `excluded.client_updated_at >= existing.client_updated_at`, documented at the RPC |
| Deletions preserved across reconnect | **DONE, pre-existing** | four tests in `ShiftCheckpointTests`, incl. "a full sync pass preserves pending shift restores" and "a legacy deletion queue entry survives a restore-cancel pass" |
| Late responses for a previous account rejected | **UNREACHABLE BY DESIGN** | `registerCurrentUser` refuses a second account outright; asserted at `PaydaySyncStateTests:27`. There is no switch to reject a late response from |
| Account switch clears the store and checkpoint | **UNREACHABLE BY DESIGN** | same refusal. The plan item describes a path this codebase forbids |
| Shift moved across workweeks re-values both | **ADDED** (#80) | source week's overtime must disappear, not merely stop growing |
| Upgrade conserves rows and money | **ADDED** (#82) | conservation, not expected values; two identical rows must not be deduplicated |
| Midnight rollover rebuilds | **ADDED** (#83) | posts the real `.NSCalendarDayChanged`, so the REGISTRATION is what is tested |
| Device timezone change leaves money untouched | **DONE, pre-existing** | fixture T1 |
| Parsers produce candidates only | **DONE** | `scripts/lint-parsers-pure.sh`, design-lint rule 32. Proven to fire: adding a `try? c.save()` to `ReceiptAIParser` fails it by name |

**A citation in this table must name a symbol that EXISTS.** The row above
originally cited "anEditThatThrowsLeavesTheRecordExactlyAsItWas" (quoted, not
backtick-fenced, precisely so the lint below does not flag this sentence),
which is
nowhere in the codebase: I camel-cased the test's DISPLAY string
(`@Test("an edit that throws leaves the record exactly as it was")`) into
something shaped like an identifier and wrote it here as if it were one. The
test is real and the coverage is real -- the function is
`editThatThrowsChangesNothing()` -- but a reader who greps the name I wrote
finds nothing and concludes the coverage is phantom. A reviewer did exactly
that within the hour.

That is worse than a typo, because a gate document citing test names that
resolve to nothing is a rubber stamp shaped like evidence. A sweep of every
backticked identifier in this file found exactly one such citation: the one
I had just added. `scripts/design-lint.sh` now fails on any other.

**PR 7's plan list is now CLOSED.** The last item, the parser rule, is
design-lint rule 32. What remains is not on the list: see the paragraph
below. Two of its
eleven items describe paths the code makes unreachable and should be struck
from the plan rather than implemented; the plan predates the decision that
made them impossible.

**What this does NOT mean.** The gate line "no lost, duplicated, or
cross-account records under fault injection" is satisfied for the faults
named above and is not a general proof. Sync fault injection at the wire
level is affordable here -- `ShiftWriteWireTests` already stubs
`URLProtocol` -- and has not been swept systematically. That is real
remaining work; it is just not the work the plan's list describes.

## CORRECTED 2026-09-19: the flip blocker is narrower than I wrote

**Retraction of the mechanism, not of the finding.** I recorded this as a
P0 whose failure mode was "the fold re-derives the shift and the next pull
brings it back". **The fold cannot do that, and I should have checked
before writing it.**

Measured in `20260917200000_add_shift_deriver.sql`:

- `private.shift_is_open_to_fold` is
  `native_modified_at is null and deleted_at is null` -- a deleted shift is
  closed to the fold entirely.
- ARM 1's `on conflict ... do update` sets fourteen columns and
  **`deleted_at` is not among them**. The upsert cannot clear a tombstone.
- ARM 3, the un-delete arm, reopens only `deleted_reason = 'converted'` on
  a shift with `native_modified_at is null`, and says so: *"Only a tombstone
  the fold itself set on a shift no human has touched is reopened. A user
  deletion is never cleared."*

So the server-side invariant that review ruled for -- *a tombstoned shift id
is never re-derived, whatever legacy rows survive* -- **already exists and is
complete.** We both designed a fix for an implemented guarantee.

**And the scope was wrong too.** It is not that deletions specifically lack
a flush. The ENTIRE shift sync leg has zero production callers:

| symbol | production callers |
|---|---|
| `upsertShifts` | 0 (its one "reference" is a doc comment) |
| `reconcileShifts` | 0 |
| `softDeleteShifts` | 0 |
| `restoreShifts` | 0 |
| `fetchShifts` | 0 |

That is coherent pre-flip state, not a hole in a built system. `shifts` is
not synced by the device at all yet.

### What survives, and it is worth keeping

**Whoever wires the shift sync leg must wire ALL of it.** The deletion flush
is the piece most likely to be forgotten, because push and pull are the
obvious two and a queue with no reader fails silently. `ShiftCommands`
already queues into `pendingShiftDeletions` and `pendingLegacyEntryDeletions`
today, so the producers are live and waiting.

That is a completeness requirement on unbuilt work, not a defect in built
work -- a real difference, and the reason this section is no longer titled
as a P0.

`FLIP-BLOCKER-DELETION-FLUSH` remains the marker, because the allowlist
entries naming it are still correct: those accessors genuinely have no
consumer yet.

## ORIGINAL ENTRY, kept for the record: shift deletions have no flush

**Marker: `FLIP-BLOCKER-DELETION-FLUSH`** -- named by every entry in
`scripts/syncstate-unwired-allowlist.txt` that this condition excuses.
Deleting this section fails `lint-syncstate-wired.sh` until those symbols
are wired, which is deliberate: the excuse cannot outlive the reason.

**Found 2026-09-19 while sweeping PR 7. The shift deletion path has
producers and no consumers. At the moment `shiftsAreAuthoritative` becomes
true for an account, deleting a shift will stop reaching the server.**

Measured, three independent ways, all pointing the same direction:

| symbol | app references outside `PaydaySyncState` |
|---|---|
| `recordShiftDeletion` | 2 (producers, in `ShiftCommands`) |
| `recordLegacyEntryDeletions` | 1 (producer) |
| `pendingShiftDeletions` | **0** |
| `pendingLegacyEntryDeletions` | **0** |
| `softDeleteShifts` | **0** (defined on the repository, called only by a wire test) |
| `restoreShifts` | **0** |

`ShiftCommands.delete` queues both a shift tombstone and the deleted shift's
legacy source rows. Nothing in production reads either queue.
`PaydaySyncService` flushes `pendingTipDeletions` only, which is the
`tipEntries` key -- and `legacyEntries` exists as a SEPARATE key precisely
because `tipEntries` is emptied by the restore-cancel arm before the flush
runs. That reasoning is documented at `PaydaySyncState.swift:256`; the queue
it created is the one with no reader.

**Why it is latent rather than live.** `shiftsAreAuthoritativeForCurrentAccount`
is false for every account, so screens render from the legacy
representation and hand `[TipEntry]` to the delete path, taking the arm
that works. The `ShiftRecord` overload at `ShiftContextMenu.swift:68` is
built ahead of the flip.

**Why it is a P0 at the flip rather than a tidy-up.** The user deletes a
shift. It disappears locally. The server never hears, so the legacy rows
stay live, the fold re-derives the shift, and the next pull brings it back.
A deleted shift RETURNING is indistinguishable from the app inventing money,
and it is the failure that the whole conversion design was shaped to avoid
-- the `legacyEntries` key exists because someone already reasoned their way
to this exact outcome and split the queue to prevent it.

**This is the same shape as slice S13** -- machinery built, tested at the
wrong layer, with no producer or no consumer in production -- occurring for
the fourth time in this project and in the most damaging place available.

### The fix is a server-side invariant, NOT flush ordering

Ruled after review, and the rejected option is the instructive one.

The tempting fix is "flush the legacy row deletions before the tombstone".
**It is wrong.** It makes correctness depend on two network operations
landing in a particular order, which fails under partition, partial
success, retry, and app termination between the two. This project has paid
for that class twice in one night -- the wedged migration and the
intermittent CI verification -- and both were expensive *because* they were
intermittent. A resurrection bug that only appears when the second call
fails is the worst version available: rare, unreproducible, and presenting
to the user as invented money.

**Instead: a tombstoned shift id is never re-derived by the fold, whatever
legacy rows survive.** Then client flush order is irrelevant, a lost legacy
deletion is a storage leak rather than a correctness failure, and a
tombstone means what its name says -- the shift is dead as a fact, not as a
race outcome.

Three consequences to design in deliberately:

- **Only an explicit restore clears a tombstone.** Absence of a delete must
  never clear it, or the same race is rebuilt from the other side.
  `restoreShifts` becomes the sole revocation path, which is what it is
  already shaped for.
- **A re-created shift mints a NEW id**, never reusing a tombstoned one, or
  resurrection returns through the front door.
- **The legacy-row flush stays**, demoted from correctness to hygiene, and
  must remain outside the `tipEntries` restore-cancel arm -- which is the
  entire reason the separate key exists.

That is a migration plus a consumer rather than just a consumer. It is more
work, and it is the right more-work.

**Not fixed here, deliberately.** Where the flush belongs is a design
decision: which pass, in what order relative to the server-side fold, and
what happens when a tombstone lands before its legacy rows do. PR 2's shape
died twice from answering questions like that quickly. This is recorded as a
blocking condition on the flip, not patched at the end of a long session.

## UNTRIAGED-LEGACY-ACCESSORS

`lint-syncstate-wired.sh` found two `PaydaySyncState` accessors with no
production reader that are NOT part of the deletion-flush gap:
`knownTipEntryIDs` and `knownPaycheckIDs`.

They are allowlisted under this marker rather than under the flip blocker,
because I have not established whether they are dead code from the 1.0 sync
or are wanted by something unbuilt, and filing them under a condition they
have nothing to do with would make that condition look bigger than it is.

**This section exists to be deleted.** Whoever triages them either wires
them, removes them, or splits them into a condition with a real reason --
and deleting this heading without doing one of those fails the lint.

## PR 8 entry condition: the records arm must out-gate the legacy arm first

**PR 8 may not delete the legacy calculation paths until the records arm's
catch count, for the same mutation, reaches what the legacy arm's was.**

Ruled 2026-09-18, and it exists because of a measured asymmetry rather than a
worry. The instrument is a per-arm mutation comparison: introduce ONE
cross-surface defect on each representation in turn -- clamping a builder's
DATASET to today while its sibling stays unclamped is the canonical one,
since that is exactly the divergence criterion 5 forbids -- and count the
suites and tests that fail.

Measured on `DashboardEarnings`:

| Mutation | Suites | Failing tests |
|---|---|---|
| legacy arm clamps  | 5 | 32 |
| records arm clamps, before | 1 | 3 |
| records arm clamps, after `DashboardRecordsArmParityTests` | 2 | **14** |

**RE-STATED 2026-09-19, because the count form could not be checked.**

The condition was "the records arm's catch count must reach the legacy
arm's", recorded as 5 suites / 32 tests against 2 / 14. Re-running the
canonical mutation today gives **3 / 9 on BOTH arms** -- and legacy
*dropping* from 5/32 to 3/9 is the tell. Coverage did not fall; the two
measurements used different counting conventions. Swift Testing prints a
failing test twice (once per issue, once for "failed after"), and a test
failing on three issues inflates a naive count threefold.

So the recorded numbers were not wrong so much as **unreproducible**, which
for a gate is the same thing: a threshold nobody can re-derive cannot be
met or missed, only asserted.

**The condition is now a SET comparison, which is method-independent and is
also the actual risk.** Deleting the legacy arm deletes the tests that
exercise it. What matters is not how many those are, but whether any of
them catches something the records arm misses -- because those are the ones
whose deletion loses coverage.

> **PR 8 may not delete the legacy calculation paths while any test catches
> a cross-surface defect on the legacy arm that no test catches on the
> records arm.**

Measured at `6862117`, clamping each arm's dataset to today in turn and
diffing the sets of failing test names:

| | |
|---|---|
| caught by BOTH arms | 6 tests |
| caught by the RECORDS arm only | **0** |
| caught by the LEGACY arm only | **0** |

The six: "Dashboard, History rows, period detail and Calendar agree across
both arms", "Dashboard, the History row and period detail agree on one
records period", "a shift at 5pm on the period's final day is inside the
records range", "one fixture reads the same on all four HistoryEarnings
consumers", "one records dataset answers both the to-date and the
whole-period question", and "the payday card's check differs from the hero
by exactly the cash, on records".

**So the entry condition is MET for the canonical mutation.** Stated with
its limit rather than as a clearance: one mutation is not a proof of
general parity. It is the mutation this condition named, and the asymmetry
it was created to detect is gone.

### MET IS NOT CLEARED: PR 8 has TWO blocking conditions, not one

This one is satisfied. **The other is not, and it is the dangerous one to
overlook**, because "entry condition MET" reads like a green light.

PR 8 deletes `TipBreakdown`, `ShiftDetails`, `ShiftDays.groupedByShift` and
`TipEntry.netCents` -- the legacy CALCULATION paths. Once they are gone the
app can only read from records, so **shipping PR 8 IS the flip**, whatever
the flag says.

And `FLIP-BLOCKER-DELETION-FLUSH` fires exactly there. Shape 3 keeps
`tip_entries` as the write surface indefinitely, so deleting a shift still
has to tombstone its legacy source rows -- and that flush has no production
consumer. Delete the calculation paths without fixing it and the first
thing the new representation does is resurrect a shift the user deleted.

The two conditions are independent and both must hold:

| condition | state |
|---|---|
| records arm out-gates legacy for the canonical mutation | **MET** (above) |
| shift deletions reach the server | **NOT MET** -- `FLIP-BLOCKER-DELETION-FLUSH` |

Worth stating because the failure mode here is a reader who checks the
condition they remember, finds it green, and proceeds.

Reproduce with: clamp `asOf` to `.now` in each `DashboardEarnings.build`
overload in turn, run the app suite, and diff the sorted sets of failing
test names. Set equality is the gate; the counts are incidental.


And on `CalendarEarnings`:

| Mutation | Suites | Failing tests |
|---|---|---|
| records arm clamps, before | 1 | 3 |
| records arm clamps, after the four-way chain | 2 | 6 |

**Why this is a gate and not a note.** PR 8 deletes the legacy paths, and the
legacy parity suites go with them, because they exercise `TipEntry`-based
code that will no longer exist. So PR 8 as conceived removes roughly 32
catching tests and leaves 12 -- stripping most of the project's cross-surface
protection at the exact moment every account depends on the records arm.

**The failure mode this guards is not a broken gate.**
`DashboardPeriodParityTests` is correctly named, correctly written and
correctly passing; it catches exactly what it was built to catch. It simply
stopped pointing at the dangerous thing. Nobody erred when those 22 tests
were written, because the second representation did not exist yet. The RISK
moved and the tests did not.

That is entropy with a direction, and it is predictable: test mass
accumulates where the code has been longest, risk migrates to where the code
is newest, so the two diverge by default in every migration. Expect the
asymmetry rather than being surprised by it, and measure it rather than
assuming the count is where you left it.

## Human lines — Tyler only

- [H] Clean install on a real device, release configuration, exercised for a full logging session.
- [H] Upgrade in place from the build currently installed from TestFlight, with existing real data, and the totals checked against what they read before.
- [H] A pay-period close observed end to end on the device, including the payday moment.
- [H] A real paycheck reconciled against the engine's expectation, with any discrepancy explained.
- [H] A TestFlight soak across that close with no correctness report from any tester.
- [H] A payroll professional confirms the supported compensation policy is stated correctly for a tipped employee, since 40h/1.5x on the base rate is an estimate and the app says so.

## Rules for whoever fills this in

1. Paste the command and its output. "Verified" alone is not evidence.
2. If a line was not run, write `not run` and why. Do not leave it ambiguous.
3. A red line blocks the release. There is no weighted average and no "mostly green".
4. Re-run every machine line against the final candidate commit. A line green on an earlier commit is not green on this one.
5. Never mark a human line. Not even with Tyler's verbal say-so in chat: the line exists so the act happened.
