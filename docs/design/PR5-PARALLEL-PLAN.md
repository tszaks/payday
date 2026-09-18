# PR 5 execution plan: migrate 280 figures across 16 surface groups

PR 5 is the largest PR in the plan and the one most likely to stall. It is not one PR's worth of serial work; it is six mostly independent file sets. This is how it gets done without waiting.

## The constraint that makes parallelism safe

Each surface group touches a disjoint set of files. The shared pieces are exactly three, so they go FIRST, alone, and merge before any screen worker starts:

**Wave 0, serial, one worker.** `docs/METRICS.md` group 2.3, the shared components: `ShiftDayRow`, `HeroBreakdownDrawer`, `NightlyEarningsChart`, `ShiftContextMenu`, `UndoDeleteToast` (10 rows). Every screen renders at least one of these. Migrating them first means each screen worker changes only its own facts struct, and two workers can never both be editing `ShiftDayRow`.

Wave 0 also lands the adapter contract itself: each screen's `Facts` struct keeps only presentation and takes `EarningsSnapshot` plus its own presentational inputs, with the `Key`/`dataRevision` pattern deleted in favour of the snapshot's stamp. Write that shape once, in the shared components, so five workers do not invent five shapes.

### Wave 0 is DONE (2026-09-18). Read this before starting a wave 1 screen.

**The contract lives in [`Payday/Earnings/SnapshotFacts.swift`](../../Payday/Earnings/SnapshotFacts.swift).** Its header is the four rules, spelled out with the reason each one was paid for. Read that file first; everything below is a summary of it.

1. A `Facts` struct keeps only presentation. Money is not presentation.
2. It takes `EarningsSnapshot?` plus its own presentational inputs. Not `[TipEntry]`, not `wageCentsPerHour`, not `firstWeekday`, not a `TimeZone`.
3. No per-screen `Key` struct and no `dataRevision`. Conform to `SnapshotFacts` and cache on `(stamp, this screen's own selection)`.
4. Views render `EarningsFigure`, never cents. `.partial` never renders "Total"; `.unavailable` renders no currency at all.

New shared machinery, with the file to copy from:

| What | Where | What it replaces |
|---|---|---|
| `EarningsFigure` + `CompletenessCopy` | `Packages/PaydayCore/Sources/PaydayCore/Copy/CompletenessCopy.swift` | every screen's own `tipOut > 0 ? "You kept" : "Total"`, and every `$0.00` that meant "unknown" |
| `SnapshotFacts` protocol + the contract header | `Payday/Earnings/SnapshotFacts.swift` | the hand-maintained `XFactsKey` dependency lists |
| `ShiftDayRowFacts` | `Payday/Views/Shared/ShiftDayRow.swift` | `ShiftDayRow(entries:wageCents:)` |
| `BreakdownRow.ledgerRows(_:)` / `.total(_:)` / `.lipText(_:)` / `.hasBreakdown(_:)` | `Payday/Views/Shared/HeroBreakdownDrawer.swift` | Dashboard's and Period detail's two hand-composed copies of the same drawer, one of which back-derived its tip-out |
| `EarningsChartFacts(snapshot:range:timeZone:asOf:)` and `(wholeOf:timeZone:)` | `Payday/Views/Shared/NightlyEarningsChart.swift` | `EarningsChartFacts(nights:period:)` over `StatsEngine.nightlyTotals` |
| `EarningsComponents.grossBeforeTipOutCents` | `PaydayCore/Ledger/EarningsComponents.swift` | the four-term "Earned" subtotal both hero screens added by hand |
| `CivilDay.date(in:)` | `PaydayCore/Values/CivilDay.swift` | nothing; it is the inverse the chart's x-axis needed |

### The blocker wave 1 inherits: nothing writes `ShiftRecord` locally yet

`EarningsStore` reads `FetchDescriptor<ShiftRecord>`, and outside `PaydayTests/` nothing in the app constructs a `ShiftRecord`. PR 2 slices S5 through S8 (the one-shot conversion and the shift sync leg) are open, so **`earningsStore.snapshot` on a real device is an empty snapshot.** A screen that switches to it before S7 lands shows a person with years of shifts a blank page, and every test would still pass, because tests construct their own `ShiftRecord`s.

So wave 0 feeds the shared components a real snapshot built from the legacy rows: `LegacySnapshotBridge.snapshot(shifts:rateCents:payrollTimeZone:workweekStartWeekday:asOf:)`. It is the same `CompensationLedger`, the same `SnapshotStamp`, the same queries — only the input table differs, and `LegacySnapshotBridgeTests` proves its wages equal `WageEstimate.centsByShiftID`'s and its tips equal `TipBreakdown`'s, per shift.

**A wave 1 screen should use `LegacySnapshotBridge` too, and not `earningsStore`.** When S7 lands, the swap is one line per screen and nothing below it changes. That is what wave 0 was for. Put the swap in its own PR so a single revert undoes it.

### Call sites wave 0 already touched, and what it deliberately left

Changed to the minimum needed to compile and stay correct:

- `DashboardView.swift` — `DashboardFacts` gains `shiftSnapshot`; `wagesByShiftID` now reads off it instead of calling the ledger a second time; `shiftRow` builds a `ShiftDayRowFacts`.
- `PeriodDetailView.swift` — `PeriodDetailFacts` gains `shiftSnapshot` and `chartFacts`; `nightsInPeriod` is gone; the chart takes `EarningsChartFacts`.
- `DayDetailSheet.swift` — `DayDetailFacts` gains `snapshot`; `wagesByShiftID` is gone.
- `InsightsView.swift` — `InsightsPageFacts` gains `chartFacts` and takes `rateCents` / `workweekStartWeekday`; `recentNights` is gone; the key gains those two fields (it cannot become a stamp yet, because it also covers the `StatsEngine` facts this screen still computes).
- `RenderFactsPerformanceTests.swift`, `InsightsNumbersGridTests.swift` — rewritten for the new chart API. The granularity thresholds now count INCLUSIVE days, so a 22-day range is the first weekly one (was 23). A real 14-day period is `.day` either way.

Left alone on purpose, and therefore owed by the wave that owns the file:

- **Dashboard's hero drawer still composes its own rows** (group 2.1, wave 1). `BreakdownRow.ledgerRows(_:)`/`.total(_:)` exist for it; the swap needs the hero PERIOD's `EarningsResult`, which is the hero migration itself. Until then Dashboard's drawer can still print "Total" over a partial period.
- **Period detail's hero, $/hr caption, breakdown rows and paycheck section** (group 2.4, wave 1). Same, and its tip-out is still back-derived.
- **DayDetailSheet's hero** (group 2.2, wave 1). It is still `TipBreakdown` net plus Σ wages. Replacing it with `snapshot.day(_:)` is what finally closes the `withKnownIssue` in `EarningsParityTests`.
- **The `.partial` hollow bar.** `EarningsChartPoint.isPartial` is exposed and the chart's COPY rules are enforced, but the bar is not re-shaded: the fill opacity is already a magnitude encoding whose floor constants are a stated 3:1 accessibility contract ([SC-09]), and a second opacity term stacked on it breaks that. A real hollow bar is a stroked mark, which is a visual decision for the screens that own the chart (wave 2).
- **`WageState.noShifts` still renders `$0.00`.** Design 2 says `.noShifts` renders no currency figure, but Dashboard's empty period shows `$0.00` today and changing that is a hero decision, not a shared-component one. `CompletenessCopy` labels `.noShifts` "Total" and documents the deferral.

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
