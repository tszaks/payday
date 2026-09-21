# Goal: finish PaydayCore. Every PR, verified, merged.

Drafted 2026-09-17 for autonomous sessions. This file is the contract. Read it before doing anything, and re-read it after any compaction.

## The objective

Every number Payday shows, speaks, exports, or serves comes from one engine, and no two surfaces can disagree about the same fact.

Concretely: **PRs 0 through 8 of `~/.claude/plans/option-b-b-full-effervescent-kite.md` are merged to `production` with CI green, and the release gate in PR 8 passes.**

**Status, measured 2026-09-18 rather than estimated.** This sentence has been
stale in both directions before, so it names what is merged rather than
counting slices, which is the part that rots.

Merged: PR 0, PR 1, PR 3, PR 4, and all three waves of PR 5. Of PR 2: S1-S9,
S11 and S13, plus S9's second-half waves. Of PR 6: group 2.10 and 2.11 (the
widget and Siri read the engine), 2.13 (the CSV writes exact minutes), and
S11's deletion of the backend's duplicate money math. Of PR 8: the
money-boundary lint, which ratchets.

Open: PR 2's writer flip and the reader swaps it gates, S10 and S12; PR 6's
group 2.14 (the device-published snapshot, which is the only thing that can
give the `/v1` API a wage concept at all); PR 7 entirely; and PR 8's
deletions, which cannot begin until the flip lands because the screens still
read through the old paths.

Criteria 2, 3, 4 and 5 are green as of this date, each measured by running it
and recorded in `docs/RELEASE_GATE.md`. Criterion 6 is half done: the lint
side is in, the deletion side is blocked behind the flip.

**Status, measured 2026-09-21.** The 09-18 paragraph above is now stale in
the understating direction. Merged since: #135 (authority synthesis — new
accounts read `migrated_at` through the `shift_migration_state` view; the
"new account never flips" blocker is closed on production), #136 (the
deferred session re-check in `synchronize` — the apply path now defends
the forget-and-re-register window), #138 (`SyncWireFaultTests`, 25 tests,
the wire-level fault sweep). #137 (the PR 8 deletions — the dual
representation arm gone; `TipBreakdown`, `PredictedPaycheck`,
`PeriodIncome`, `ShiftWriter`, `LegacySnapshotBridge` and all eleven
flip-gated sites records-only) merged 2026-09-21 as `0f436df`. PR 7's list is closed including its
two reopened rows. What remains is not machine work: the device lines,
the upgrade/downgrade probes, the shadow comparison, and the human
review the gate keeps open. Evidence in `docs/RELEASE_GATE.md`, top
block, measured against `bf89da9`.

The governing rule, which every PR is measured against:

> The same metric, date scope, cutoff, source revision, compensation policy, and engine version must return the same integer-cents result and the same completeness state on every consumer.

## Definition of done

Done is not "the code is written." Done is all of:

1. All 9 PRs merged to `production`, each with its own CI green on the merge commit.
2. `swift test --package-path Packages/PaydayCore` green, and the app suite green with its **Swift Testing** total (see the traps below) at or above the then-current baseline.
3. Every one of the 14 golden fixtures passing against the real production engine, not a test helper.
4. `KnownIssuesGateTests.knownIssueCountIsZero` green with `PAYDAYCORE_RELEASE_GATE=1`.
5. The parity invariants from the plan hold on the real screen adapters: Dashboard equals the History row equals period detail; calendar day equals day detail equals the sum of that day's shifts equals the chart point; a month equals the sum of its days; Siri equals the widget equals the app.
6. Every old calculation path deleted, with the money-boundary lint rules in place so nothing can bypass the engine again.
7. `docs/PRODUCT.md` Pillar 8 tells the truth about what the engine actually guarantees.

## Authority granted (Tyler, 2026-09-17)

Work autonomously. Do not stop to ask permission for any of this:

- Build, review, gate, push, and **merge** each PR to `production` as its CI goes green.
- Create and delete your own git worktrees and branches.
- Apply Supabase migrations to the **production** database when their PR merges. Authorized explicitly. Before each one: dump or snapshot the affected tables first, apply the same migration to a scratch local Postgres from clean, and verify the result there. Report what you applied and what the row counts were before and after.
- Spawn as many agents and workflows as the work needs. Token cost is not a constraint; being wrong is.
- Fix bugs you find outside the plan's scope if they are losing or corrupting data. Ship them alone, ahead of the queue, as the `didSet` hotfix was.

## Hard stops (ask, and wait)

