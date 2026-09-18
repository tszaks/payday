Finish PaydayCore: every number Payday shows, speaks, exports or serves comes from one engine, and no two surfaces disagree about the same fact. Full contract: `docs/PAYDAYCORE_GOAL.md`; read it first and after any compaction. Plan: `docs/design/PAYDAYCORE_PLAN.md`. PR 2 design: `docs/design/PR2-design-final.md`.

DONE means all of these, not "the code is written":
1. PRs 0-8 merged to `production`, CI green on each merge commit. (0, 1 done; PR 2 is 3 of 13 slices.)
2. `swift test --package-path Packages/PaydayCore` green; app suite green with its Swift Testing total at or above the then-current baseline.
3. All 14 golden fixtures pass against the real production engine, never a test helper.
4. `PAYDAYCORE_RELEASE_GATE=1` and `knownIssueCountIsZero` green.
5. Parity holds on real screen adapters: Dashboard = History row = period detail; calendar day = day detail = sum of that day's shifts = chart point; month = sum of its days; Siri = widget = app.
6. Every old calculation path deleted, money-boundary lint rules in place so nothing can bypass the engine again.
7. `docs/PRODUCT.md` Pillar 8 tells the truth about what the engine guarantees.

AUTHORITY (Tyler, 2026-09-17), do not stop to ask: build, review, gate, push and MERGE each PR as CI goes green; make and delete your own worktrees; apply Supabase migrations to the PRODUCTION database when their PR merges, snapshotting the affected tables first and verifying the same migration on a scratch local cluster from clean, reporting row counts before and after; spawn as many agents and workflows as the work needs, since token cost is not the constraint and being wrong is; ship a data-loss bug found outside the plan alone and ahead of the queue, as the `didSet` hotfix was.

HARD STOPS, ask and wait: deleting or overwriting real earnings data beyond a reversible migration; touching the 1.0 App Store submission; credentials; `~/.codex/AGENTS.md`; spending money.

NEEDS TYLER PHYSICALLY: PR 8's release gate (his phone, clean install, upgrade from TestFlight, a pay-period close with a real paycheck) and a payroll professional validating the 40h/1.5x estimate. Take PR 8 as far as it goes, leave `docs/RELEASE_GATE.md` with every machine-checkable line green, say plainly that only the human lines remain, and never fake them or call the goal complete while they are open.

PROCESS, each rule already paid for:
- Measure, do not reason. `didSet` never fires on a SwiftData model, and a downgrade silently purges the new entity's rows: both found by building the smallest thing that answers the question.
- Never trust a worker's "done". A worker reported `TEST SUCCEEDED` while CI logged `609 tests in 99 suites failed`.
- The app suite is Swift Testing: grep `Test run with N tests in M suites`. The `Executed N tests` lines count 7 of them and have hidden a real failure.
- Adversarially verify: independent skeptics, distinct lenses, prompted to refute, defaulting to refuted when uncertain. Every round so far found real P0s, including in the previous round's fixes.
- When each review round finds new defects in the last round's fixes, the approach is wrong, not under-polished. PR 2's shape died twice this way. Find the one decision generating the complexity.
- A gate is a measurement, not a claim. Name the command and the number.
- Report to the live page as things happen; retractions as loudly as wins.

STANDING FACTS: all of them, including the Postgres CHECK-cast trap, the receipt-version payloads live in real data, the 42501 definer-wrapper rule, `primary key (user_id, id)`, numeric-space clamping, non-monotonic MDDYY build numbers, the simulator UDID, the 4x CI perf budgets and the Opus `teamModel` plus per-`agent()` model override, are in `docs/PAYDAYCORE_GOAL.md`. Read them there rather than rediscovering any of them.

CADENCE: report when a PR merges, a design is killed, a retraction is owed, or a hard stop is hit. Otherwise keep going, and never stop to ask whether to continue.
