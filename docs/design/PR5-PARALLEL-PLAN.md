# PR 5 execution plan: migrate 280 figures across 16 surface groups

PR 5 is the largest PR in the plan and the one most likely to stall. It is not one PR's worth of serial work; it is six mostly independent file sets. This is how it gets done without waiting.

## The constraint that makes parallelism safe

Each surface group touches a disjoint set of files. The shared pieces are exactly three, so they go FIRST, alone, and merge before any screen worker starts:

**Wave 0, serial, one worker.** `docs/METRICS.md` group 2.3, the shared components: `ShiftDayRow`, `HeroBreakdownDrawer`, `NightlyEarningsChart`, `ShiftContextMenu`, `UndoDeleteToast` (10 rows). Every screen renders at least one of these. Migrating them first means each screen worker changes only its own facts struct, and two workers can never both be editing `ShiftDayRow`.

Wave 0 also lands the adapter contract itself: each screen's `Facts` struct keeps only presentation and takes `EarningsSnapshot` plus its own presentational inputs, with the `Key`/`dataRevision` pattern deleted in favour of the snapshot's stamp. Write that shape once, in the shared components, so five workers do not invent five shapes.

## Waves 1 and 2, parallel worktrees, one worker each

| Wave | Group | Rows | Files | Notes |
|---|---|---|---|---|
| 1 | 2.2 Calendar + day detail | 8 | `CalendarView`, `DayDetailSheet` | Smallest, and it carries the audit's worst confirmed bug: tiles summing raw row net. Do it first for the morale of a green parity test. |
| 1 | 2.4 History | 27 | `PeriodsView`, `PeriodDetailView` | Carries the $/hr coverage fix and the back-derived tip-out. |
| 1 | 2.1 Dashboard | 32 | `DashboardView` | Largest single file; the hero, drawer, payday moment, reveal echo. |
| 1 | 2.8 Log + Backfill | 25 | `LogTipSheet`, `BackfillSheet`, `ShiftBeliefLine` | Needs `preview(draft:)` so the pre-save header equals the saved row. |
| 2 | 2.6 + 2.7 Insights | 62 | `InsightsView`, `InsightsNumbersGrid`, `InsightsFactsCopy`, `InsightsService`, `PlanForwardCopy` | Biggest row count. Wave 2 because it consumes `StatsEngine` fed by `[ShiftValuation]`, which wave 1 settles. Group 2.7 is dormant code: decide per row whether to migrate or delete, and say which. |
| 2 | 2.5 Paycheck | 18 | `PaycheckEntrySheet`, `PaycheckAudit`, `PredictedPaycheck` → `PaycheckReconciler` | Also fixes the ±100c correction becoming a proposal the user accepts rather than a silent rewrite. |
| 2 | 2.9 + 2.15 + 2.12 | 9 | `OnboardingQuiz`, `SettingsView`, `PaydayPushScheduler` | Small, bundle them. The notification is the one place a dollar figure is spoken without a screen. |

Groups 2.10 (Siri), 2.11 (widget), 2.13 (CSV), 2.14 (backend) and 2.16 (sync) are **PR 6**, not PR 5. Do not let a PR 5 worker touch them.

## The rule that makes each screen's migration checkable

A screen is done when, and only when:

1. Every row of its group in `docs/METRICS.md` reads its value from `EarningsSnapshot`, and the row's `MetricID` column is satisfied by what the code now asks for.
2. Its parity test passes against the **real adapter**, not a helper. The relevant invariant from the goal, for that screen.
3. The completeness presentation rules hold: `.partial` never renders "Total"; a failed read never renders `$0`; `.estimated` carries its caption.
4. The completeness critic is re-run **for that screen's files only** and comes back dry. The inventory is a floor, not a ceiling: expect each screen to surface one or two figures the sweep missed, and append them.
5. No `Key`/`dataRevision` remains in that file, and no raw money arithmetic outside the adapter.

## Sequencing against the rest

Wave 0 cannot start until PR 4 (the snapshot and its store) merges, because there is nothing to read from. So the real order is: PR 2 slices → PR 3 ledger → PR 4 snapshot → PR 5 wave 0 → waves 1 and 2 in parallel → PR 6 → PR 7 → PR 8.

Four parallel workers in wave 1 and three in wave 2 turns the largest PR in the plan into roughly two serial screens' worth of wall-clock, which is the difference between PR 5 finishing and PR 5 being where this project stops.

## What to watch for

- **Two workers touching one file.** If a screen needs a shared-component change that wave 0 missed, it stops and the change goes to a wave 0 follow-up merged alone. It does not get made twice.
- **A screen "migrated" that still computes.** The lint rules from S1 catch the obvious cases; the parity test catches the subtle ones. A screen that passes parity but still holds arithmetic is not done.
- **Insights basis drift.** Group 2.6 and 2.7 are where the audit found tips-only figures sitting under wage-inclusive headlines. Every comparison must declare its basis, and a comparison that mixes complete and incomplete observations falls back and says so.
