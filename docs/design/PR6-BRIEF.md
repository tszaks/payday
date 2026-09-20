# PR 6 brief: the extensions, the export, and retiring the second authority

Surveyed on production at wave 2 time. 89 inventoried figures across five groups, and one of them is the whole reason this PR exists.

## What is actually still wrong

The backend is a **second, independently maintained money engine**. `supabase/functions/payday-api/index.ts` computes net per row in `tipFacts` (line 1325) and groups shifts in `groupShifts` (line 1342); `payday_agent_summary` computes the same figures again in SQL. So the gratuity v1/v2 rule exists in three places (Swift, TypeScript, SQL) and the API has no wage concept at all, which means `/v1/summary` and the app answer "how much this period" with different numbers **by construction**, not by accident.

Neither `SnapshotUploader` nor the `dataset_revision` watermark exists yet, so Design 3 of the plan is entirely unbuilt.

## The five groups, in the order I will do them

**2.14, backend, 48 figures.** The big one. Per Design 3: add `user_settings.dataset_revision` incremented by trigger on every write to that user's shifts, paychecks and settings; add `earnings_snapshots`; add `upsert_earnings_snapshot` whose acceptance rule is the server's own revision, never a device clock; build `SnapshotUploader` in the app to publish after a fully synced pass; make `/v1/summary` read the stored snapshot and report `stale: true` when the revision has moved past it; then **delete** `payday_agent_summary`'s money math and `tipFacts`/`groupShifts`' net computation. `getShift` also still filters on `shift_id` alone while every other path uses `coalesce(shift_id, id)`.

**2.11, widget and Live Activity, 17 figures.** `buildOnce` over the shared store, and the thing that must not regress: a failed read renders "Couldn't load", never `$0`. The accessory faces still label a wage-inclusive number "Tips".

**2.10, Siri, 8 figures.** Same `buildOnce` path. Siri, widget and app must agree for the same `asOf` and revision, which is a release-gate line.

**2.13, CSV, 10 figures.** Exact minutes (`6.3833`), not the quarter-hour rounding that contradicts the punches-are-literal ruling; named money columns that match engine metrics; paychecks as their own section rather than a value repeated on every shift row; observed and proposed corrections kept separate.

**2.16, cloud sync, 6 figures.** The shift sync leg, which is also PR 2's S6-S13. Landing it is what lets every migrated screen swap `LegacySnapshotBridge` for `earningsStore` in one line each.

## Order, and why

The sync leg (2.16 / PR 2's remaining slices) comes **first**, because until `ShiftRecord` is written and synced locally, every screen is reading through the legacy bridge and the widget has nothing to read at all. Then the backend, because it is the largest and most independent. Then the widget and Siri, which share one code path. CSV last; it is self-contained.

## Standing traps, already paid for

- The fold must never raise inside a shipped 1.0 build's transaction. Anything added to the write path inherits that rule.
- `when others` does not catch `57014`; guard `jsonb_typeof` before any numeric cast in a CHECK; a security-invoker RPC into schema `private` fails 42501 and needs a definer wrapper capturing `auth.uid()` first; clamp in numeric space or int4 still overflows.
- Mutate in one statement, assert in the next: one `SELECT` has one snapshot, and a test that reads a table a volatile function mutated in the same statement reads the pre-statement value and passes for the wrong reason.
- Supabase's `postgres` role is not a superuser, so suppress triggers with `ALTER TABLE ... DISABLE TRIGGER`, never `session_replication_role`.
- Wave 1's lesson: screens migrated separately disagree in ways their own tests cannot see. Anything touching two surfaces gets a cross-surface assertion, not two per-surface ones.
