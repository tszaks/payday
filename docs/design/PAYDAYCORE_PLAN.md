# Payday: PaydayCore, the one earnings engine (Option B, revision 2)

## Context

An external audit of tszaks/payday (audited at 8c1e20f; verified by me against HEAD 1d973ff on 2026-09-17, every claim reproduces in source and all eight of its isolated Swift checks pass on this Mac) found that Payday shares helpers but not the *interpretation* of its records. The same stored shifts produce different answers on different surfaces:

- Wages rounded per shift (calendar tiles, shift rows) vs per workweek (month, period, Dashboard, Siri, widget). 1c gaps on ordinary data.
- Month/period/YTD callers filter entries to a range and *then* compute weekly overtime, so a >40h week straddling a boundary loses its overtime ($11.31 in the worked example below).
- `PaySchedule.firstWeekday` is documented as the calendar-grid start and lives under Settings > Calendar, yet is the only input to the overtime workweek.
- `CalendarView` sums `TipEntry.netCents` row by row (double-subtracts a duplicated tip-out); every other reader resolves once per shift. `CalendarDayTotalTests` tests the day-detail formula, not the calendar's.
- `StatsEngine.shiftFacts` normalizes receipt gratuity per record with no metrics-owner guard, so a duplicated legacy receipt payload makes StatsEngine and TipBreakdown disagree.
- Charts and all of Insights are tips-only while headlines above them include wages, both labelled "earnings". The widget's circular/inline faces label a wage-inclusive number "Tips".
- Period $/hr divides the whole wage-inclusive hero total by only the hours that were logged; $/hr is also computed inline in LogTipSheet and separately in StatsEngine.
- CSV rounds hours to quarter hours (contradicting PRODUCT.md's 2026-07-19 "punches are literal" ruling), writes raw `paidTipsCents` where the UI shows `reconciledPaidTipsCents`, and uses its own `%.2f` formatter.
- Dashboard/Siri/widget mix an as-of-today tips cutoff with whole-period wages. The widget renders a failed fetch as $0. `PaycheckEntrySheet` caches its audit with no key.
- A wage-only or gratuity-only shift with hours writes zero rows (`ShiftWriter.insertShift:41-51`); the hours are lost.
- `PayPeriodCalculator.init` and `StatsEngine.init` force `TimeZone.current`, so travelling reprices history.
- Backend: `payday-api/index.ts` computes net per row, dates a shift by its LATEST row while iOS uses the EARLIEST (a backend test asserts the opposite of the app), `getShift` filters on `shift_id` alone, and the gratuity v1/v2 rule is implemented three times (Swift, TS, SQL) with only the TS copy tested. The backend has no wage concept, so `/v1/summary` and the app answer "how much this period" with different numbers by construction.
- The root cause of most normalization code: a shift is stored as a cash row plus a credit row, with shift-level facts living on whichever row is "canonical".
- `docs/PRODUCT.md` Pillar 8 declares the "Earnings Engine" DONE. It overclaims.
- No CI exists. 609 Swift Testing cases run hosted in the app target (simulator required). The widget shares code by listing 24 app files twice in `project.yml`; no Swift package exists.

Tyler chose **Option B: the full PaydayCore**, judged on architectural merit, not timing, and after Codex's review of revision 1 chose to **pay off the storage debt now with a real Shift entity**. The governing rule:

> The same metric, date scope, cutoff, source revision, compensation policy, and engine version must return the same integer-cents result and the same completeness state on every consumer.

## Decisions made (Tyler, 2026-09-17)

1. **Backend authority = app-published snapshots** computed by PaydayCore on-device, accepted by Supabase only against a server-issued dataset revision (Design 3). The TS/SQL money math is retired.
2. **Default basis = wage-inclusive everywhere.** Anything labelled "earnings" or "Total" is voluntary tips + gratuity/fees - tip-out + allocated wages. Tips-only figures are labelled "Tips".
3. **Real `ShiftRecord` entity now.** One row per shift on device and server; `TipEntry` pairs are migrated and retired.
4. Codex's review corrections adopted: golden fixture = 2759c; payroll timezone frozen, never device-following; server watermark for snapshots; snapshot revision covers shifts, paychecks, schedule, policies, engine; explicit partial-earnings presentation rules; rate history split from payroll-calendar policy; no fabricated historical rate; SHA-256 for input identity; a release-gate test asserting zero known issues.

## Assumptions stated (not asked)

- Overtime policy stays 40h / 1.5x on the base rate, presented as an estimate. Tip-credit regular-rate math (29 CFR 531.60) is out of scope; validating the supported policy with a payroll professional is a tracked Tyler task.
- Shift work date = the date the user logged (single field on `ShiftRecord`), so the earliest/latest ambiguity disappears with the two-row model.
- Feature freeze on anything that adds or changes an earnings metric while PRs land. 1.0.1 onboarding is UI-only and may continue.
- Existing data volume is TestFlight-scale; the device and server migrations are additive and reversible (old tables kept until PR 8).

## Target architecture

```
SwiftData ShiftRecord / PaycheckRecord     PolicyStore (rate history + payroll calendar)   PayScheduleStore
                 |                                      |                                        |
                 v         adapters: plain value copies, on the main actor                       v
   +-----------------------------------------------------------------------------------------------+
   |  PaydayCore  (local SwiftPM package; Foundation only)                                          |
   |   Input:      ShiftInput, PaycheckInput, PayRatePolicy, PayrollCalendarPolicy, PaySchedule     |
   |   Ledger:     CompensationLedger -> [ShiftValuation]  (wages allocated per shift, once)         |
   |   Queries:    EarningsSnapshot.shift/day/month/payPeriod/ytd/range -> EarningsResult           |
   |   Paycheck:   PaycheckReconciler (observed vs expected, corrections as proposals)               |
   |   Analytics:  StatsEngine (moved in, fed [ShiftValuation], basis-consistent comparisons)        |
   |   Copy:       MetricLabel, Money, HoursFormatting, presentation rules for completeness          |
   |   Export:     CSVRows                                                                          |
   +-----------------------------------------------------------------------------------------------+
                 |  immutable EarningsSnapshot { stamp: InputManifest digest + generation }
        +--------+---------+----------------+------------------+
        v                  v                v                  v
   App screens        Widget / Siri       CSV file          SnapshotUploader (after full sync,
   (thin adapters)   (buildOnce over      writer            stamped with server dataset_revision)
                      shared store)                                  |
                                                            Supabase earnings_snapshots
                                                            payday-api /v1/summary reads it, no math
```

## Module and file layout

New local package `Packages/PaydayCore/` referenced from `project.yml` (`packages: PaydayCore: { path: Packages/PaydayCore }`), linked into `Payday`, `PaydayWidget`, `PaydayTests`. The 24 duplicated source entries in `project.yml:105-130` shrink to SwiftUI/process-specific files (DesignSystem, TipEntrySheetTarget, DeepLinkCoordinator, intents, ShiftSession*, the new `Earnings/` adapters).

```
Packages/PaydayCore/
  Package.swift                      swift-tools 6.2, platforms [.iOS(.v26), .macOS(.v15)], language mode 6
  Sources/PaydayCore/
    Values/      Money.swift (moved), CivilDay.swift, DayRange.swift, YearMonth.swift, WorkedMinutes.swift
    Input/       ShiftInput.swift, PaycheckInput.swift, ReceiptMetrics.swift (moved ShiftReceiptMetrics)
    Policy/      PayRatePolicy.swift, PayrollCalendarPolicy.swift, PaySchedule.swift + PayPeriodCalculator.swift (moved, explicit calendar)
    Ledger/      CompensationLedger.swift, ShiftValuation.swift, EarningsComponents.swift
    Query/       EarningsSnapshot.swift, EarningsResult.swift, MetricID.swift, Completeness.swift, InputManifest.swift (SHA-256)
    Paycheck/    PaycheckReconciler.swift (absorbs PredictedPaycheck, PaycheckAudit, reconciledTipsCents)
    Analytics/   StatsEngine.swift (moved; input [ShiftValuation]; comparisons declare their basis)
    Copy/        RevealCopy.swift (moved), MetricLabel.swift, HoursFormatting.swift, CompletenessCopy.swift
    Export/      CSVRows.swift
    Snapshot/    SnapshotDocument.swift (JSON schema v1 for upload)
  Tests/PaydayCoreTests/   `swift test` on macOS, no simulator; Fixtures/*.json shared with the Deno test
```

Stays in the app target: SwiftData models (`ShiftRecord`, `PaycheckRecord`, legacy `TipEntry` until PR 8), stores, sync, views, intents, widget, `Earnings/ShiftInputAdapter.swift`, `Earnings/EarningsStore.swift`, `Earnings/SnapshotUploader.swift`, `ShiftCommands.swift`.

## Design 0: ShiftRecord (the storage model)

SwiftData `@Model final class ShiftRecord` (CloudKit-safe defaults kept even though CloudKit is off):
`id: UUID`, `workDate: Date` (start of day, in the payroll timezone at write time; see Design 1 on CivilDay), `period: ShiftPeriod?`, `cashTipsCents: Int = 0`, `creditTipsCents: Int = 0`, `tipOutCents: Int?`, `salesCents: Int?`, `hoursWorked: Double?` (kept as the minute-exact decimal `ShiftTimes` produces), `clockIn: Date?`, `clockOut: Date?`, `serverCount: Int?`, `receiptMetricsJSON: String?`, `note: String?`, `recordedAt: Date?`, `modifiedAt: Date`, `legacyEntryIDs: [UUID]` (provenance of the migrated TipEntry rows).

Supabase `public.shifts` mirrors it (`cash_tips_cents`, `credit_tips_cents`, `hours_worked numeric`, `work_date date`, `receipt_metrics jsonb`, `legacy_entry_ids uuid[]`, `client_updated_at`, `updated_at`, `deleted_at`, `version`) with the same RLS, `touch_versioned_row` trigger, and conflict-safe `import_shifts` / `upsert_shifts` RPCs modelled on the tip-entry ones (`client_updated_at >=` gate).

Migration (device, `MigrationRunner` version 3): group `TipEntry` by `shiftID ?? ShiftDays.deterministicShiftID`, build one `ShiftRecord` per group using today's `ShiftDetails.resolve` + `TipBreakdown.total` rules (this is the last time those rules run), record `legacyEntryIDs`, and keep `TipEntry` rows read-only until PR 8. Migration (server, SQL): `migrate_tip_entries_to_shifts(user_id)` with the same grouping, invoked by the app after its local migration and before its first shift sync; idempotent on `legacy_entry_ids`. Sync switches to `shifts` in PR 2; `tip_entries` becomes read-only on the server (RPCs revoked) in PR 8.

Consequences: `ShiftDetails`, `TipBreakdown`, `ShiftDays.groupedByShift`, `ShiftWriter`'s two-row logic, and the credit-owns-metadata rule all disappear. A wage-only or gratuity-only shift is simply a `ShiftRecord` with zero tips. Receipt v1/v2 normalization (`ShiftReceiptMetrics.voluntaryTipsCents`) is applied exactly once, at migration, so `creditTipsCents` is always voluntary and `gratuityFeesCents` always separate; new scans already write v2.

## AMENDMENT 2026-09-17 (supersedes the hard-cutover amendment): PR 2 = THE SERVER CONVERTS, NO LOCKOUT

PR 2's shape was decided three times. The first two were killed by adversarial review, each on a premise that turned out to be false.

**Shape 1, both representations alive and reconciled on the device.** Produced 4 P0 money-loss paths, 11 P1s, then 3 further P0s inside its own fix stack, reaching 487KB. Worst: undo of a legacy-derived shift destroyed it permanently, and every account derived the same shift UUID for the same work date. Every P0 lived in the device-side reconcile machinery.

**Shape 2, hard cutover with old builds locked out of writing.** Produced 16 P0s and 15 P1s. Fatal premise: **Payday 1.0 is already shipped and contains no handling for a rejected write.** A lockout therefore does not prompt "please update"; the app goes dark, and a fresh 1.0 install can never reach its own data. The lockout also bricked the very drain sequence meant to rescue unsynced rows.

**Shape 3, final: the server converts on arrival.** A Postgres trigger on `public.tip_entries` folds every incoming legacy write into the shift representation in the same transaction, calling the same conversion function the one-shot per-account migration calls.

- Exactly one deriver (SQL) and one direction (legacy to shift). The device never reconciles, sweeps, claims, merges, or derives a shift.
- `public.shifts` is authoritative for reads. `tip_entries` stays the legacy write surface indefinitely, converted on arrival.
- Old builds keep working exactly as they do today and never learn anything changed. New builds read and write shifts. Both are correct at all times.
- Deleted for good: `shift_legacy_claims`, every sweep arm, `ShiftDivergence`, claim merges, `released_legacy_entry_ids`, replicated `ShiftTombstone`s, the version floor, `assert_write_allowed`, `drain_tip_entries`, drain-then-lock, the freeze, and every "please update" surface.
- Rollback becomes close to trivial, because `shifts` is derived rather than primary: stop reading it.

Live design: `/tmp/paydaycore/PR2-design-final.md`. Historical and superseded: `PR2-design-base.md` (shape 1), `PR2-amendments.md` (shape 1 fixes), `PR2-design-cutover.md` (shape 2). The final design carries a harvest ledger so all three rounds stay auditable.

Facts measured on Postgres 17.11 during these rounds, binding on the implementation: a non-numeric `earningsSchemaVersion` makes a numeric cast inside a CHECK abort the statement uncatchably, so guard with `jsonb_typeof` first; receipt payloads with that key absent are live in production data, so a CHECK demanding v2 rejects real rows; a security-invoker RPC calling into schema `private` fails 42501 and needs a definer wrapper that captures `auth.uid()` first; `public.shifts` needs `primary key (user_id, id)` and composite foreign keys; and Payday build numbers (MDDYY+seq) are not monotonic as integers because months lack a leading zero.

## Design 1: CompensationLedger (value each shift once)

**Arithmetic: integers only.** Hours become `minutesWorked: Int` at the adapter (`Int((hoursWorked * 60).rounded())`, lossless for every value `ShiftTimes` produces). Rate in cents, multiplier in hundredths (150), threshold in minutes (2400). Exact wage numerators in units of 1/6000 cent: `regular = rate * minutes * 100`, `overtime = rate * minutes * multiplierHundredths`. Half-up `roundCents(x) = (2x + 6000) / 12000`. Reproduces today's `.rounded()` on positive values. Decimal rejected: 1/60 is non-terminating in base 10.

**Two policy types, not one:**
- `PayRatePolicy { id, effectiveFrom: CivilDay, hourlyRateCents: Int, provenance: .confirmed | .assumedFromLegacySetting }`. May change on any day; the weekly threshold is continuous across a rate change.
- `PayrollCalendarPolicy { id, effectiveFrom: CivilDay, workweekStartWeekday: Int, overtimeThresholdMinutes: Int = 2400, overtimeMultiplierHundredths: Int = 150, payrollTimeZone: TimeZone }`. `effectiveFrom` MUST fall on a workweek start under the *previous* calendar policy; the Settings UI snaps any chosen date to the next such boundary, and the engine rejects (diagnostic, falls back to the previous policy) any stored policy that does not. This makes overlapping or broken workweeks unrepresentable.

**Frozen payroll timezone.** `payrollTimeZone` is captured when the calendar policy is created (device zone at that moment) and changes only when the user creates a new calendar policy. `CivilDay(date, in: policy.payrollTimeZone)` is therefore stable when the device travels. Nothing observes `NSSystemTimeZoneDidChange` for money. (`workDate` on `ShiftRecord` is already a civil day; the adapter converts with the policy zone in effect on that date.)

**Types** (`public Sendable Hashable Codable`, Foundation only): `CivilDay`, `DayRange` (inclusive, `clamped(to: asOf)`), `YearMonth`, `ShiftInput { id, workDay, period, recordedAt, voluntaryCashCents, voluntaryCreditCents, gratuityFeesCents, tipOutCents?, minutesWorked? }`, `EarningsComponents: AdditiveArithmetic` (cash, credit, gratuity, tipOut, regularWages, overtimeWages; `nonWageEarningsCents`, `wagesCents`, `earnedIncomeCents`), `WageValuation = .valued(WageComponents, assumed: Bool) | .unavailable(.rateNotSet | .hoursMissing | .noCalendarPolicy)`, `ShiftValuation { id, workDay, ratePolicyID?, calendarPolicyID?, workweekStart?, minutesWorked?, wage, components }`.

**Function:** `CompensationLedger.value(_ shifts: [ShiftInput], rates: [PayRatePolicy], calendars: [PayrollCalendarPolicy]) -> [ShiftValuation]`, pure, order-independent. `engineVersion = 1`.

**Algorithm:**
1. Calendar policy = last with `effectiveFrom <= workDay`; none → `.noCalendarPolicy`, tips only. Rate policy likewise; none → `.rateNotSet`.
2. Group by `workweekStart = workDay.startOfWorkweek(startingOn: calendar.workweekStartWeekday)` over ALL shifts, never the caller's range.
3. Order within week: workDay, period rank (lunch, dinner, nil), recordedAt, id.
4. Chronological threshold split: `regularMinutes = clamp(threshold - cumulative, 0, m)`, rest overtime. Nil hours → contributes 0, `.hoursMissing`. Nil rate → minutes still count toward the threshold, `.rateNotSet`.
5. Cumulative rounding per stream: `cents_i = roundCents(cum_i) - roundCents(cum_{i-1})`. Telescopes, so `Σ shift cents == roundCents(Σ exact)`; each shift within 1c of its naive rounding; a later shift never changes an earlier row.
6. Every aggregate anywhere is `Σ components` over the selected shifts.
7. A shift is attributed whole to its work day; never split across a workweek boundary.
8. A valuation under a rate policy with `provenance == .assumedFromLegacySetting` is `.valued(_, assumed: true)` and rolls up into completeness as "estimated".

**Worked example A** (4.25h + 5.5h at 283c, one week): exact 1202.75 + 1556.50 = 2759.25 → week **2759**. Allocated A = 1203, B = **1556**. The old per-shift path gave 2760. **The golden fixture expects 2759.** `roundsPerShiftNotPerTotal` is superseded.

**Worked example B** (Mon-start week Sep 28–Oct 4 2026, 48h, 283c): Mon 10.25h, Tue 9.75h, Wed 10.5h, Thu 11.5h (9.5 regular + 2 OT), Fri 6h (all OT). Regular 2901 / 2759 / 2972 / 2688 / 0 = 11320 = 40h·283c. OT 849 / 2547 = 3396 = 8h·424.5c. September (Mon–Wed) = 8632; October (Thu–Fri) = 6084; sum **14716**. Today's month-first path gives 8632 + 4953 = 13585, losing $11.31 of overtime; the additivity fixture asserts 13585 as the wrong number.

**Severing calendar from payroll:** `PaySchedule.firstWeekday` becomes grid-only. `PayrollCalendarPolicy.workweekStartWeekday` owns overtime. Migration (PolicyStore, one-time flag) creates the first calendar policy with `effectiveFrom = .distantPast`, `workweekStartWeekday = schedule.resolvedFirstWeekday` (freezing the old effective value, so nobody's overtime moves), `payrollTimeZone = TimeZone.current` at migration time. The migration does not touch `PaydaySettingsSyncClock`. Policies sync via a new `compensation_policies jsonb` column on `user_settings` (both RPCs updated) so the choice roams.

**No fabricated rate history.** Migration creates ONE `PayRatePolicy` from `baseHourlyWageCents` with `effectiveFrom = earliest shift workDay` and `provenance = .assumedFromLegacySetting`. Today's totals are unchanged, but every wage they contain is marked `assumed`, completeness reports "wages estimated from your current rate", and Settings > Payroll shows a one-time prompt: "Has your rate always been $2.83? [Yes, since I started] [It changed on…]". Answering converts the policy to `.confirmed` (optionally splitting it). Users with no wage set get no rate policy and every wage is `.rateNotSet`.

**Behavior changes accepted:** shift rows and tiles may move by 1c versus today; a shift row now carries its overtime share. LogTipSheet's pre-save header uses `preview(draft:)` so it equals the saved row.

**Tests (PaydayCoreTests/CompensationLedgerTests):** examples A and B to the cent; month additivity across the boundary (13585 asserted wrong); exactly-40h all regular; 45h → 5h OT; two weeks bucket independently; workweek start drives bucketing (Sat+Sun 25h each: Mon-start 10h OT, Sun-start 0); threshold-straddling shift splits 570/120 min; 200 seeded-random weeks telescope; per-shift deviation ≤ 1c; appending a later shift never changes earlier shifts; half-up at the cumulative step; nil rate → `.rateNotSet` with minutes counted; missing hours → `.hoursMissing`; overnight shift stays on its work day; rate change mid-week keeps the threshold continuous; calendar policy with a non-boundary `effectiveFrom` is rejected with a diagnostic; shift before the earliest policy → `.noCalendarPolicy`; shuffled input → identical output; 383/60h → 383 min → 1806c; assumed provenance propagates to `assumed: true`; a device timezone change does not alter any valuation (policy zone fixed).

## Design 2: EarningsSnapshot, InputManifest, EarningsStore

**InputManifest** (PaydayCore): a canonical, sorted, versioned encoding of ALL inputs that can change any result: `[ShiftInput]`, `[PaycheckInput]`, `PaySchedule`, `[PayRatePolicy]`, `[PayrollCalendarPolicy]`, `asOf`, `engineVersion`. `digest: SHA-256` over that encoding (CryptoKit is available on all Apple platforms; Foundation-only remains true for the arithmetic). Sub-digests are exposed too (`shiftsDigest`, `paychecksDigest`, `scheduleDigest`, `policiesDigest`) so the UI and tests can say *what* changed. Identity of the financial inputs uses SHA-256, not FNV.

**SnapshotStamp** `{ generation: UInt64 (monotonic, in-process), manifest: InputManifest.Summary (digests + counts), engineVersion, asOf: CivilDay, computedAt: Date, serverDatasetRevision: Int64? (set only when computed from a fully synced dataset; see Design 3) }`.

**Completeness** `{ totalShifts, shiftsWithHours, shiftsWageValued, shiftsWageAssumed, wageFeatureEnabled, state: .off | .complete | .estimated | .partial(missingHours: Int, missingRate: Int) | .noShifts }`.

**Snapshot** `{ stamp, completeness, shifts: [ShiftValuation], paychecks: [PaycheckReconciliation] }` with rebuilt indexes; `Codable`.

**Queries:** `shift(id)`, `day(_)`, `month(_, asOf:)`, `payPeriod(_, asOf:)`, `yearToDate(year:asOf:)`, `range(_, asOf:)`, `days(in:)`, `paycheck(periodEnd:)`. Each returns `EarningsResult { range, knownComponents (Σ all shifts; wages only where valued), coveredComponents (Σ shifts with hours), minutes, regularMinutes, overtimeMinutes, completeness, shiftIDs }`, `hourlyRateCents = coveredComponents.earnedIncomeCents * 60 / minutes` (half-up, nil when minutes == 0). `asOf` clamps the range end exactly as `StatsEngine.periodToDateTotal` does and applies to tips AND wages.

**Presentation rules for partial earnings** (in `CompletenessCopy`, enforced by the adapters, tested):
- `.complete` → plain amount, "Total".
- `.estimated` → plain amount plus caption "Wages estimated from your current rate" until the rate prompt is answered.
- `.partial` → the headline shows `knownComponents.earnedIncomeCents` with caption "wages missing for N shifts" (or "no rate set" when that is the cause); the word "Total" is replaced by "Known so far"; charts render partial days with a hollow bar; $/hr shows "N of M shifts".
- `.off` → amounts are non-wage and labelled "Tips" (or "Tips & gratuity").
- Analytics (`StatsEngine`): every comparison declares a basis. Weekday/lunch-dinner/best-night comparisons run on `earnedIncome` only when every observation in the comparison is wage-complete; otherwise they fall back to `nonWageEarnings` for that comparison and say so in the copy. No comparison ever mixes complete and incomplete observations.

**Adapter** (app + widget target): `ShiftInputAdapter.inputs(from: [ShiftRecord], calendars:) -> [ShiftInput]`, main actor, one receipt decode per shift.

**Store** (`@MainActor @Observable final class EarningsStore`): `state: .loading | .ready(snapshot, isRefreshing) | .unavailable(kind, last: snapshot?)`, `requestRebuild(reason:)`, `preview(draft:)`, `static buildOnce(...) -> Result<EarningsSnapshot, EarningsUnavailable>` for out-of-process callers. Triggers: `ModelContext.didSave`, `PaydaySettingsSyncClock.didChange` (schedule, rate, calendar policy), `PolicyStore.didChange`, `.NSCalendarDayChanged`, scene `.active`. Pipeline: 50 ms debounce → `generation += 1` on main → fetch + adapt on main → compute manifest → skip if digest and asOf unchanged → detached build → `guard g == generation` before publish. An older computation can never overwrite a newer one.

**Out-of-process: recompute, do not read a file.** Widget and `PeriodTotalIntent` call `buildOnce` over the shared store. Intents and controls already write to the store from other processes, so an app-written file would go stale by construction. `PaydayWidgetEntry.content = .setup | .redacted | .unavailable | .ready(...)`; a container-open or fetch failure renders "Couldn't load" with no currency text; Siri says "Payday couldn't read your shifts right now."

**Facts structs → thin adapters.** Every `Key` drops `entriesRevision`/`wageCentsPerHour`/`firstWeekday` and keys on `stamp`. Moves to the engine: Dashboard hero components and predicted paycheck; Calendar `dailyTotals`/`monthTotalCents`/hours; DayDetail total; ShiftDayRow amount (takes `ShiftValuation?`); PeriodDetail wages/hero/nights/$/hr/tipOut/gross/breakdown cents; PeriodsView rows and YTD; PaycheckEntrySheet computed wages; LogTipSheet header via `preview(draft:)`; CSV; widget and intent. Stays presentational: labels, period selection, payday phase, grid geometry, drawer ordering.

**Tests:** `EarningsSnapshotTests` (range == Σ days; month + month == range; pay period straddling a workweek keeps OT; asOf clamps like periodToDateTotal; hourly rate excludes uncovered shifts from both sides; completeness states incl. `.estimated`; YTD; manifest digest is order-independent with a fixed expected hex; editing a paycheck changes `paychecksDigest` only; changing the schedule changes `scheduleDigest` and period membership; Codable round-trip preserves every query). `EarningsStoreTests` (stale generation dropped; identical digest skips publish; fetch failure → `.unavailable` with last snapshot; settings clock triggers rebuild). `PolicyStoreMigrationTests` (calendar policy frozen from resolvedFirstWeekday once; rate policy assumed from earliest shift; sync clock untouched; confirming the prompt flips provenance). `CompletenessCopyTests` (each state's label and caption). Widget `unavailableContentRendersNoCurrency`.

## Design 3: Server-accepted snapshots (backend authority)

- `user_settings.dataset_revision bigint not null default 0`, incremented by trigger on every insert/update/delete of that user's `shifts`, `paycheck_records`, and `user_settings` rows (extends `touch_versioned_row`). This is the server-issued watermark.
- Sync protocol change (`PaydaySyncService`): after a full push/pull cycle with zero pending local changes, the pull response includes `dataset_revision`; the checkpoint stores it as `syncedDatasetRevision` together with the local `InputManifest.digest` at that moment.
- `SnapshotUploader` (app): when `EarningsStore` publishes a snapshot whose manifest digest equals `checkpoint.syncedDigest`, it uploads `upsert_earnings_snapshot(p_dataset_revision, p_engine_version, p_as_of, p_manifest_digest, p_payload jsonb)`. Otherwise it does nothing (local changes not yet synced; the next sync will publish).
- RPC rule (authenticated, own row): accept only if `p_dataset_revision = user_settings.dataset_revision` (still current) AND (`no existing snapshot` OR `p_dataset_revision > existing.dataset_revision` OR (`=` AND `p_engine_version >= existing.engine_version`)). Otherwise return `stale_input` and the app retries after its next sync. Cross-device monotonicity comes from the server revision, never from device clocks.
- `earnings_snapshots(user_id pk, dataset_revision, engine_version, manifest_digest, as_of, payload jsonb, uploaded_at)`.
- `GET /v1/summary` / `get_summary` return the stored payload's period/YTD/range results plus `{ dataset_revision, engine_version, as_of, stale: existing.dataset_revision <> user_settings.dataset_revision }`. When the API itself writes a shift the trigger bumps the revision, so `stale` flips true immediately and stays true until a device syncs, recomputes, and uploads.
- `payday_agent_summary` money math and `tipFacts`/`groupShifts` net computation are deleted; `list_shifts`/`get_shift` return `shifts` rows plus, when present, the snapshot's `ShiftValuation` for that id.
- Deno golden test loads the same JSON fixtures as the Swift tests and asserts payload round-trip and the `stale` rule.

## Metric registry (PR 1 deliverable, `MetricID.swift` + `docs/METRICS.md`)

| MetricID | Definition | Basis | Missing-data rule | Allowed labels |
|---|---|---|---|---|
| `earnedIncome` | cash + credit + gratuityFees - tipOut + regularWages + overtimeWages | work date | wages absent where `.unavailable`; result carries completeness; presentation rules above | "Total" (complete), "Known so far" (partial), "Earned", "You kept" (tipOut>0) |
| `nonWageEarnings` | same without wages | work date | none | "Tips" when gratuity==0, else "Tips & gratuity" |
| `voluntaryTips`, `gratuityFees`, `tipOut`, `regularWages`, `overtimeWages` | components | work date | wages `.unavailable` | as today's drawer rows |
| `expectedPaycheckTipsLine` | credit - tipOut, cash-only fallback (today's `PredictedPaycheck.tipsLineCents`) | pay period | | "Your check's tips line" |
| `expectedPaycheckGross` | tips line + gratuity + wages | pay period | wages `.unavailable` | "Expected" |
| `observedPaidTips` / `proposedPaidTipsCorrection` | stub field / ±100c inferred correction, separate, never auto-applied | pay date | | "Paid", "Looks like $X (accept?)" |
| `reconciliationDelta` | observed - expected per component | pay period | never added to income | "checked", red only when < 0 |
| `hourlyRate` | Σ earnedIncome over covered shifts / Σ hours over covered shifts | | nil without coverage; carries N of M | "Averaging $X/hr · N of M shifts" |

Every `EarningsResult` carries `metric`, `scope`, `asOf`, `manifest`, `engineVersion`, `completeness`.

## Implementation sequence

Each PR merges to `production` behind green CI. Every PR updates `docs/PRODUCT.md` Pillar 8 and `docs/METRICS.md`. Worker sessions implement one PR at a time from this plan; the main session verifies against the gates.

### PR 0: CI and package scaffold
- `.github/workflows/ci.yml`: A `swift test --package-path Packages/PaydayCore` (macOS runner); B `xcodegen generate && xcodebuild test -scheme Payday -destination 'platform=iOS Simulator,id=<runtime UDID>' -derivedDataPath /tmp/payday-dd`; C `deno test` in `supabase/functions/payday-api`; D `scripts/design-lint.sh`; E `supabase db reset` against a local Postgres to prove migrations apply.
- Empty package with `Money` moved in, wired into all three targets. Gate: CI green on a no-op; app and widget build.

### PR 1: Numerical contract, inventory, regression harness
- `docs/METRICS.md` = registry + consumer inventory (from the 2026-09-17 exploration).
- `MetricID`, `EarningsResult`, `Completeness`, `InputManifest` types (no engine yet).
- JSON fixtures with independently specified expected values: W1 4.25h+5.5h @283c → **2759c** with per-shift 1203/1556; W2 the 48h boundary week → 14716c, October carries 3396c OT, 13585c asserted wrong; W3 changing `firstWeekday` moves nothing; N1 duplicate tip-out rows → subtract once (migration fixture); N2 duplicated legacy receipt payload → gratuity once (migration fixture); N3 legacy nil-shiftID cash+credit same day → one shift (migration fixture); M1 chart point == day total; H1 shift with tips and no hours excluded from both sides of $/hr; P1 observed vs proposed correction both present, observed unchanged; E1 6h23m exports as 6.3833; S2 future-dated row excluded by asOf for tips and wages; Z1 wage-only 5h shift → 1415c; T1 device timezone change → identical valuations; C1 partial completeness → "Known so far" label.
- Known failures are tagged `knownIssue` so CI stays usable, AND a release-gate test `KnownIssuesGateTests.knownIssueCountIsZero` fails on any tag; it is excluded from the per-PR run and required by the release workflow in PR 8.
- Gate: every inventoried number has a MetricID; every finding has a fixture.

### PR 2: ShiftRecord, canonical input, mutation boundary
- `ShiftRecord` model + `shifts` table + RPCs + device Migration 3 + server migration function (Design 0). Sync moves to `shifts`; `TipEntry` becomes read-only.
- `ShiftInput`/`PaycheckInput` + `ShiftInputAdapter`. Receipt v1/v2 normalization applied once at migration.
- `ShiftCommands` (app target): create/edit/delete/undo/backfill/intent/accepted-scan all go through it; one logical shift saves atomically; `ShiftWriter` deleted. Wage-only and gratuity-only shifts save. `LogTipSheet.canSave` allows hours- or gratuity-only.
- `TipBreakdown`, `ShiftDetails`, `ShiftDays.groupedByShift`, `TipEntry.netCents` remain only inside the migration.
- Gate: migration is idempotent and order-invariant on fixtures N1–N3; every screen still renders identical numbers from `ShiftRecord` (bridge parity test); a shift written by the API appears in the app after sync as one record.

### PR 3: Policies and CompensationLedger
- `PayRatePolicy`, `PayrollCalendarPolicy`, `PolicyStore` (App Group UserDefaults JSON + `compensation_policies` column and RPC updates). Migrations per Design 1 (frozen calendar policy; assumed rate policy from the earliest shift). Settings > Payroll: rate, "Rate changed on…", "Workweek starts" (snaps to boundary), timezone shown read-only with "Change…" creating a new calendar policy, the rate-history prompt, estimate disclaimer. `baseHourlyWageCents` becomes a read-only view of the current rate policy until PR 6 removes the last readers.
- `PayPeriodCalculator` and `StatsEngine` take an explicit calendar/timezone; `TimeZone.current` removed from both.
- `CompensationLedger` per Design 1; `WageEstimate`/`PeriodIncome` become wrappers (deleted in PR 8). Superseded tests replaced.
- Gate: W1, W2, W3, T1, Z1 green through the ledger; a rate change on date X reprices only shifts on/after X; a calendar policy off-boundary is rejected.

### PR 4: EarningsSnapshot and EarningsStore
- Per Design 2. Injected via `.environment(earningsStore)`.
- Gate: one coherent revision per change; stale rebuild can never overwrite newer (injected delay test); `.unavailable` propagates; digests change only for the input that changed.

### PR 5: Migrate every in-app consumer
Order: Calendar + DayDetail + ShiftDayRow → PeriodsView + PeriodDetail + Dashboard → NightlyEarningsChart + Insights + InsightsNumbersGrid + InsightsFactsCopy + InsightsService prompt → LogTipSheet preview + reveal + PaycheckEntrySheet + PaycheckComparisonView + PaydayPushScheduler.
- Facts structs become presentational; `Key`/`dataRevision` deleted in favour of `stamp`.
- Chart and Insights on `earnedIncome` with basis-consistent comparisons; `InsightsNumbersGrid` HOURLY uses `hourlyRate` with "N of M"; tips-only survivors labelled per registry.
- `PaycheckReconciler` absorbs `PredictedPaycheck`, `PaycheckAudit`, `reconciledTipsCents`; the ±100c correction becomes a proposal the user accepts in `PaycheckEntrySheet`; observed field never rewritten. Red/green rule unchanged.
- Partial-earnings presentation rules applied on every headline; tip-out read from results, never back-derived.
- Gate: parity tests on the real adapters: Dashboard(period) == PeriodsRow(period) == PeriodDetail(period); CalendarDay(d) == DayDetail(d) == Σ ShiftDayRow(d) == chart(d); Month == Σ days; C1 green. `RenderFactsPerformanceTests` re-baselined.

### PR 6: Widget, Siri, export, backend authority
- Widget + `PeriodTotalIntent` via `buildOnce`; `.unavailable` never renders as $0; accessory faces relabel "TIPS" → "Total"/"Known so far"/"Tips" per completeness; `asOf: date` for tips and wages.
- CSV from `CSVRows`: exact decimal hours plus `h:mm`, `Non-wage earnings`, `Regular wages`, `Overtime wages`, `Earned income`, `Completeness`; paychecks as a separate section with observed and proposed values; `Money` formatting.
- Backend per Design 3: `dataset_revision` trigger, `earnings_snapshots`, `upsert_earnings_snapshot` with the acceptance rule, sync checkpoint carries `syncedDatasetRevision`, `SnapshotUploader`, `/v1/summary` reads the snapshot with `stale`, TS/SQL money math deleted, `getShift` uses `shifts.id`, Deno fixture test. `docs/PAYDAY_API.md` updated.
- Gate: Siri == widget == app for the same asOf and digest; export equals engine results; API summary equals the uploading device's snapshot and reports `stale` correctly; an older device's upload against a superseded revision is rejected (two-device test with the Supabase local stack).

### PR 7: Lifecycle hardening
- Atomic logical-shift save (single `context.save()` per command, rollback on throw); reveal fires only after local persistence.
- Sync: idempotent retries on `id`; documented last-client-write-wins by `client_updated_at`; deletions preserved across reconnect; late responses for a previous `supabaseCurrentUserID` rejected; account switch clears `EarningsStore` and the sync checkpoint.
- Lifecycle tests: interrupted save; retry replay; shift moved across workweeks re-values both weeks; offline edit then reconnect; delete then sync; account switch mid-request; midnight rollover; device timezone change leaves money untouched; upgrade from a pre-PaydayCore store fixture through Migration 3.
- Parsers produce candidates only.
- Gate: no lost, duplicated, or cross-account records under fault injection.

### PR 8: Proof, bypass removal, release gate
- Delete `TipEntry` model and `tip_entries` RPCs (table kept read-only one release, then dropped), `TipBreakdown`, `ShiftDetails`, `ShiftDays.groupedByShift`, `TipEntry.netCents`, `WageEstimate` wage math, `PeriodIncome`, `PredictedPaycheck`, `PaycheckAudit`, `CalendarDayTotalTests` helper, per-screen `Key` structs, `TipRecord`.
- Lint (`scripts/design-lint.sh` money-boundary rule): outside `Packages/PaydayCore`, no `.netCents`, no `cashTipsCents +`, no `tipOutCents ??`, no `* 1.5`, no `/ 100 / hours`; adapters allowlisted.
- "Explain this number" debug sheet: contributing shift ids, components, wage allocation, policy ids, manifest digests, diagnostics.
- Shadow comparison (one-off, DEBUG, old code on a git tag vs new snapshot over the same migrated store): every difference maps to a fixture ID.
- `docs/RELEASE_GATE.md` (pass/fail, tied to the RC build): fixtures + parity + lifecycle + `knownIssueCountIsZero` green; clean install and upgrade from the current TestFlight build on a real device; TestFlight soak across one pay-period close with a paycheck reconciled; no `.unavailable` shown as $0; no `.partial` shown as "Total"; policy disclaimer present.
- Branch protection on `production` requiring the CI jobs and the release workflow for tags.

## Verification (end to end)

1. `swift test --package-path Packages/PaydayCore` on the Mac, no simulator; all fixtures green; `knownIssueCountIsZero` green.
2. `xcodegen generate && xcodebuild test -scheme Payday -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath /tmp/payday-dd`; parity and lifecycle suites green.
3. `deno test` green including the shared-fixture round-trip and the `stale` rule.
4. `supabase db reset` applies all migrations; `upsert_earnings_snapshot` rejects a superseded `dataset_revision`.
5. On device, release config, upgraded from the current TestFlight build: two shifts 4.25h and 5.5h at $2.83 in one week → tiles sum to the month headline and the week reads $27.59; a 48h week across a month boundary → overtime appears in the second month and both months sum to the whole week; flip Settings > Calendar > First day → no total changes; change the device timezone → no total changes; enable/disable the rate → labels flip "Total" ↔ "Tips"; leave hours off one shift → headline reads "Known so far · wages missing for 1 shift"; answer the rate-history prompt → "estimated" caption disappears; break the widget's store access in a debug build → "Couldn't load", not $0; ask Siri → equals Dashboard; export CSV → `6.3833`; call `/v1/summary` → equals the Dashboard for the same digest, and reports `stale: true` after an API-side write until the phone syncs.
6. Shadow-comparison report: zero unexplained differences.

## Risks and how the plan handles them

- **Storage migration** is the largest new risk. Mitigations: additive (old table kept read-only until PR 8), idempotent on `legacy_entry_ids`, order-invariant fixtures N1–N3, bridge parity test in PR 2 proving every screen shows the same number before and after, upgrade-path test in PR 7, TestFlight-scale data.
- **Visible 1c and overtime changes on shift rows** are the intended result of "value once, sum everywhere"; the shadow comparison attributes each to a fixture.
- **Frozen payroll timezone** means a user who genuinely moves must create a new calendar policy at a workweek boundary; Settings makes that a two-tap action.
- **Assumed rate provenance** shows an "estimated" caption for existing users until they answer one prompt; that is the honest state of the data.
- **Snapshot upload requires a fully synced dataset**, so an offline device never publishes; the API's `stale` flag covers the gap.
- **Swift 6 concurrency**: models never cross to the detached build task; adapters run on the main actor; `EarningsStore` is `@MainActor`.
- **Payroll policy correctness** (tip credit) is out of engine scope and labelled as an estimate.
- **Delegation**: each PR is one worker slice with this plan as the spec; the main session verifies gates, never trusts "done".