- Anything that would **delete or overwrite** Tyler's real earnings data beyond a reversible migration, including any destructive repair, truncate, or history rewrite.
- Submitting a build to App Store review, or changing anything about the 1.0 submission currently in review.
- Rotating, revoking, or publishing a credential.
- Changing `~/.codex/AGENTS.md`.
- Spending money.

## What physically needs Tyler, and how to park it

PR 8's release gate cannot be finished by a session: it needs his phone, a clean install, an upgrade from the current TestFlight build, and a pay-period close with a real paycheck reconciled. Also owed: a payroll professional validating the supported overtime policy, since the engine presents 40h/1.5x as an estimate.

So: take PR 8 as far as it goes, leave the device-and-soak checklist in `docs/RELEASE_GATE.md` with every machine-checkable line already green, and say plainly that the human lines are the only ones left. Do not fake them and do not call the goal complete while they are open.

## Process rules, each one paid for

**Measure, do not reason.** Two of today's biggest findings came from executing something rather than thinking about it: `didSet` never fires on a SwiftData model (four-way probe), and downgrading silently purges the new entity's rows (real store probe). When a design asks "does X happen", build the smallest thing that answers it.

**Never trust a worker's "done".** Verify against ground truth yourself. A worker reported `Executed 7 tests ... TEST SUCCEEDED` while CI logged `Test run with 609 tests in 99 suites failed`.

**The CI trap that hid a real failure.** The app suite is Swift Testing. `xcodebuild test | grep Executed` counts only the two XCTest files (7 tests). Always grep for `Test run with N tests in M suites`.

**Adversarially verify.** Give each finding independent skeptics with distinct lenses, prompted to refute, and default to refuted when uncertain. Every round so far found real P0s, including in its own previous round's fixes.

**When a design keeps growing and each review finds new defects in the fixes, the approach is wrong, not under-polished.** PR 2's shape died twice this way. Step back and find the single decision generating the complexity. The dual-representation design hit 487KB and four P0s; the lockout design hit 16 P0s because the already-shipped 1.0 build cannot handle a rejected write. The third shape is small because it deleted the premise, not the symptoms.

**A gate is a measurement, not a claim.** State the number you measured and the command that produced it. If something was not run, say so.

**Report on the live page as things happen**, per `~/.codex/LIVE_HTML.md`. Retractions go on it as loudly as the wins.

## Order of work, and what can run in parallel

- **PR 2** (13 slices; S1-S9, S11 and S13 merged as of 2026-09-18, leaving the writer flip, S10 and S12): S3 the deriver, S4 the trigger, S5 the one-shot and rollback were serial. The rest, sync, ShiftCommands, the agent API, the views, the parity test, can overlap once S5 lands. Design: `docs/design/PR2-design-final.md`.
- **PR 3** (policies and the CompensationLedger) is pure Swift over fixtures already merged. It does **not** depend on PR 2 and should run in parallel from the start.
- **PR 4** (the snapshot and its store) needs the ledger and `ShiftRecord`.
- **PR 5** (every consumer) is the largest surface: 280 inventory rows in `docs/METRICS.md`. Migrate in the plan's order, screen by screen, re-running the completeness critic per screen, because the inventory is a floor and not a proven ceiling.
- **PR 6** (widget, Siri, CSV, backend), **PR 7** (lifecycle), **PR 8** (deletion, lint, release gate) follow.

## Standing facts, so nothing is rediscovered

- Default branch is `production` (renamed from `szakacsmedia` on 2026-09-17).
- `xcodegen generate` from `project.yml`; never commit `Payday.xcodeproj`, `Generated/`, or `.build`. CI writes a secret-free `Secrets.local.xcconfig` because the real one is gitignored.
- Simulator: iPhone 17 Pro `E4FC6A8A-563B-4027-B246-242D123EB40B`. Always pass `-derivedDataPath` under `/tmp`.
- Wall-clock perf budgets scale 4x when `CI` is set. Do not delete them.
- Measured on Postgres 17.11 and binding: guard `jsonb_typeof` before any numeric cast in a CHECK, or a junk payload aborts the statement uncatchably; receipt payloads with `earningsSchemaVersion` absent are live in real data; a security-invoker RPC calling into schema `private` fails 42501 and needs a definer wrapper capturing `auth.uid()` first; `public.shifts` needs `primary key (user_id, id)`; clamp in numeric space or int4 still overflows.
- Payday build numbers are MDDYY+seq and are **not** monotonic as integers.
- Subagents run on Opus: `teamModel` in `~/.claude/settings.json`. A workflow captures the session model at launch, so pass `model: 'opus'` on every `agent()` call.

## Cadence

Report when each PR merges, when a design is killed, when a retraction is needed, and when a hard stop is hit. Otherwise keep going. Do not stop to ask whether to continue.
