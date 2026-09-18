# PaydayCore release gate

Pass/fail, not a score. No line is satisfied by an argument; each names the command or the act that produces it. Tied to a specific release-candidate commit, not to "the branch".

Two kinds of line. **Machine lines** a session can run and must keep green. **Human lines** that physically need Tyler's phone, his pay period, or a professional's judgement, and that no session may mark done. A goal that reports complete with an open human line is lying.

Status legend: `[ ]` not yet, `[x]` green with evidence recorded below it, `[H]` human line, never checkable here.

---

## Candidate

- Commit: _fill in at candidate time_
- Build number: _MDDYY+seq_
- Date: _fill in_

## Machine lines

### Engine correctness
- [ ] `swift test --package-path Packages/PaydayCore` green. Record the `Test run with N tests in M suites` line.
- [ ] App suite green. Record the **Swift Testing** total, not the `Executed N tests` lines, which count only the two XCTest files and have hidden a real failure before. Must be at or above the then-current baseline.
- [ ] All 14 golden fixtures (W1-W3, N1-N3, M1, H1, P1, E1, S2, Z1, T1, C1) pass **against the real production engine and screen adapters**, not a test helper. The original `CalendarDayTotalTests` passed for years while testing a formula the calendar did not use.
- [ ] `PAYDAYCORE_RELEASE_GATE=1 swift test --package-path Packages/PaydayCore --filter KnownIssuesGate` green, with `Fixtures/KnownIssues.json` empty. A pending known issue blocks the release; it is not a note.

### Parity, on real adapters
- [ ] Dashboard period income == History period row == period detail.
- [ ] Calendar day == day detail == sum of that day's shifts == the chart point for the same metric.
- [ ] Month == sum of its days. Pay period == sum of its eligible ledger entries. YTD clips periods crossing the year boundary rather than summing whole overlapping periods.
- [ ] Siri == widget == in-app current period, for the same `asOf` and source revision.
- [ ] A shift's wages sum across day, month, pay period and year to the same cents, including a workweek that straddles a month boundary.

### Honesty of state
- [ ] A failed read is never rendered as `$0`. Verified by breaking the widget's store access in a debug build and seeing "Couldn't load".
- [ ] `.partial` completeness never renders the word "Total". Verified by removing hours from one shift and reading the headline.
- [ ] Wages estimated from the legacy rate carry their caption until the rate-history prompt is answered.
- [ ] The overtime policy is presented as an estimate everywhere it appears.

### Boundaries
- [ ] Money-boundary lint rules green, and each one proven to fire by planting a violation in a scratch copy.
- [ ] Every superseded calculation path deleted, not wrapped. `grep` for the retired symbols returns nothing outside the engine and its adapters.
- [ ] Package imports Foundation and CryptoKit only.
- [ ] `docs/PRODUCT.md` Pillar 8 describes what the engine actually guarantees, with no claim the tests do not back.

### Data lifecycle
- [ ] Interrupted save, retry replay, offline edit then reconnect, delete then sync, account switch mid-request, midnight rollover, and a device timezone change all pass with no lost, duplicated, or cross-account record.
- [ ] A shift moved across a workweek boundary re-values both weeks.
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

- [ ] Zero entries remain in this table, and `grep -rn withKnownIssue PaydayTests/` returns nothing.

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

Neither cause is a code failure. Two were a race in our own workflow; one was a GitHub API rate limit while `supabase/setup-cli` resolved `version: latest`. Both are fixed: pushes key the concurrency group on `github.sha`, so no merge commit can cancel another, and the CLI is pinned to an explicit version so `supabase db reset` cannot change behaviour with no change in this repo.

**The honest claim, and the only one a re-run earns.** Re-running those three commits runs them against the workflow **as it stands now**, not as it stood that afternoon. A green re-run therefore proves:

> every PR-0-8 commit's tree passes CI on the current workflow

and it does **not** prove "CI was green at the moment each commit merged." That verdict was cancelled or flaked, and it cannot be reconstructed. The current-tree claim is the one that matters for shipping, which is why it is the line below. The historical claim is not recoverable, and a green tick here must not be recorded as if it were.

- [ ] Every merge commit in PRs 0-8's history has a completed, successful CI run **on the current workflow**. Record the run id per commit. `gh run list --branch production --limit 40 --json headSha,status,conclusion`
- [ ] No merge commit's run is `cancelled`. A cancelled run is not a pass and not a failure; it is an absence, and in a listing an absence reads like neither.

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
