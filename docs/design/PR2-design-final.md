# PR 2 (FINAL): The server converts. No lockout.

**Status: this document supersedes `PR2-design-base.md`, `PR2-amendments.md` and `PR2-design-cutover.md` in full. A worker implements PR 2 from this file alone and must not read the other three.**

Every code fact below was re-read in the live tree at `/Users/tyler/Projects/Payday` on 2026-09-17. Line numbers are from that read. Every Postgres fact marked *measured* was measured on local Postgres 17.11 and is not to be re-litigated, only obeyed.

**Revision 3 (2026-09-17).** A skeptic round returned 39 findings against this document's first draft: **14 P0, 19 P1, 6 P2**. **The shape survives.** No finding named a fatal premise, every one had a local fix, and a striking number were this document contradicting a rule it had already stated correctly somewhere else. Two of its own rules had to bend, both narrowed rather than abandoned: "never a union" becomes *one provably disjoint addition* (6.2), which was the only way to stop the write gate from reproducing shape 2's dark app through the write path; and "the conservation check raises on the RPC path" becomes *it never raises anywhere* (3.1, 5.3), because the raising version was unsatisfiable against two other rules in this same file and reversed, for the new build, the exact trade 4.6 makes for the old one. Section 15 lists every finding and its disposition, including the six where the skeptic was wrong about the code or the SQL.

---

## 1. Decision and scope

### 1.1 The shape

A Postgres trigger on `public.tip_entries` folds every incoming legacy write into the shift representation **in the same transaction**, by calling the **same** SQL conversion function the one-shot migration calls.

- Exactly **one deriver** (SQL) and exactly **one direction** (legacy to shift).
- The device **never** reconciles, sweeps, claims, merges, or derives a shift from legacy rows.
- `public.shifts` is authoritative **for reads** once an account's conversion is verified.
- `public.tip_entries` remains the legacy write surface **indefinitely**, converted on arrival.
- Old builds keep working exactly as they do today and never learn anything changed. New builds read and write shifts. Both are correct at all times.

### 1.2 Why shape 1 died (both representations alive, reconciled on the device)

Shape 1 kept `TipEntry` rows and `ShiftRecord` rows both live and made the **device** responsible for keeping them in step: claims (`shift_legacy_claims`), a launch sweep with six arms, a `ShiftDivergence` type, claim merges, released entry ids. Its fatal premise was that a phone holding partial knowledge can safely decide that a shift's sources changed. It cannot: it sees only the rows it has pulled. That produced 4 P0 money-loss paths, 11 P1s, then 3 more P0s inside its own fix stack, at 487KB, and **every P0 lived in the device-side reconcile machinery**. The reconcile job belongs where complete knowledge lives, which is the database.

### 1.3 Why shape 2 died (hard cutover, old builds locked out of writing)

Shape 2 raised a write-protocol floor, froze `tip_entries` with a rejecting trigger, and drained unsynced rows before the freeze. Its fatal premise was that a rejected write prompts "please update". **Payday 1.0 is already shipped (build 9112029) and contains no handling for a rejected write.** `PaydayRemoteRepository` throws, `PaydayCloudGate` lands in `.failed`, and the app goes dark with no upgrade path; a fresh 1.0 install can never reach its own data at all. The lockout also bricked the very drain sequence that existed to rescue unsynced rows, because the drain is itself a legacy write. 16 P0s and 15 P1s.

### 1.4 The rule that replaces both

**Nothing in the conversion path may ever fail an old build's write.** Not a raise, not a constraint violation, not a deadlock, not a statement timeout. Any abort inside the fold is shape 2 arriving through the back door: 1.0 retries the identical payload forever and never syncs. Section 4.6 makes this structural, not aspirational.

*Measured on PG 17.11, and the reason 4.6 is written the way it is:* PL/pgSQL's `exception when others` does **not** catch `57014 query_canceled`, which is exactly what `statement_timeout` raises, and does not catch `assert_failure` either. A `when others` handler wrapping `perform pg_sleep(3)` under `set statement_timeout='500ms'` never fires its `raise notice` and the statement aborts. So the one abort class this rule names by name is the one a bare `when others` cannot trap, and 4.6 lists `query_canceled` and `assert_failure` as their own arms.

### 1.5 Deliberately not built

Deleted for good, from both prior designs, with no replacement:

`shift_legacy_claims` and every claim collision / merge / release path; `released_legacy_entry_ids`; every sweep arm; `ShiftDivergence` and `ShiftDivergenceStore`; `LegacyShiftConverter`; replicated `ShiftTombstones`; the write-protocol version floor (`public.write_policy`, `min_write_version`, `PAYDAY_WRITE_PROTOCOL_VERSION`, `scripts/check-protocol-version.sh`); `assert_write_allowed`; `private.reject_frozen_legacy_write` and the `tip_entries` freeze; `legacy_writes_frozen_at`; `drain_tip_entries` and drain-then-lock; `retired_at`; every "please update" / `clientTooOld` surface; device-side Migration 3 as a deriver, with its local derive pass, `Migration3Verification`, `Migration3Receipt` and the pre-migration SQLite backup triple; `LegacyServerFact` and `checkpoint.legacyServerFacts`; `ShiftRecord.legacyDayKey` and `shifts.legacy_day_key`; the read-through `persisted UNION ALL derived` read surface; the legacy-union reader.

Deleted by round 3 of review, having been in this document's own first draft: `p_strict` and every raise on the RPC path (the fold path and the RPC path now behave identically, 4.6 rule 6); `ShiftDays.legacyShiftID` and the whole Swift md5 port of the identity function, which lost its last consumer when 6.4 kept minting generation 0; the claim that the gratuity `CASE` must be written twice (one `immutable` helper is legal inside a stored generated column, *measured*, 2.3).

Also **not** built in PR 2, on purpose: new agent write verbs for shifts (PR 6), deletion of the four legacy agent write verbs (they are now as safe as any old build's write), and deletion of `TipEntry` / `tip_entries` (see 1.6).

### 1.6 One consequence to write down now

Because `tip_entries` stays a permanently open write surface, **the plan's PR 8 is not reachable as written**. PR 8 was "delete `TipEntry`, `TipBreakdown`, `ShiftDetails`, `ShiftDays.groupedByShift`, `TipRecord`, the `tip_entries` table". Under this shape the legacy read path is permanent (see 6.2), `tip_entries` can never be dropped while any supported build writes it, and the trigger, the shared deriver, the gin index and the duplicate detector are permanent infrastructure rather than scaffolding. Their maintenance bar and their test bar are permanent too. The one fact that could ever end the transition is knowing no 1.0 install is still writing, so `shift_migration_state.last_legacy_write_at` (5.5) exists to answer exactly that in one query.

---

## 2. `ShiftRecord` and `public.shifts`

### 2.1 The Swift model

```swift
@Model
final class ShiftRecord {
    var id: UUID = UUID()
    var workDate: Date = Date.now { didSet { modifiedAt = .now } }
    private var shiftPeriodRaw: String? { didSet { modifiedAt = .now } }
    var cashTipsCents: Int = 0 { didSet { modifiedAt = .now } }
    var creditTipsCents: Int = 0 { didSet { modifiedAt = .now } }
    var tipOutCents: Int? { didSet { modifiedAt = .now } }
    var salesCents: Int? { didSet { modifiedAt = .now } }
    var hoursWorked: Double? { didSet { modifiedAt = .now } }
    var clockIn: Date? { didSet { modifiedAt = .now } }
    var clockOut: Date? { didSet { modifiedAt = .now } }
    var serverCount: Int? { didSet { modifiedAt = .now } }
    private var receiptMetricsJSON: Data? { didSet { modifiedAt = .now } }
    var note: String? { didSet { modifiedAt = .now } }
    var recordedAt: Date? { didSet { modifiedAt = .now } }
    private var sourceRaw: String? { didSet { modifiedAt = .now } }
    var legacyEntryIDsRaw: String? { didSet { modifiedAt = .now } }
    var modifiedAt: Date = Date.now
}
```

CloudKit rules, copied from `TipEntry` because they are why that model survived three schema changes: every attribute optional or defaulted; no `@Attribute(.unique)`, no `#Unique`; **no `@Relationship` to `TipEntry`** (provenance is a list of ids, not an edge, which is what keeps the legacy table immutable and rollback possible); enums as optional raw strings with a non-trapping accessor.

```swift
enum ShiftRecordSource: String, Codable, Sendable { case device, api, migration }
var source: ShiftRecordSource {
    get { sourceRaw.flatMap(ShiftRecordSource.init(rawValue:)) ?? .device }
    set { sourceRaw = newValue.rawValue }
}
```

The `?? .device` fallback earns its keep on day one, because the fold writes `'migration'`.

`legacyEntryIDsRaw` is a canonical `String` so two writers produce byte-identical rows: `Set(ids).map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")`, nil when empty.

**`receiptMetrics` is encode-only.** The setter encodes and mutates nothing else:

```swift
var receiptMetrics: ShiftReceiptMetrics? {
    get { Self.decode(receiptMetricsJSON) }
    set {
        assert((newValue?.earningsSchemaVersion ?? 2) >= 2,
               "ShiftRecord stores v2 earnings only. Use applyEarnings.")
        receiptMetricsJSON = Self.encode(newValue)
    }
}
var receiptPayloadIsUnreadable: Bool {
    receiptMetricsJSON != nil && Self.decode(receiptMetricsJSON) == nil
}
```

`receiptPayloadIsUnreadable` is load-bearing: `shifts.gratuity_fees_cents` is generated, so a nil-metrics getter feeding `applyEarnings` would zero gratuity locally and push that zero over the server's generated value. Such a record is **excluded from the sync push set** and shown in Data health as "1 shift's receipt couldn't be read", never silently rewritten.

The only earnings writer is atomic over all four values: `applyEarnings(cashCents:creditCents:metrics:metricsOwner:)`. A normalization in a property setter that mutates two other stored properties is order-dependent and nothing binds a call site's assignment order; that is what once inflated $80 to $122.

Three `scripts/design-lint.sh` bans, each failing the build: `earningsSchemaVersion =` outside `ShiftReceiptMetrics.swift`; `voluntaryTipsCents(` outside `ShiftReceiptMetrics.swift`; `.receiptMetrics =` on a `ShiftRecord` outside `ShiftRecord.swift`.

### 2.2 Container and build wiring

`SharedModelContainer.swift:17-21` and `:33-37` open `ModelContainer(for: TipEntry.self, PaycheckRecord.self, ...)` twice with no shared schema constant, and on failure fall back to an **in-memory** container and set `openingFailed`. So:

- Add `static let schema = Schema([TipEntry.self, PaycheckRecord.self, ShiftRecord.self])` and use it for both, so the lists cannot drift. `shared.mainContext.autosaveEnabled = false` also belongs in this file but **lands in S9, not S1**, because every shipped SwiftUI write path depends on autosave until S9 replaces them (8.2).
- Add `Payday/Models/ShiftRecord.swift`, `Payday/Utilities/ShiftProjection.swift`, `Payday/Utilities/LegacyShiftRow.swift` to `project.yml`'s **explicit per-file** `PaydayWidget.sources` list (`project.yml:101-136`), plus anything the widget transitively needs. Miss it and `ModelContainer(for:)` throws in the widget process, `openingFailed` is set, and the Lock Screen renders "Couldn't load".
- Adding an entity is a SwiftData lightweight migration: no `VersionedSchema`, no `SchemaMigrationPlan`.
- Guard every durable flag write with `guard !SharedModelContainer.openingFailed`.
- `PaydayAccountEraser.eraseLocalData` gains `try context.delete(model: ShiftRecord.self)` and a third `fetchCount` assertion (`PaydayAccountEraser.swift:43-58`). `PaydaySyncState.forget` (`:120-127`) already deletes whole keys; keep it that way.

### 2.3 The DDL

```sql
create table public.shifts (
  id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  work_date date not null,
  shift_period text check (shift_period is null or shift_period in ('lunch','dinner')),

  cash_tips_cents integer not null default 0 check (cash_tips_cents >= 0),
  credit_tips_cents integer not null default 0 check (credit_tips_cents >= 0),
  tip_out_cents integer check (tip_out_cents is null or tip_out_cents >= 0),
  sales_cents integer check (sales_cents is null or sales_cents >= 0),
  hours_worked numeric check (hours_worked is null or hours_worked >= 0),
  clock_in timestamptz,
  clock_out timestamptz,
  server_count integer check (server_count is null or server_count >= 0),
  receipt_metrics jsonb,
  note text,
  recorded_at timestamptz,

  source text not null default 'device' check (source in ('device','api','migration')),
  legacy_entry_ids uuid[] not null default '{}',
  legacy_source_max_updated_at timestamptz,
  converted_at timestamptz,
  native_modified_at timestamptz,
  unconverted_legacy_cents integer not null default 0 check (unconverted_legacy_cents >= 0),
  deleted_reason text check (deleted_reason is null or deleted_reason in ('user','api','converted')),

  agent_idempotency_key text
    check (agent_idempotency_key is null or char_length(agent_idempotency_key) between 8 and 200),
  client_updated_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version >= 1),
  derived_version bigint not null default 0 check (derived_version >= 0),

  gratuity_fees_cents integer generated always as
    (private.receipt_gratuity_cents(receipt_metrics)) stored,

  non_wage_earnings_cents integer generated always as (
    greatest(-2147483648::numeric, least(2147483647::numeric,
        cash_tips_cents::numeric + credit_tips_cents::numeric
      + private.receipt_gratuity_cents(receipt_metrics)::numeric
      - coalesce(tip_out_cents, 0)::numeric))::integer) stored,

  constraint shifts_receipt_is_object check (
    receipt_metrics is null or jsonb_typeof(receipt_metrics) = 'object'),
  constraint shifts_receipt_is_v2 check (
    receipt_metrics is null
    or case jsonb_typeof(receipt_metrics -> 'earningsSchemaVersion')
         when 'number' then (receipt_metrics ->> 'earningsSchemaVersion')::numeric >= 2
         else false end),

  primary key (user_id, id)
);
```

```sql
-- The gratuity rule, ONE implementation in SQL. Read by both generated
-- columns, by the deriver's arithmetic and by the fold's sanitizer.
create or replace function private.receipt_gratuity_cents(p jsonb)
returns integer language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p -> 'gratuityFeesCents') = 'number'
              then least(2147483647::numeric,
                     greatest(0::numeric, (p ->> 'gratuityFeesCents')::numeric))::integer
              else 0 end;
$$;
```

**Stored versus generated.** `cash_tips_cents`, `credit_tips_cents`, `tip_out_cents`, `sales_cents`, `hours_worked` are stored: they are facts a person entered. `gratuity_fees_cents` and `non_wage_earnings_cents` are `generated always as ... stored`: they are the gratuity rule and the net rule, and a generated column gives each rule exactly one implementation per language rather than a drift that is merely detectable. `non_wage_earnings_cents` deliberately has **no** non-negativity check: a tip-out larger than the night's tips is real and already representable.

Three facts make this exact spelling load-bearing, all *measured on PG 17.11*:

1. **An `immutable` user function is legal inside a stored generated column**, so the gratuity `CASE` is written **once**, not twice. (This document's first draft claimed Postgres forbade it and duplicated the `CASE`; the ban is on referencing another *generated column*, not on calling a function. The duplicate then reappeared twice more inside the deriver and once in the conservation check, giving four hand-written copies of a money rule.)
2. **Both expressions must clamp in `numeric` space, not `integer` space.** `greatest(0, ('{"gratuityFeesCents":99999999999}'::jsonb ->> 'gratuityFeesCents')::numeric::integer)` aborts with `22003 integer out of range` before any clamp can run, and so does `1e30`. `public.tip_entries.receipt_metrics` has no CHECK at all (`20260831164348:34`) and `ReceiptAIParser` is an LLM scanner, so a hallucinated magnitude is storable today and would abort arm 1 **inside a shipped 1.0 build's transaction**. With the spelling above, `99999999999`, `1e30`, `-500`, `1234.6`, `true` and `"hi"` all insert: `2147483647 / 2147483647 / 0 / 1235 / 0 / 0`.
3. **Clamping `gratuity_fees_cents` alone is not enough.** `non_wage_earnings_cents` sums three `int4` values, so `cash 5000 + credit 2000 + gratuity 2147483647` overflows even when every input is in range. *Measured:* with the gratuity clamped but the sum left in `integer`, `{"gratuityFeesCents":99999999999}` still aborts with `22003`; and so does an ordinary `cash 2147483000 + gratuity 2000000`. Hence the whole sum is computed in `numeric` and clamped to the `int4` range at both ends.

```
comment on function private.receipt_gratuity_cents(jsonb) is
  'The gratuity rule. Read by two STORED generated columns, so CREATE OR '
  'REPLACE here silently changes the rule WITHOUT recomputing any stored '
  'row (measured: the replace succeeds and existing values are untouched). '
  'It may not be edited. Changing it requires a migration that also '
  'rewrites every public.shifts row.';
```

`scripts/design-lint.sh` bans a fourth spelling: `gratuityFeesCents'` appearing in any `.sql` file outside `private.receipt_gratuity_cents`' own body and the fold's sanitizer.

### 2.4 Comments that must ship in the migration file

```
-- Keyed (user_id, id), never a bare id. payday_legacy_shift_id takes no
-- account input, so every account that worked 2026-03-05 mints the SAME
-- uuid, and the fold now mints those ids from every old build on every
-- account, forever. MEASURED on PG 17: with a bare `id uuid primary key`
-- and this conflict shape, user B's upsert of an id user A holds returns
-- ZERO rows with NO error and A's row stays; under the composite key the
-- same sequence returns 1 row and both exist. Every reader that would have
-- caught that silent drop (claims, sweep, divergence) is deleted here.
--
-- 1. NEVER add a unique index or constraint on shifts(id) alone. PostgREST
--    does not need one and it converts a silent no-op into a permanent
--    cross-tenant constraint violation.
-- 2. Every future table referencing a shift uses
--    foreign key (user_id, shift_id) references public.shifts (user_id, id).
-- 3. A support query that looks up a shift by bare id is wrong by design.
--
-- "No double counting" is now a property of ONE `group by` in ONE function
-- (private.derive_shifts) plus this composite key plus the pinned identity
-- vectors. The claims primary key that used to make it a schema property is
-- gone, and the conservation check never raises (4.6 rule 6). Any PR
-- weakening the pinned-vector test or the N4 parity gate is a money-loss PR.
--
-- That "ONE group by" is a real constraint on how derive_shifts is written,
-- not a description. The `grouped` chain is evaluated ONCE per invocation
-- into a plpgsql local and all four write arms plus the conservation check
-- read that local (4.4). Repeating the chain per arm would give four copies
-- of a money rule AND four snapshots, because at READ COMMITTED each
-- statement takes a fresh one and a writer that lost the try-lock still
-- COMMITS its legacy row before returning (4.7).
```

### 2.5 The two receipt CHECKs

*Measured:* `(receipt_metrics ->> 'earningsSchemaVersion')::numeric` on a boolean or string raises `invalid input syntax for type numeric`, a statement **abort** no constraint-name handler can catch, and Postgres does not guarantee `OR` short-circuits, so `CASE` is what makes the cast unreachable. A payload with the key **absent** is live production data (`ReceiptAIParser.swift:161` writes `earningsSchemaVersion: creditTipsCents != nil ? 2 : nil`; older scans never wrote it), and `{"earningsSchemaVersion": "1"}` must be **rejected**, because `ShiftReceiptMetrics.earningsSchemaVersion` decodes as `Int?` so the whole payload would fail to decode on device and any reader treating undecodable as v1 subtracts the gratuity twice.

**New obligation under this shape:** the CHECK now fires inside a shipped 1.0 build's transaction, so the fold must sanitize such that it can never trip. On an object payload it writes

```sql
jsonb_set(
  jsonb_set(payload, '{earningsSchemaVersion}', '2'::jsonb, true),
  '{gratuityFeesCents}',
  to_jsonb(private.receipt_gratuity_cents(payload)),
  false)          -- create_missing = false: never invent the key
```

and `null` on anything else (3.4). The CHECK is the belt; the sanitization is the braces.

**`gratuityFeesCents` is sanitized for the same reason `earningsSchemaVersion` is, and that was missed once.** The fold's own arithmetic goes through `private.receipt_gratuity_cents`, so it is already clamped and integral, but the payload it *stores* was copied through verbatim. *Measured:* a credit row of 5000 carrying `{"gratuityFeesCents":1234.6}` folds to credit 3765 / gratuity 1235 / non-wage 5000 — self-consistent, no money moves — and writes `{"gratuityFeesCents": 1234.6, "earningsSchemaVersion": 2}` into `shifts.receipt_metrics`. `ShiftReceiptMetrics.swift:53` decodes `gratuityFeesCents` as `Int?`, so the **whole payload** fails to decode on device, 2.1's `receiptPayloadIsUnreadable` fires, and per 2.1 that shift is excluded from the push set and reported forever, because the server keeps re-folding the same fractional value. Rewriting the key through the same helper the arithmetic used makes the stored payload and the generated column agree by construction. Fixture: the stored payload of every fold fixture must decode as `ShiftReceiptMetrics` on the Swift side.

`shifts_receipt_is_object` was in the base design, dropped by the cutover, and comes back because `tip_entries.receipt_metrics` has **no** object CHECK (`20260831164348:34`), so a non-object payload is storable and `jsonb_set` on one raises. *Measured:* `jsonb_set('[1,2]'::jsonb,'{earningsSchemaVersion}','2',true)` gives `path element at position 1 is not an integer`; on a scalar it gives `cannot set path in scalar`; the guarded `case when jsonb_typeof(p)='object' then jsonb_set(...) else null end` returns null. `->` and `->>` on a non-object return NULL with no error, so `jsonb_set` is the only hazard.

### 2.6 Identity

```sql
create or replace function public.payday_legacy_shift_id(p_work_date date)
returns uuid language sql immutable set search_path = '' as $$
  select ('5aac5d01' ||
          substr(md5('payday:legacy-shift:' || to_char(p_work_date, 'YYYY-MM-DD')), 9, 24)
         )::uuid;
$$;

comment on function public.payday_legacy_shift_id(date) is
  'This value is a persisted primary key. Changing the namespace, the digest '
  'or the date format re-keys every subsequent fold, splits one night into '
  'two shifts and duplicates history. It may not be edited.';
```

Pinned vectors, both re-measured: `2026-03-05` gives md5 `137014afcdd8a5b71018bd7636d09d87` and uuid `5aac5d01-cdd8-a5b7-1018-bd7636d09d87`; `2026-07-01` gives `237b5c54e5506ca92f6ed35d43bfc83f` and `5aac5d01-e550-6ca9-2f6e-d35d43bfc83f`.

Asserted in job E (both vectors, `theDerivedIDIsIdenticalAcrossUsersAndThatIsFine`) and in `supabase/functions/payday-api/agent_shifts_test.ts` against local Postgres. `PaydayTests/LegacyShiftIdentityTests.swift` keeps only `aOneZeroDeviceBackfillingTheSameDayDoesNotRekeyTheGroup` and `generation0IsStillWhatTheDeviceMints`; with no Swift port there is nothing else on the device to pin. The **reason** for pinning has changed: it is no longer a runtime double-count tripwire, it is a guarantee the function is never edited again. The earlier `A-4` form produced a 36-character string and did not cast, which is why this form is spelled out.

**There is no Swift port, and adding one would be a money bug.** Earlier drafts kept `ShiftDays.legacyShiftID(forWorkDate:)` (the `5A AC 5D 01` prefix plus md5 bytes 4..15) so `MigrationRunner.backfillShiftIDs` could mint the same id the server mints. 6.4 no longer does that: it keeps minting `ShiftDays.deterministicShiftID` (`ShiftDays.swift:105-124`, the `5aac5d00` generation-0 day-index form), because **every shipped 1.0 build still mints generation 0** and `upsert_tip_entries` rewrites `shift_id` unconditionally (`20260904134500:138-139`). Two devices on one account, one on 1.0 and one on the new build, each holding nil-`shift_id` rows for the same day, would flip that day's group key between the two generations on every pass — a repeating group-key change, which is the trigger for the worst failure in 4.3. So `deterministicShiftID` is **not** deprecated, it stays the only Swift minter, and `ShiftDays.legacyShiftID` is not written.

`payday_legacy_shift_id` therefore has exactly one caller, `private.legacy_group_key`, and its vectors are asserted in SQL (job E) and in `supabase/functions/payday-api/agent_shifts_test.ts` only. `ShiftDays.isGeneration0LegacyID` is for support output only and is banned from every key computation. A day can still end up with one generation-0 group (rows some device backfilled) and one generation-1 group (rows that reached the server with a nil `shift_id` and were never backfilled, e.g. an agent `create_tip_entry`); that is same-day duplication, reported by 5.5, not prevented, and it is reachable identically under either choice of generation.

### 2.7 RLS, grants, indexes, version trigger

```sql
alter table public.shifts enable row level security;
create policy shifts_select_own on public.shifts for select to authenticated
  using ((select auth.uid()) = user_id);
-- SELECT ONLY. No insert, update or delete policy and no such grant: every
-- client write goes through the definer RPCs of 7.1, so a direct grant is
-- unnecessary AND it would defeat three invariants the rest of this design
-- rests on -- 4.5's "native_modified_at is written by private.write_shifts
-- and by nothing else", 12.2's "source plus legacy_entry_ids is the only
-- safe rollback query", and private.shift_is_open_to_fold's meaning. With
-- insert/update granted, a session could set source, legacy_entry_ids,
-- deleted_reason or native_modified_at on its own rows and make rollback
-- tombstone a shift the user authored, spare a conversion artifact, or
-- reopen a closed shift to the fold.
revoke all on table public.shifts from anon, authenticated;
grant select on table public.shifts to authenticated;

create index shifts_user_work_date_idx
  on public.shifts (user_id, work_date desc, recorded_at desc nulls last, id desc)
  where deleted_at is null;
create index shifts_user_updated_idx on public.shifts (user_id, updated_at, id);
create index shifts_legacy_entry_ids_idx on public.shifts using gin (legacy_entry_ids);

-- The fold must read TOMBSTONED legacy rows (watermark, all-tombstoned arm).
-- tip_entries has THREE shipped indexes (20260831164348:49-57). Both that
-- could serve a (user_id, shift_id, work_date) group lookup are partial on
-- `deleted_at is null`; the third, tip_entries_user_updated_idx, is on
-- (user_id, updated_at, id) and is not partial but cannot serve a group
-- lookup. So without this index the fold seq-scans INSIDE a 1.0 build's
-- write transaction.
create index tip_entries_user_group_all_idx on public.tip_entries (user_id, shift_id, work_date);
```

`agent_idempotency_key` stays server-only by convention: the sync client's column list never names it, exactly as for `tip_entries`.

**Account deletion.** `public.delete_my_account()` rests entirely on the stated invariant that every user-owned table references `auth.users(id) on delete cascade`, enumerated at `20260911150000_add_account_deletion.sql:9-18` — the migration written for the Guideline 5.1.1(v) rejection. PR 2 adds **five** user-keyed tables and all five go in that comment: `public.shifts`, `public.shift_legacy_conflicts`, `public.shift_migration_state`, `private.shift_fold_backlog` and `private.shift_fold_failures`. The two `private` tables must carry `user_id uuid not null references auth.users(id) on delete cascade` like the rest; a foreign key does not require the table to be reachable by `authenticated`. Without it they survive account deletion, and `shift_fold_failures.message` holds `SQLERRM` text that for `22P02` and `22003` embeds the offending value out of the user's receipt payload. 4.8's `auth.users` existence guard stops the cascade from *failing*; only the FKs stop the rows from being *orphaned*. Extend the existing `delete_my_account` test to assert zero remaining rows in all five.

`public.shifts` must **not** reuse `private.touch_versioned_row()` (`20260831164348:5-16`), which increments `version` on every UPDATE. The agent API mutates with `.eq("version", expected_version)` (`index.ts:1191-1194`, `:1226-1231`), so a fold fired by an unrelated 1.0 write would return a 409 for something the agent did nothing wrong on:

```sql
create or replace function private.touch_shift_row()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  new.updated_at = now();
  if coalesce(current_setting('payday.folding', true), '') = 'on' then
    -- A derivation is not a user edit. updated_at still advances so every
    -- device re-pulls, but `version` keeps meaning "intentional change".
    new.version = old.version;
    new.derived_version = old.derived_version + 1;
  else
    new.version = old.version + 1;
  end if;
  return new;
end;
$$;
create trigger shifts_touch_version before update on public.shifts
for each row execute function private.touch_shift_row();
```

`payday.folding` is set transaction-local by `private.derive_shifts` and by nothing else, **and cleared by `private.derive_shifts` immediately before every `return`, including inside its exception handler** (`perform set_config('payday.folding', 'off', true)`). Transaction-local means it otherwise outlives the fold: once a fold has run, every later UPDATE to `public.shifts` in that same transaction takes the derived branch, freezing `version` and bumping `derived_version` instead. Nothing in PR 2 reaches it, verified — `private.write_shifts`, `soft_delete_shifts` and `restore_shifts` are each their own PostgREST request and therefore their own transaction, and the fold never writes `tip_entries` so it cannot recurse. But this trigger exists precisely to protect the agent's optimistic concurrency at `index.ts:1191-1194` and `:1226-1231`, and PR 6 adds agent **write** verbs for shifts. The first function that folds a legacy row and then updates a shift in one transaction would silently stop bumping `version`, and `.eq("version", expected_version)` would become a no-op guard instead of a 409. A GUC set and never reset is invisible at the call site that breaks, so the invariant test `aNativeShiftWriteAfterAFoldInTheSameTransactionStillBumpsVersion` ships now, while it is cheap.

---

## 3. The conversion function: the single deriver

### 3.1 Shape

```sql
create or replace function private.legacy_group_key(p_shift_id uuid, p_work_date date)
returns uuid language sql immutable set search_path = '' as $$
  select coalesce(p_shift_id, public.payday_legacy_shift_id(p_work_date));
$$;

create or replace function private.derive_shifts(
  p_user_id uuid, p_group_keys uuid[]
) returns table (touched_count integer, wrote_count integer,
                 source_cents bigint, shift_cents bigint, conflicts integer)
language plpgsql security definer set search_path = '' as $$ ... $$;
```

One function, **one behaviour**. Both the trigger and `public.migrate_tip_entries_to_shifts` call it identically, so they cannot disagree about grouping, receipt arithmetic, tip-out, hours, or what happens when conservation fails.

**`p_strict` is deleted.** An earlier draft of this document gave the RPC path `p_strict := true`, so a conservation failure raised there and was merely recorded on the fold path. That was unsatisfiable against two other rules in this same document: 4.5 requires provenance be written unconditionally onto a **closed** shift, while a closed shift's money is by definition no longer equal to its legacy sources, and 5.2's predicate keeps re-deriving exactly those groups. *Measured, with no concurrency and no clock skew:* an old build logs $50 cash (folds to 5000), the user corrects the night on the new build (`native_modified_at` set, shift CLOSED), the old phone then deletes the tip through the shipped `soft_delete_tip_entries` — and `migrate_tip_entries_to_shifts` raises `payday_migration_conservation_failed orphans=0 dupes=0 in=0 out=6000 touched=1` on run 1, run 2 and run 3 identically, rolling back the backlog delete and `last_run_at` with it so there is no record it ran. The document had even printed the failing pair itself (§5.3's "after one legal edit (cash 5000 to 6000) `in=8200 out=9200`") and read it only as evidence the **account-wide** check was too broad, without noticing the invocation-scoped check inherits it whenever an edited group is re-derived. 4.6 rule 6's own reasoning — committing a wrong number that Data health flags beats a dark app — applies with **more** force to the new build than the old one, since `shifts` is the surface that is authoritative for reads. So: conservation records, never raises, on both paths (5.3).

The group key exists in exactly one place and is called from the trigger, the `unmigrated` predicate and the deriver, so drift is unrepresentable rather than tested. **The key is a pure function of ONE row** and never adopts a sibling's stored id, which is what makes the fold's result independent of which rows are visible in a given transaction; set-dependence is exactly how two overlapping folds diverge (4.7). It matches `index.ts:1342-1348`, which keys a nil-`shift_id` row on its own `row.id`, so nothing in the shipped API changes meaning for rows that carry a `shift_id`, and most real rows do (`ShiftWriter.swift:38` mints one per new log; `backfillShiftIDs` only ever ran for nil rows).

### 3.2 Grouping and resolution

```sql
with source as (
  select e.*, private.legacy_group_key(e.shift_id, e.work_date) as group_key
  from public.tip_entries e
  where e.user_id = p_user_id
    and private.legacy_group_key(e.shift_id, e.work_date) = any(p_group_keys)
    and e.deleted_at is null
),
ranked as (
  select s.*,
    row_number() over (partition by s.group_key order by
      (jsonb_typeof(s.receipt_metrics) = 'object') desc, (s.kind = 'credit') desc, s.id asc) as metrics_rank,
    row_number() over (partition by s.group_key order by
      (s.kind = 'credit') desc, s.id asc) as detail_rank
  from source s
),
owned as (
  select r.*,
    case when r.metrics_rank = 1
         then private.receipt_gratuity_cents(r.receipt_metrics)
         else 0 end as owner_gratuity_cents,
    case when r.metrics_rank = 1
              and jsonb_typeof(r.receipt_metrics -> 'earningsSchemaVersion') = 'number'
         then (r.receipt_metrics ->> 'earningsSchemaVersion')::numeric
         else 1 end as schema_version
  from ranked r
),
grouped as (
  select
    o.group_key as id,
    min(o.work_date) as work_date,
    (array_agg(o.shift_period order by o.detail_rank) filter (where o.shift_period is not null))[1] as shift_period,
    least(greatest(0, sum(case when o.kind = 'cash'
      then case when o.schema_version >= 2 then o.amount_cents
                else greatest(0, o.amount_cents - o.owner_gratuity_cents) end
      else 0 end)::bigint), 2147483647)::integer as cash_tips_cents,
    least(greatest(0, sum(case when o.kind = 'credit'
      then case when o.schema_version >= 2 then o.amount_cents
                else greatest(0, o.amount_cents - o.owner_gratuity_cents) end
      else 0 end)::bigint), 2147483647)::integer as credit_tips_cents,
    (array_agg(o.tip_out_cents order by o.detail_rank) filter (where o.tip_out_cents is not null))[1] as tip_out_cents,
    (array_agg(o.sales_cents  order by o.detail_rank) filter (where o.sales_cents  is not null))[1] as sales_cents,
    (array_agg(o.hours_worked order by o.detail_rank) filter (where o.hours_worked is not null))[1] as hours_worked,
    (array_agg(o.clock_in     order by o.detail_rank) filter (where o.clock_in     is not null))[1] as clock_in,
    (array_agg(o.clock_out    order by o.detail_rank) filter (where o.clock_out    is not null))[1] as clock_out,
    (array_agg(o.server_count order by o.detail_rank) filter (where o.server_count is not null))[1] as server_count,
    (array_agg(o.note         order by o.detail_rank) filter (where o.note         is not null))[1] as note,
    (array_agg(o.recorded_at  order by o.detail_rank) filter (where o.recorded_at  is not null))[1] as recorded_at,
    (array_agg(case when jsonb_typeof(o.receipt_metrics) = 'object'
                    then jsonb_set(o.receipt_metrics, '{earningsSchemaVersion}', '2'::jsonb, true)
                    else null end
       order by o.metrics_rank) filter (where jsonb_typeof(o.receipt_metrics) = 'object'))[1] as receipt_metrics,
    array_agg(distinct o.id order by o.id) as legacy_entry_ids,
    max(o.client_updated_at) as source_max_updated_at
  from owned o
  group by o.group_key
)
```

- **`metrics_rank`** is **object-first**, then credit, then id: `TipBreakdown.swift:47-68`'s rule made deterministic on ties. Ranking on object-ness rather than `is not null` is what keeps the gratuity **owner** and the group's **stored payload** the same row by construction, because the stored payload is `(array_agg(... order by metrics_rank) filter (where jsonb_typeof = 'object'))[1]`. *Measured through the shipped `upsert_tip_entries`* with a credit row of 2000 carrying `"hi"` and a cash row of 5000 carrying `{"gratuityFeesCents":4200}` (v1, key absent):

  | ranking | cash | credit | gratuity | non-wage |
  |---|---|---|---|---|
  | `receipt_metrics is not null` (wrong) | 5000 | 2000 | 4200 | **11200** |
  | `jsonb_typeof(...) = 'object'` (this rule) | 800 | 2000 | 4200 | 7000 |

  A non-object payload is not null, so it won rank 1, no subtraction happened on any row, and the gratuity was then **added** by the generated column without ever being **subtracted**: $42.00 of money that does not exist, on one shift. It was also a parity break, not just arithmetic — Swift gives 7000 for the same input, because an undecodable payload is nil on device so `TipBreakdown.swift:51` picks the cash row as owner and subtracts its 4200. The `filter (where jsonb_typeof(...) = 'object')` on the aggregate **stays**: it is what keeps a group in which *no* row holds an object payload from storing a scalar into `shifts.receipt_metrics` and violating `shifts_receipt_is_object`. No live writer produces a non-object payload today (`index.ts:234-239`'s `receiptMetrics()` runs `optionalObject`, and the device encodes a struct), but `tip_entries.receipt_metrics` has no object CHECK, `upsert_tip_entries` passes the jsonb through unvalidated (`20260904134500:114`), CloudKit-era imports predate the validator, and 2.5 and 3.4 both design for non-object payloads explicitly. Fixture **N5** pins it: junk payload on the credit row, v1 object on the cash row, expected cash 800 / credit 2000 / gratuity 4200 / non-wage 7000, in the section 11 parity set and in the pinned-vector suite.
- **`detail_rank`** is credit-first then id, and every scalar is the first **non-null** in that order across **all** of a group's rows, **never a sum**.

  **Correction (S3, measured): this bullet used to say "matching `ShiftDetails.resolve`, which is credit `??` cash", and that was wrong.** `credit ?? cash` is `first { kind == .credit } ?? first { kind == .cash }` **per field**, which has no rank and cannot see a group's *second* row of either kind. The two rules agree to the cent on a group of exactly one cash row plus one credit row — which is every fixture this design had (N1, N3, N4, N5, L1, L2, P6), so all of them passed under **both** rules and none could see the difference. A group with two rows of one kind needs no data corruption to exist: the agent API's `create_tip_entry` mints ids as `deterministicUUID("shift:<shift_id>:credit")` (`index.ts:1101-1141`), which never equal a device row's random UUID and are under no uniqueness constraint on `(shift_id, kind)`, so an agent adding credit tips to an existing device shift lands a second credit row in that group; and `MigrationRunner.backfillShiftIDs` assigns a day's existing `shiftID` to every nil-`shift_id` row of that day (pinned by its own test `coalescesOntoExistingID`), collapsing a legacy pair and a new pair into one four-row group.

  Measured on the real shipped `TipBreakdown` over new fixture **P7** — one `shift_id`, 2026-07-01, four live rows: cash 5000 (`a1`), credit 2000 with `tip_out 1000` (`b1`), cash 1000 (`c1`), credit 3000 carrying the v1 receipt `{"gratuityFeesCents":4200}` (`d1`):

  | reader | cash | credit | gratuity | tip-out | non-wage |
  |---|---|---|---|---|---|
  | Swift, 12 of the 24 array orders | 6000 | 5000 | 0 | 1000 | **10000** |
  | Swift, the other 12 array orders | 6000 | 2000 | 4200 | 0 | **12200** |
  | `index.ts` `groupShifts` (sorts by id) | 6000 | 5000 | 0 | 1000 | **10000** |
  | `private.derive_shifts` (this rule) | 6000 | 2000 | 4200 | 1000 | **11200** |

  Swift returned **two different answers for identical data** depending on array order, and the fold agreed with neither. **Conservation cannot see this class of disagreement at all**, which is the point worth keeping: both sides of the check are the fold's own grouping, so P7 returns `source_cents = shift_cents = 11200` with `conflicts = 0` while both shipped readers are wrong. Only a pinned fixture catches it.

  **Resolution: the ranking was ported INTO Swift, not the reverse,** because the fold's answer is the correct one. `ShiftDetails` now carries `detailRanked` / `metricsRanked` / `metricsOwner(of:)`, resolves every scalar as the first non-null in detail-rank order across all rows, reads the receipt off metrics rank 1, and `write` targets detail rank 1 instead of `first(where:)` — which also removes `TipBreakdown`'s array-order dependence, a live defect on its own. Fixture P7 is pinned twice, as literals on both sides: `supabase/tests/shift_deriver_test.sql` (`P7_*`) and `PaydayTests/ShiftGroupRankingParityTests.swift` (all 24 orders). Neither side can move alone. One asymmetry stays and is deliberate: SQL ranks on `jsonb_typeof(...) = 'object'` while Swift can only see a payload that **decodes** as `ShiftReceiptMetrics`, so an object-but-undecodable payload outranks on the server and is nil on the device; the sanitizer confines that to un-folded legacy rows and `ShiftRecord.receiptPayloadIsUnreadable` is the surface that reports it. The agent API's `groupShifts` is deliberately **not** patched: its own slice replaces it with a read of `public.shifts`, and porting a ranking into code scheduled for deletion would be a fourth copy of a money rule.
- **Every scalar is resolved by rank, never summed.** A tip-out duplicated onto both rows must subtract once (fixture N1).
- **`min(work_date)`, never `max`.** `ShiftDays.swift:56` and `StatsEngine.swift:226` use `min`; `groupShifts` (`index.ts:1352-1358`) reduces to the largest, and that is correction D1. Fixture L1 (two rows sharing a `shift_id`, work dates 2026-07-04 and 2026-07-05) is the only fixture that makes it observable.
- **Null is not zero** for `hours_worked`, `tip_out_cents`, `sales_cents`: "never entered" and "tipped out nothing" are different facts, and they are genuine `Int?` on `TipEntry`. Summary sums coalesce **at the sum**, so totals do not move (D4).
- **`work_date` is filtered before grouping**, as `payday_agent_summary` already does (`20260904125000:30-31`). A filter-after-grouping bug in the shared deriver would corrupt writes, not just a read.
- **Sums widen to `bigint`, then clamp into `int4`.** `amount_cents` is `int4`, a junk account can overflow the group sum, and an overflow is a statement abort, which here is a rejected 1.0 write.
- **`array_agg(distinct o.id order by o.id)`** is the provenance and the idempotency evidence.

### 3.3 The v1-to-v2 receipt conversion, and which Swift path it ports

**It ports the READ path (`TipBreakdown.total`), not the edit path (`LogTipSheet.gratuityFeesBinding`).** The single most expensive correction in three rounds.

`TipBreakdown.total` resolves the metrics owner and applies `voluntaryTipsCents(fromStoredAmount:)` to **that row only**. The owner resolution it shipped with — `credit?.receiptMetrics != nil ? credit : (cash?.receiptMetrics != nil ? cash : nil)` — is now `ShiftDetails.metricsOwner(of:)`, the metrics rank, for the reason in 3.2's `detail_rank` bullet; the "that row only" half is unchanged and is what this section is about. `ShiftReceiptMetrics.swift:120-123` is `max(0, amountCents - employeeGratuityFeesCents)`. `TipEntry.netCents` (`TipEntry.swift:162-165`) and `index.ts:1325-1340` sum the same way.

`gratuityFeesBinding` (`LogTipSheet.swift:1040-1057`) moves the **whole** folded gratuity to the other kind (`if creditCents >= foldedGratuity { creditCents -= ... } else { cashCents = max(0, cashCents - ...) }`), which is a deliberate reassignment on an edit, a different operation.

Measured on N4 (cash 5000, credit 2000, v1 receipt on the credit row with `gratuityFeesCents = 4200`, `tip_out_cents = 1000`):

| | cash | credit | gratuity | non-wage |
|---|---|---|---|---|
| read path / this SQL | 5000 | 0 | 4200 | 8200 |
| the old binding-derived rule | 800 | 2000 | 4200 | 6000 |

$22.00 on one shift **and** a different cash/credit split, and the split is what drives the paycheck comparison.

Swift, still needed because the v1 producer is live (`ReceiptAIParser.swift:161`):

```swift
// ShiftReceiptMetrics.swift is the only file allowed to touch the version.
static func normalizedToV2(cashCents: Int, creditCents: Int,
                           metrics: ShiftReceiptMetrics,
                           owner: TipKind) -> (cash: Int, credit: Int, metrics: ShiftReceiptMetrics) {
    guard (metrics.earningsSchemaVersion ?? 1) < 2 else { return (cashCents, creditCents, metrics) }
    let folded = metrics.employeeGratuityFeesCents
    var cash = cashCents, credit = creditCents
    switch owner {
    case .cash:   cash = max(0, cash - folded)
    case .credit: credit = max(0, credit - folded)
    }
    var out = metrics
    out.earningsSchemaVersion = 2
    return (cash, credit, out)
}
```

Idempotent via the guard. Its agreement with the SQL is what the parity gate asserts (section 11).

### 3.4 Behavior on an empty or junk payload

| input | result |
|---|---|
| `receipt_metrics is null` | no gratuity, no subtraction, `shifts.receipt_metrics` null |
| non-object payload (`[1,2]`, `"hi"`, `4`) | excluded by `jsonb_typeof(...) = 'object'`, so the group's `receipt_metrics` is null. Never `jsonb_set` on it. |
| object, `earningsSchemaVersion` absent | treated as **v1**: subtract the owner's gratuity, then relabel to 2. This is live production data. |
| object, `earningsSchemaVersion` non-numeric (`true`, `"v2"`) | `schema_version` resolves to 1 via the `jsonb_typeof` guard, so subtract then relabel. The guard is mandatory: an unguarded cast inside a CHECK is an uncatchable abort. |
| `gratuityFeesCents` non-numeric (`true`, `"42"`) | `private.receipt_gratuity_cents` gives 0, nothing is subtracted, the stored payload's key is left alone. |
| `gratuityFeesCents` fractional (`1234.6`) | **rounds half away from zero**, so `1234.6` stores as `1235` and `1234.4` as `1234` (*measured*; an earlier draft said "truncates, so `1234.6` stores as `1234`", which is simply wrong). The sanitizer rewrites the key to the rounded integer so the stored payload decodes as `ShiftReceiptMetrics` on device (2.5). |
| `gratuityFeesCents` out of `int4` range (`99999999999`, `1e30`) or negative | clamped to `[0, 2147483647]` **in `numeric` space**, in one place, by `private.receipt_gratuity_cents`, and the whole `non_wage_earnings_cents` sum is clamped the same way. *Measured:* without that, arm 1's INSERT aborts with `22003 integer out of range` inside a 1.0 build's transaction, which violates 4.6 rule 4. The sanitizer writes the clamped value back, so the payload and the generated column cannot disagree. |
| group with zero live rows | emits no `grouped` row. Handled by its own statement (4.4 arm 2b), while arm 2a still clears its provenance. |

### 3.5 The invariant that makes repeat calls safe

> `derive_shifts(u, K)` is a pure function of the current contents of `public.tip_entries` for user `u` restricted to `K`, and it writes each result to the primary key `(u, group_key)` where `group_key` is a pure function of a single source row.

So calling it again with the same `K` and unchanged sources produces byte-identical output on the same rows. Re-converting needs no marker table, no claim and no "already migrated" flag: idempotency is a property of the key (R2).

The companion rule (R1) is what makes the "in" side stable: **the new build never rewrites a legacy row's money.** `tip_entries` is additive-only from the new build, with exactly one narrow exception (`ShiftCommands.delete`, 8.4, through the shipped `soft_delete_tip_entries`).

---

## 4. The on-arrival trigger

### 4.1 Why a trigger, not an RPC wrapper

The agent API writes `tip_entries` by **direct table access with the service-role client**, so no RPC predicate is ever on the call path: `ctx.admin.from("tip_entries").insert(payload)` in `createRow` (`index.ts:1045`), `ctx.admin.from(table).update(payload)` in `updateRow` (`:1191`), `changeDeletion`'s update (`:1226`), the batch insert in `createShift` (`:1144`), and the admin client built from `SUPABASE_SERVICE_ROLE_KEY` (`:545-556`). RLS is bypassed on all of them. A table trigger is the only construct that makes conversion a property of the **table** rather than of six call sites plus two RPCs.

### 4.2 Statement-level, three triggers, one function

```sql
create trigger tip_entries_fold_insert after insert on public.tip_entries
  referencing new table as new_rows
  for each statement execute function private.fold_legacy_writes();

create trigger tip_entries_fold_update after update on public.tip_entries
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.fold_legacy_writes();

create trigger tip_entries_fold_delete after delete on public.tip_entries
  referencing old table as old_rows
  for each statement execute function private.fold_legacy_writes();
```

- *Measured:* `after insert or update ... referencing new table as nt for each statement` fails with `transition tables cannot be specified for triggers with more than one event`, and an OLD TABLE is invalid for INSERT. So three triggers over one function, which branches on `TG_OP`.
- **Statement-level, not row-level.** A per-row AFTER trigger is *correct* (measured: one multi-row INSERT of both rows of a group yields cash 5000, credit 2000, 2 ids) but folds the same group once per row, and `PaydayRemoteRepository.batchSize = 500` makes that up to 500 recomputes inside one old build's transaction. Timeout-proneness **is** a rejected write.
- **AFTER, never BEFORE**, so `tip_entries_touch_version` is undisturbed.
- `insert ... on conflict do update` routes inserted rows to the INSERT trigger and updated rows to the UPDATE trigger, so `upsert_tip_entries` is fully covered.

### 4.3 The touched set: old keys union new keys

An UPDATE that moves a row between groups must recompute the **old** group too. Three live producers of a key change:

1. `upsert_tip_entries` updates `shift_id` and `work_date` unconditionally (`20260904134500:138-139`), with no staleness guard.
2. `RemoteTipEntry.workDate = PaydayRemoteDate.day(entry.date)` (`PaydayRemoteModels.swift:91`) is computed in the device's **current** zone at push time, and `PaydayRemoteDate.day` re-extracts in `.current` (`:12-20`), so a relocated 1.0 device re-pushes the same row under the adjacent civil day.
3. `update_tip_entry` accepts `shift_id` (`index.ts:2136`, `updateRow` passes `tipPayload(body, true)`).

Recompute only the new key and the old shift keeps the money while the new one gains it: double-counted money with nothing to detect it.

```sql
v_keys := array(
  select distinct k from (
    select private.legacy_group_key(n.shift_id, n.work_date) as k
      from new_rows n where n.user_id = v_uid
    union
    select private.legacy_group_key(o.shift_id, o.work_date)
      from old_rows o where o.user_id = v_uid
  ) u);
```

**The account comes from the rows, never from `auth.uid()`.** The agent writes as `service_role`, for which `auth.uid()` is null, so scoping by it writes `user_id` null (a NOT NULL violation, i.e. a rejected write) or folds nowhere. The function reads `v_uid` from the transition tables and loops per account for the rare multi-account service-role statement.

*Measured and binding:* inside a `security definer` body `current_user` is the **owner**, not the caller, so service-role detection uses `coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role'`. And a `security invoker` body calling into schema `private` fails with `42501`, because `20260831164348:3` revokes it; `grant usage on schema private` is explicitly **not** the fix. Everything reaching into `private` here is `security definer ... set search_path = ''` with fully qualified names. `private.touch_versioned_row` on `tip_entries` is the live precedent that a `private` trigger function fires fine for `authenticated`.

### 4.4 The four write arms

**All four arms read ONE evaluation of `grouped`.** The chain of 3.2 is evaluated once per invocation into a plpgsql local and every arm plus the conservation check reads that local:

```sql
v_grouped jsonb := (select coalesce(jsonb_agg(to_jsonb(g)), '[]'::jsonb)
                    from ( <the source/ranked/owned/grouped chain of 3.2> ) g);
-- then, in each arm:
--   from jsonb_to_recordset(v_grouped) as g(id uuid, work_date date, ...)
```

This is normative, not stylistic. The arms are printed below against `grouped` for readability; a worker who instead repeats the CTE chain per arm gets four copies of the gratuity rule and **four snapshots**, because at READ COMMITTED each statement takes a fresh one and a concurrent writer that lost the try-lock still COMMITS its legacy row before returning (4.7). 4.7's reentrancy note already rules out the obvious alternative (`create temporary table ... on commit drop` makes the body non-reentrant), which is why the local is `jsonb` and not a temp table.

**Arm 1: the upsert of derived groups.** `deleted_at` guarded **per column**, provenance written **unconditionally**, and the conflict predicate **never** filtering on `deleted_at`:

```sql
insert into public.shifts (
  user_id, id, work_date, shift_period, cash_tips_cents, credit_tips_cents,
  tip_out_cents, sales_cents, hours_worked, clock_in, clock_out, server_count,
  receipt_metrics, note, recorded_at, source, legacy_entry_ids,
  legacy_source_max_updated_at, converted_at, client_updated_at)
select v_uid, g.id, g.work_date, g.shift_period, g.cash_tips_cents, g.credit_tips_cents,
       g.tip_out_cents, g.sales_cents, g.hours_worked, g.clock_in, g.clock_out, g.server_count,
       g.receipt_metrics, g.note, g.recorded_at, 'migration', g.legacy_entry_ids,
       g.source_max_updated_at, statement_timestamp(),
       least(g.source_max_updated_at, statement_timestamp())
from grouped g
on conflict (user_id, id) do update set
  -- EVERY money/state column takes the identical CASE:
  cash_tips_cents = case when private.shift_is_open_to_fold(public.shifts.*)
                         then excluded.cash_tips_cents else public.shifts.cash_tips_cents end,
  -- ... work_date, shift_period, credit_tips_cents, tip_out_cents, sales_cents,
  --     hours_worked, clock_in, clock_out, server_count, receipt_metrics, note,
  --     recorded_at, client_updated_at ...
  converted_at = statement_timestamp(),
  legacy_entry_ids = excluded.legacy_entry_ids,
  legacy_source_max_updated_at = excluded.legacy_source_max_updated_at,
  unconverted_legacy_cents = case when private.shift_is_open_to_fold(public.shifts.*) then 0
    else abs(<folded non-wage cents> - public.shifts.non_wage_earnings_cents) end;
-- NO `where` CLAUSE. EVER. See the comment below.
```

```
-- A WHERE on this DO UPDATE is the measured INSERT 0 0 no-op, which under
-- this shape rejects a shipped 1.0 build's write. The predicate an earlier
-- draft carried here, `where public.shifts.user_id = v_uid`, was harmless
-- (always true, given the (user_id, id) conflict target and the supplied
-- v_uid) and therefore worse than useless: it preserved in the file the
-- exact statement shape a future edit can make false, in the one statement
-- that runs inside a 1.0 build's transaction. design-lint.sh bans `on
-- conflict` combined with `where` anywhere in a statement targeting
-- public.shifts.
```

`unconverted_legacy_cents` is `abs(...)`, not `greatest(0, ...)`, and it means **"the magnitude of the latest disagreement"**, never "unconverted money". *Measured on a closed shift at 6000:* a **downward** correction from an old build (6000 to 4000) gave `greatest(0, 4000-6000) = 0` and Data health showed nothing at all; the upward one (4000 to 8000) gave 2000 correctly; and a later arrival that happened to equal the shift erased the earlier disagreement. Downward is the common shape of a correction, so the column could not represent half of what 4.5 promises to surface. It is never accumulated: a repeated re-push of the same row would inflate it without bound. The **account-wide** money figure in `shift_migration_state.unconverted_legacy_cents` is derived from `public.shift_legacy_conflicts` (arm 4), which is append-only and carries both numbers and both directions, and which is the honest surface. Tests `aDownwardLegacyCorrectionOnAClosedShiftIsStillSurfaced`, `aMatchingLateArrivalDoesNotEraseAnEarlierDisagreement`.

```sql
-- A shift is open to the fold only while no human and no agent has touched it.
create or replace function private.shift_is_open_to_fold(s public.shifts)
returns boolean language sql immutable set search_path = '' as $$
  select s.native_modified_at is null and s.deleted_at is null;
$$;
```

*Measured, and the most expensive Postgres fact in this design:* `insert ... on conflict (user_id,id) do update ... where deleted_at is null` against a deleted target reports `INSERT 0 0` and leaves the row **untouched**, so the arriving legacy id is never added to any `legacy_entry_ids`, an orphan check then counts it forever, and any raise afterwards wedges the path. Under shape 2 that wedged the migration; here the same statement runs inside a 1.0 build's transaction, so it **rejects that build's write**. Hence a `CASE` per column, so the partition stays **total** over a closed target, and `deleted_at` is never written by this arm, so nothing resurrects.

Reachable, and ordinary rather than a boundary effect: the user deletes the 2026-07-04 shift on the new build, then an old phone pushes one unsynced $20 cash tip for 2026-07-04. Money landing in a closed shift is **counted and reported**, never silently accepted and never raised.

Keep the comment: *"'Accounted for' has to be a state the schema can represent, not a side effect of a statement that did nothing."*

**Arm 2: the emptied-group arm, in two statements.** A `group by` over an empty source emits nothing. *Measured:* soft-deleting one row of a two-row group re-derives correctly (credit 2000 to 0, 2 ids to 1); soft-deleting the **last** live row leaves the shift at cash 5000 with a stale provenance id, **permanently**. The user deleted the money on their old phone and the new build keeps counting it. Under this shape the arm fires on ordinary 1.0 deletions, continuously.

An earlier draft wrote this as **one** statement gated on `private.shift_is_open_to_fold(s)`, and that single gate was the root of three separate permanent failures. **Provenance and money must be released independently**: provenance unconditionally, exactly as 4.5 already mandates for arm 1, and money only while the shift is open.

**Arm 2a: release provenance. Unconditional. Closed and deleted shifts included.**

```sql
update public.shifts s set
  legacy_entry_ids = '{}',
  legacy_source_max_updated_at = v_watermark,
  converted_at = statement_timestamp()
where s.user_id = v_uid and s.id = any(v_keys)
  and not exists (select 1 from grouped g where g.id = s.id)
  and array_length(s.legacy_entry_ids, 1) > 0;
```

**Arm 2b: release the money and tombstone. Only while open.**

```sql
update public.shifts s set
  cash_tips_cents = 0, credit_tips_cents = 0,
  tip_out_cents = null, sales_cents = null, hours_worked = null,
  clock_in = null, clock_out = null, server_count = null, receipt_metrics = null,
  deleted_at = coalesce(s.deleted_at, statement_timestamp()),
  deleted_reason = coalesce(s.deleted_reason, 'converted')
where s.user_id = v_uid and s.id = any(v_keys)
  and not exists (select 1 from grouped g where g.id = s.id)
  and private.shift_is_open_to_fold(s);
```

Arm 2b runs **before** 2a in the body, so `shift_is_open_to_fold` is still evaluated against the pre-release row and 2a's `array_length(...) > 0` still selects it. A **closed** emptied shift keeps its money — the user's own edit wins, per 4.5 — and arm 4 records the disagreement as a `shift_legacy_conflicts` row so it is surfaced rather than silently retained.

**Why 2a must be unconditional.** With the single gated statement, a closed shift whose sources move away or get tombstoned keeps naming rows it no longer derives from, forever, and that one stranded claim causes all three of:

1. **The night is displayed twice, on two different dates.** Every leg verified in shipped code: legacy row E (nil `shift_id`) folds into shift S keyed `payday_legacy_shift_id('2026-07-04')`; the user fixes hours on the new build so S is CLOSED; a 1.0 device re-pushes E from another time zone, where `RemoteTipEntry.init(entry:userID:)` sets `workDate = PaydayRemoteDate.day(entry.date)` with `calendar: .current` (`PaydayRemoteModels.swift:91`, `:12-20`) and `upsert_tip_entries` updates `work_date` and `shift_id` unconditionally (`20260904134500:138-139`). E's key becomes `payday_legacy_shift_id('2026-07-03')` = S'. `v_keys` is `{S, S'}` per 4.3, `grouped` holds S' only, arm 1 inserts S' with E's money — and the gated arm skipped S because it is closed. Jul 3 and Jul 4 both show the night, and 5.5's duplicate detector groups by `work_date`, so **two different dates are never reported**. The same key change is reachable two other ways this design already admits: `update_tip_entry` accepts `shift_id` (`index.ts:2136`, 9.1) and 6.4's backfill mint. 9.1's claim that this is "covered by 4.3 and 5.5" was false.
2. **`v_dupes` in 5.3 returns 1 forever**, because E is named by two shifts and the count unnests over every shift of the account including deleted ones.
3. **`payday_unmigrated_tip_row_count()` never returns 0**, because the `unmigrated` predicate left-joins E to `named` twice and the S row carries the stale watermark. 5.6 then has the client re-invoke the one-shot on every pass forever, and 4.8's "with the trigger installed the steady state is exactly 0" would be false.

`deleted_reason = 'converted'` is why 2b is reversible: arm 3 may clear a tombstone **it** set and never a user's. Tests: `emptying_every_row_of_a_group_tombstones_its_shift`; `aClosedShiftWhoseSourcesMoveAwayLosesItsClaimAndIsReported`; `aNativelyEditedShiftWhoseLegacyRowsWereDeletedKeepsItsMoneyAndRecordsAConflict`.

**Arm 3: the un-delete arm.** A legacy un-delete is a first-class live path on both writers. `RemoteTipEntry(entry:userID:)` hardcodes `self.deletedAt = nil` (`PaydayRemoteModels.swift:106`), and `upsert_tip_entries` lost its staleness guard in `20260904134500` (compare `:137-154`, a bare `deleted_at = excluded.deleted_at`, with `20260831165043`), so **every** 1.0 push of a locally present row writes `deleted_at = null` over a server tombstone. The agent's `restore_tip_entry` (`index.ts:2148`) is the feature version. Without this arm the source row comes back, its money is back in `tip_entries`, and the shift stays tombstoned forever: the new build shows nothing while the old build shows the night.

```sql
update public.shifts s set deleted_at = null, deleted_reason = null
where s.user_id = v_uid and s.id = any(v_keys)
  and s.deleted_reason = 'converted' and s.native_modified_at is null
  and exists (select 1 from grouped g where g.id = s.id);
```

Runs **before** arm 1, so the reopened shift is then filled by arm 1's `CASE`. A user deletion (`deleted_reason = 'user'`, and `native_modified_at` non-null anyway because `soft_delete_shifts` is a native write) is never cleared.

**Arm 4: the conflict record.** When arm 1 declined money because the shift is closed and the numbers actually disagree:

```sql
insert into public.shift_legacy_conflicts
  (user_id, shift_id, detected_at, shift_cents_before, legacy_cents_after)
select v_uid, g.id, statement_timestamp(), s.non_wage_earnings_cents, <folded non-wage cents>
from grouped g join public.shifts s on s.user_id = v_uid and s.id = g.id
where not private.shift_is_open_to_fold(s)
  and s.non_wage_earnings_cents <> <folded non-wage cents>;
-- plus the emptied-and-closed case from arm 2b, which has no `grouped` row:
insert into public.shift_legacy_conflicts
  (user_id, shift_id, detected_at, shift_cents_before, legacy_cents_after)
select v_uid, s.id, statement_timestamp(), s.non_wage_earnings_cents, 0
from public.shifts s
where s.user_id = v_uid and s.id = any(v_keys)
  and not exists (select 1 from grouped g where g.id = s.id)
  and not private.shift_is_open_to_fold(s)
  and s.non_wage_earnings_cents <> 0;

create table public.shift_legacy_conflicts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  shift_id uuid not null,
  detected_at timestamptz not null default now(),
  shift_cents_before integer not null,
  legacy_cents_after integer not null);
create index shift_legacy_conflicts_user_idx
  on public.shift_legacy_conflicts (user_id, detected_at desc);
```

Append-only, low volume, informational. **Not** the deleted `ShiftDivergence`: no resolve behaviour, no `Kind` cases, no store, and the device only renders it.

### 4.5 The precedence rule (the decision, stated once)

> **A shift that has been natively edited, natively authored or natively deleted is CLOSED to the fold.** Its money columns are never rewritten by a conversion. The arriving legacy value is recorded (`unconverted_legacy_cents`, `shift_legacy_conflicts`) and shown in Data health. Provenance (`legacy_entry_ids`, `legacy_source_max_updated_at`, `converted_at`) is written unconditionally, so the partition stays total and nothing is orphaned.

`native_modified_at` is set by `private.write_shifts` (the device and API path) and by **nothing else**: never by a client payload, never by the fold. `converted_at` is stamped by `derive_shifts` on every conversion.

Why the alternative was rejected: `tip_entries` stays a write surface indefinitely and old builds never learn anything changed, so a 1.0 phone on the same account can re-push the legacy rows of a shift the user already corrected, **at any time, forever**. Conversion is whole-group, so one late legacy row would destroy **every** new-build edit in its group: a user fixes hours 7.5 to 8.0, adds a note, corrects a tip-out; days later any single row of that day is re-pushed and all three revert. Last-fold-wins would make `ShiftCommands.update` a lie, and claims, divergence, the sweep and `adopted_at` are all deleted, so nothing else could see it.

The cost, stated honestly: an old build's genuine **correction** to a closed shift does not apply automatically. It is recorded with its numbers and surfaced, and applying it is a user action in Data health. That is the right side to err on, because the newer edit was made on the device the person is actually using.

**That user action is required, not optional, and it is the exit from 4.9's frozen over-count.** Each `public.shift_legacy_conflicts` row renders in Data health as "An older device reported $70.00 for Jul 4; Payday is showing $50.00" with **[Keep mine]** and **[Use theirs]**. `[Use theirs]` runs an ordinary `ShiftCommands.update` with the legacy numbers, which is a native write, so the shift stays closed and nothing refolds. Without it, every path in 4.5 and 4.9 that "records and surfaces" a disagreement is a dead end with no resolution, and 4.9's claim that money converges is false on its most reachable path (see 4.9). Ships in S13. Test `aConflictResolvedWithUseTheirsMatchesTheLegacyNumbersAndStaysClosed`.

The same rule answers three other hazards for free: a restored shift is closed, so a later fold can never re-tombstone it (which is why no device-side legacy un-delete is needed); a fold bumps `updated_at` and `derived_version` but not `version` (2.7); and a 1.0 device that loses its checkpoint and mass-re-pushes its whole history (`PaydaySyncState.changedIDs` returns every local id when `acknowledged` is empty, `PaydaySyncState.swift:204-211`) can only rewrite shifts no human has touched, bounded further by 5.5's bulk banner.

### 4.6 The fold never raises

1. **The body is wrapped** in a plpgsql exception block that records `(user_id, group_keys, sqlstate, message, at)` into `private.shift_fold_failures`, **queues `v_keys` into `private.shift_fold_backlog`**, and returns. `when others` is not sufficient and was the single largest hole in this document's first draft:

   ```sql
   exception
     when query_canceled then    -- 57014 statement_timeout. NOT caught by OTHERS.
       insert into private.shift_fold_failures ...;
       insert into private.shift_fold_backlog ... on conflict do nothing;
       return null;              -- one bounded insert pair, then leave. See below.
     when assert_failure then    -- also NOT caught by OTHERS.
       ... same ...
     when others then            -- check_violation, 22P02, 22003, 40P01, 23505 ...
       ... same ...
   ```

   *Measured on PG 17.11, in the exact trigger shape:* PL/pgSQL's `OTHERS` deliberately excludes `QUERY_CANCELED` and `ASSERT_FAILURE`, and `statement_timeout` raises exactly `57014`, so a `when others` handler around a slow fold never fires — the `raise notice` does not print and the statement aborts with `canceling statement due to statement timeout`. With a `when query_canceled` arm instead, the 1.0-shaped `insert into legacy ...` under `set statement_timeout='500ms'` around a 3-second fold returned `INSERT 0 1`, the legacy row committed, exactly one row landed in the failures table with sqlstate `57014`, and the backlog got the key. That is the whole rule, and without the named arm the one abort class 1.4 calls out by name and 4.7 identifies as *the* dark-app killer is the one the handler cannot trap.

   **Catching `57014` does not re-arm the timer** (*measured:* 2 seconds of further work inside the handler after a 500 ms timeout completed and committed). So the handler is unbounded, which is exactly why it must do only the two bounded inserts and return immediately — no retry, no re-derive, no second pass.

   **Queueing the keys on the exception path is not optional.** An earlier draft recorded the failure and returned without queueing, so a caught abort silently dropped the work: the group was never converted, `payday_unmigrated_tip_row_count()` stayed positive forever, and the only recovery was the one-shot, which reproduced the identical abort. One bad receipt scan on one night took the account dark permanently.

   *Also measured, and still true:* such a block inside the same transaction contains both a `check_violation` from the fold's insert and a `22P02` from a CHECK's numeric cast, and the enclosing statement still commits.
2. **Every cast is guarded by `jsonb_typeof` first.** No exception.
3. **Every money value is clamped in the fold**, not validated by a CHECK.
4. **Every constraint on `public.shifts` must be satisfiable by construction from any row `tip_entries` can legally hold, and a generated column IS such a constraint.** Verified: `tip_entries` already constrains `amount_cents >= 0`, `kind`, `hours_worked >= 0`, `tip_out_cents >= 0`, `sales_cents >= 0`, `shift_period`, `server_count >= 0`, `client_updated_at not null` (`20260831164348:18-39`). `receipt_metrics` is the one unconstrained column, which is why 2.5, 2.3 and 3.4 exist. `gratuity_fees_cents` and `non_wage_earnings_cents` were the counterexample this rule missed once: `{"gratuityFeesCents": 99999999999}` is legally storable in `tip_entries` today and aborted arm 1 with `22003`. Fixed in 2.3 by clamping in `numeric` space in both expressions.
5. **No new CHECK may be added to `public.shifts` that a derived value could violate.** Review rule.
6. **The conservation check never raises, on either path.** It records `shift_migration_state.conservation_failed_at` plus the `orphans / dupes / in / out / touched` detail and **commits anyway**. Committing a wrong number that Data health flags is strictly better than a dark app, and that is Tyler's stated trade — and the earlier draft applied that trade to the old build while reversing it for the new one via `p_strict := true`, on the one code path the new build depends on. See 3.1 and 5.3.
7. **No `raise` anywhere, in either path.** Use the failures table and `conservation_failed_at`.

```sql
create table private.shift_fold_failures (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  group_keys uuid[] not null,
  sqlstate text not null, message text not null,
  at timestamptz not null default now());
```

**S-gate**, which would have caught shape 2 in one round. Install the trigger, then for **each** forced-abort class assert a **1.0-shaped** `upsert_tip_entries` call still returns 200, the row is present in `tip_entries`, exactly one row landed in `private.shift_fold_failures` with the expected sqlstate, and the touched keys are in `private.shift_fold_backlog`:

| forced | how | class |
|---|---|---|
| poisoned receipt payload | `{"earningsSchemaVersion": true}` reaching a CHECK's cast | `22P02` |
| out-of-range gratuity | `{"gratuityFeesCents": 99999999999}` with the 2.3 clamp **removed** in a test fixture of the DDL | `22003` |
| statement timeout | `set statement_timeout` to `1ms` on a helper, or a `pg_sleep` behind a test GUC inside the fold | `57014` |
| assertion | `assert false` behind the same test GUC | `assert_failure` |
| deadlock | two sessions taking row locks on two shifts in opposite orders, with `private.write_shifts`' advisory lock removed in the fixture | `40P01` |

The 57014 and 40P01 rows are the ones an earlier draft never measured, and they are the two most likely aborts inside a 500-row 1.0 batch. No `statement_timeout` is set anywhere in `supabase/migrations`, so the `authenticated` role's platform default governs; `PaydaySyncService.swift:25` sends `batchSize = 500` and `:321` retries the identical payload, so one untrapped timeout is permanent darkness for that device. Honest calibration: the realistic fold measures **14.6 ms** for a 500-row / 250-group `upsert_tip_entries` on a warm local cluster, so 57014 is a contended or pathological case (a large backlog drain, gin index maintenance, lock waits) rather than the common one — it is in the gate because the failure is permanent and, without the named arm, leaves no trace anywhere.

### 4.7 Locking, ordering against the one-shot, and the work budget

**The lock.** *Measured with the fold as an AFTER trigger and no per-group lock:* session A inserts a $50.00 cash row and holds its transaction open; session B inserts the $20.00 credit row and commits; result `cash = 0, credit = 2000`, provenance length 1, and the cash row named by no shift at all. At READ COMMITTED, B's recompute took its snapshot before A committed, so `excluded` described only B's row and `do update` overwrote. Mainline (two devices on one account, or one device retrying while the agent writes), not exotic. Neither prior shape could see it: shape 1 reconciled afterwards on the device, shape 2 had one writer.

**Three writers take the same per-account key**, so no two can interleave and deadlock between them is unrepresentable:

```sql
-- the fold (in a 1.0 build's transaction): non-blocking
pg_try_advisory_xact_lock(hashtextextended('payday:shiftmig:' || v_uid::text, 0))
-- the one-shot, and private.write_shifts: blocking
pg_advisory_xact_lock(hashtextextended('payday:shiftmig:' || v_uid::text, 0))
```

`private.write_shifts` taking it was missing from the first draft and it is what closes the one structurally reachable deadlock: the fold holds row locks on shifts X then Y while a native shift write holds Y then X, and a `40P01` inside the fold is a rejected 1.0 write. Serializing all three per account makes the shape impossible; the `when deadlock_detected` path in 4.6 stays as the belt.

**The fold uses `pg_try_...` and on failure does not block and does not raise**: it queues the touched keys into the backlog and returns. Blocking would put an old build's write behind a possibly long migration and into a client-side timeout, which is a rejected write.

**And the measurement quoted above for the blocking lock is NOT evidence for the non-blocking one.** An earlier draft cited it as such. *Re-measured on the same fixture — A inserts $50.00 cash and holds open, B inserts the $20.00 credit row of the same `shift_id` and commits, then A commits:*

| lock | shifts row | backlog | `tip_entries` truth |
|---|---|---|---|
| `pg_advisory_xact_lock` (blocking) | cash 5000, credit 2000, non-wage 7000, prov 2 | 0 rows | 7000 |
| `pg_try_advisory_xact_lock` (what ships) | cash 5000, credit **0**, non-wage **5000**, prov 1 | 1 row | 7000 |

So the shipping variant leaves the authoritative read surface **under-counted** until the backlog drains, and 4.9's stated invariant that the transient error is "an over-count, never an under-count" is false. Three things contain it, and all three are load-bearing: 6.3's first-switch predicate 2 rejects the switch while any local `TipEntry` id is unnamed, so a device that has not yet switched is unaffected; `payday_unmigrated_tip_row_count()` counts the backlog (5.6), so an already-switched device always learns there is work; and the drain is an explicit numbered step in 7.5, so the under-count cannot persist for a whole pass undetected. Test `aConcurrentLegacyWriteThatLosesTheLockIsStillCountedAfterTheNextSync`.

```sql
create table private.shift_fold_backlog (
  user_id uuid not null references auth.users(id) on delete cascade,
  group_key uuid not null,
  queued_at timestamptz not null default now(),
  primary key (user_id, group_key));
create index shift_fold_backlog_queued_idx
  on private.shift_fold_backlog (user_id, queued_at);
```

**Every insert into it is `on conflict (user_id, group_key) do nothing`, in sorted key order.** With neither, two concurrent 1.0 writes that both miss the try-lock — three sessions on one account, or one device retrying while the agent writes, which is the exact population the lock exists for — insert the same key: one blocks on the other's uncommitted index entry until that transaction commits, putting a 1.0 write behind another 1.0 write, then raises `23505` on commit. 4.6 catches it, which means the keys are dropped from the failing session entirely. Test `two_sessions_queueing_the_same_group_neither_block_nor_raise`.

**Reentrancy**, all verified and all now applicable because the trigger fires several times per transaction: the advisory lock is reentrant for the same session, so a second call inside one transaction does not self-deadlock; `create temporary table ... on commit drop` makes a body **non-reentrant** (`relation "_incoming" already exists` on the second call), so normalize into a `jsonb` or array local instead; catalog functions stay **unqualified** under `set search_path = ''` because `pg_catalog` is always searched first and `coalesce` / `least` / `greatest` are SQL constructs with no schema (measured: `function pg_catalog.coalesce(integer, integer) does not exist`); and `from incoming i, unnest(...) as lid join ... on ... i.id` fails with `invalid reference to FROM-clause entry for table "i"`, so it must be `cross join lateral unnest(...)`.

**The work budget.** Conversion runs inside the old build's statement, under the `authenticated` role's `statement_timeout`, at `batchSize = 500`. A first sign-in or a checkpoint-loss re-push can touch hundreds of groups in one transaction, and a timeout means 1.0 retries the identical batch forever: the dark-app failure with no raise anywhere in the code. So:

```
budget := 50 groups per statement, SPLIT and RESERVED, never a remainder:
  40 for the touched keys (freshness first);
  10 for the oldest backlog entries by queued_at;
  the 10 roll into the touched keys only when the backlog is empty.
1. derive the reserved backlog groups and the fresh groups together, in one
   call to private.derive_shifts, so there is one evaluation of `grouped`;
2. queue any touched key beyond the 40 into private.shift_fold_backlog;
3. DELETE the drained keys:
     delete from private.shift_fold_backlog
      where user_id = v_uid and group_key = any(v_spend);
   which rolls back with a failed derive, so nothing is lost.
```

**The reservation is what makes progress guaranteed, and the first draft's "spend any leftover budget" yielded exactly zero leftover in the case that creates the backlog.** *Measured, one shipped-shaped `upsert_tip_entries` of 500 rows across 250 groups (`PaydaySyncService.swift:25` sends `batchSize = 500`):* `tip_entries` 500 rows / shifts written 50 / backlog 200 / fold failures 0, in 14.6 ms. A second 500-row batch behaved identically — 50 fresh groups folded, **0 drained**. So at `batchSize = 500` a device re-pushing its whole history never drained a single backlog entry through the trigger, which is precisely the first sign-in and checkpoint-loss re-push the budget exists for. With the reservation, every legacy write drains at least 10.

**The deletion rule was also absent**, so written as specified the backlog grew monotonically and re-folded the same groups forever. It is stated above and repeated in the one-shot.

The backlog drains three ways and needs no cron: any subsequent legacy write from any device, now with a reserved share; any new-build sync, through the explicit drain step in 7.5; and Tyler as `service_role`. An account with no new build has nothing reading `shifts`, so a backlog there is harmless by construction. Tests: `aFiveHundredRowBatchDrainsAtLeastTenBacklogGroups`, `theBacklogIsEmptyAfterNSyncPassesForA250GroupHistory`, `aSaturatingStatementStillDrainsOneBacklogGroup`.

**Before shipping, measure** the 500-row / N-group case on PG 17.11. Do **not** set a function-local `statement_timeout` and assume it helps: the cutover verified only that a function-local `SET` clause is legal, never that it re-arms a timer already running from the outer statement's start.

### 4.8 What the trigger does NOT do

- It does not reject, raise or validate anything, ever.
- It does not write `deleted_at` except in arms 2b and 3, and never against a user deletion. Arm 2a writes provenance only, which is why it can be unconditional.
- It does not touch money on a closed shift, does not read `auth.uid()`, does not derive an id from more than one row, and does not bump `version`.
- It does not fire on every path that can put a legacy row in the table, and cannot be made to. `session_replication_role = 'replica'` disables triggers, which is what `pg_restore`, logical replication and PITR use; `alter table ... disable trigger` does the same; and rows present before the trigger deployed were never seen. **All three are recoverable only through the `unmigrated` predicate (5.2) and `payday_unmigrated_tip_row_count()`**, which is the strongest argument for keeping both and alerting on a sustained non-zero: with the trigger installed the steady state is exactly 0. That claim is only true because arm 2a releases provenance unconditionally (4.4) and because the count is defined as the same expression as the predicate (5.6). Under the first draft's gated arm 2 the steady state was permanently non-zero for any account with one deleted converted shift, and the alert would never have fired for the one class of drift it exists to catch.
- The DELETE arm **no-ops during account deletion.** `public.delete_my_account()` deletes the `auth.users` row and every Payday table cascades (`20260911150000:9-18`, `:46`). An arm that tried to insert or update `public.shifts` during that cascade would hit `shifts.user_id references auth.users(id)` and could **fail account deletion**, which is the Guideline 5.1.1(v) requirement Payday was rejected over once already. So the arm begins with `if not exists (select 1 from auth.users where id = v_uid) then return null; end if;`, with a test that `delete_my_account` still succeeds with shifts, conflicts, backlog and legacy rows present.

### 4.9 A shift whose rows arrive in separate transactions

The normal case for every 1.0 edit, not an edge case: `synchronize` calls `repository.upsertTips(changedTips)` then `repository.softDeleteTips(pendingTipDeletions)` as two PostgREST RPCs, i.e. two transactions, in that order (`PaydaySyncService.swift:321-324`). So an edit that both rewrites and removes rows commits a shift containing **both** the old and the new money first, and becomes correct only after the second call.

Accepted deliberately, with two corrections to the first draft's framing.

**The transient error can be an under-count as well as an over-count.** The upsert-then-softDelete sequence over-counts; a batch boundary at `batchSize = 500`, a retried partial batch, or a lost try-lock (4.7) under-counts. *Measured for the plain sequential case:* one transaction per row leaves `5000 / 0 / prov 1` before converging to `5000 / 2000 / prov 2`. So **no client assertion, conservation check or verifier may throw on a partial shift**, the readers must tolerate a zero-tip shift, a missing kind and a negative net, and a shift that gains its second leg later must update **in place on the same id**. Tests `aHalfArrivedShiftRendersWithoutThrowing`, `aShiftThatGainsItsSecondLegLaterUpdatesInPlace`, `aShiftThatIsTemporarilyUnderCountedIsNotFlaggedAsDrift`.

**"Money converges" is false on one reachable path, and the exit is a user action.** If the user opens the wrong-looking night on the new build *during* the window — which is precisely when a person notices a wrong number and tries to fix it — `native_modified_at` is set, and when the second RPC arrives 4.5 closes the shift and arm 1 declines the correction into `unconverted_legacy_cents` plus a `shift_legacy_conflicts` row. The number **freezes** rather than converging. Reordering the two RPCs does not fix it: flushing deletions first merely turns the over-count into an under-count, and a user editing a too-low night freezes it too. So the frozen case is named here, not papered over, and its exit is 4.5's `[Use theirs]` action in Data health. Test `anOverCountCorrectedByTheUserMidWindowIsFrozenSurfacedAndResolvableInOneTap`.

The alternative (mark the group stale and fold at end of transaction) would break "same transaction" and is not built.

---

## 5. The one-shot migration

### 5.1 Why it still exists

The trigger catches live changes. The one-shot is the **only** recovery for what the trigger never saw: pre-deploy rows, `replica`-mode loads, disabled-trigger windows, and the backlog. Without it those rows are invisible forever, and it is also what makes "no lockout" safe, because it is re-runnable.

```sql
create or replace function public.migrate_tip_entries_to_shifts(
  p_user_id uuid default null, p_max_groups integer default 200)
returns public.shift_migration_state
language plpgsql security definer set search_path = '' as $$ ... $$;
```

Definer; captures the subject into a local first (`v_uid := coalesce(p_user_id, (select auth.uid()))`, and a non-service-role caller may only name itself); takes the blocking `pg_advisory_xact_lock` on the shared key; `set statement_timeout = '60s'`; calls `private.derive_shifts(v_uid, v_keys)`.

**It is bounded and makes partial forward progress**, which the first draft's version did not. That version had no budget, no batching and no partial commit: its touched set was every unmigrated group union the whole backlog, in one transaction, under a 60-second timeout. A multi-year account — the normal Payday shape — got one all-or-nothing attempt, and if it ever exceeded 60s the whole RPC rolled back, the count was unchanged, and 5.6's loop repeated it identically forever with no state in which the account advanced. So:

- `p_max_groups` caps the touched set at the **oldest** `p_max_groups` groups, backlog first by `queued_at`, then `unmigrated` by `min(client_updated_at)`;
- `shift_migration_state` gains `remaining_group_count integer`, written every run, so the client and Data health see progress as a number rather than a retry;
- drained backlog keys are deleted in the same transaction, exactly as in 4.7, and roll back with a failed derive;
- one invocation per `synchronize` pass (5.6), so the loop is across passes with visible progress, never inside one.

Test `aTwoThousandGroupHistoryConvergesInCeilingOfTwoThousandOverTwoHundredPassesAndNeverRollsBack`.

### 5.2 The `unmigrated` predicate and the watermark

A membership-only predicate cannot see an **edit** or a **tombstone** of a row already named by `legacy_entry_ids`, so deleted money would stay in the shift forever or a correction would never land. The two measured miss sequences: a live row folded by device A then tombstoned by device B stays named and its $60 lives in the shift forever; and a $50 to $40 correction of an already-folded row never applies.

```sql
named as (
  select s.id as shift_id, s.deleted_at, s.legacy_source_max_updated_at,
         unnest(s.legacy_entry_ids) as entry_id
  from public.shifts s where s.user_id = v_uid   -- DELETED shifts included on purpose
),
unmigrated as (
  select e.id, private.legacy_group_key(e.shift_id, e.work_date) as group_key
  from public.tip_entries e
  left join named n on n.entry_id = e.id
  where e.user_id = v_uid
    and ( n.entry_id is null and e.deleted_at is null
       or (n.entry_id is not null and (
             e.deleted_at is not null
             or n.legacy_source_max_updated_at is null
             or e.client_updated_at > n.legacy_source_max_updated_at)))
)
```

```
comment on column public.shifts.legacy_source_max_updated_at is
  'max(client_updated_at) over the tip_entries rows this shift was last '
  'derived from, INCLUDING tombstoned ones. Null on a native or api shift.';
```

**This predicate terminates only because arm 2a releases provenance unconditionally (4.4).** With the first draft's gated arm 2, a closed or deleted shift kept naming rows it no longer derived from, so the third arm (`n.entry_id is not null and e.deleted_at is not null`) and the fourth (`e.client_updated_at > n.legacy_source_max_updated_at`) were satisfied **permanently** and 5.6's loop never ended. Nothing else in the design clears `legacy_entry_ids`, and 4.5 already required provenance be written unconditionally in arm 1, so the gate on the release side was simply an inconsistency. The `named` CTE therefore needs **no** `native_modified_at` exclusion: a closed shift stops naming a row the moment that row leaves its group, and while the row is still in its group the shift genuinely does derive from it.

Caveat to carry: `upsert_tip_entries` writes `client_updated_at = least(row.client_updated_at, statement_timestamp())` (`20260904134500:114`) with no `>=` guard, so a backward-clocked device can write a row whose `client_updated_at` is **below** an already-stamped watermark. The trigger catches that write directly; the predicate would not. A second independent reason both mechanisms must exist.

The one-shot's touched set is `select distinct group_key from unmigrated` union this account's backlog.

### 5.3 The conservation check: recorded, scoped, and closed shifts excluded

**It records, it never raises** (4.6 rule 6, 3.1). `p_strict` is gone. A failure writes `shift_migration_state.conservation_failed_at` plus the `orphans / dupes / in / out / touched` detail, Data health shows it, and the transaction commits.

Account-wide conservation is permanently unsatisfiable once one native shift, one post-conversion edit or one deletion exists. *Measured with the SQL installed verbatim:* account-wide gave `orphans=0 dupes=<NULL> in=4500 out=11500`. Scoped to shifts carrying legacy provenance: pristine `in=8200 out=8200`; after one legal edit (cash 5000 to 6000) `in=8200 out=9200`; after one legal soft delete `in=8200 out=0`. Because `tip_entries` money is immutable to the new build (R1), the "in" side can never move to match a legal edit.

**So scoping by legacy provenance is necessary but not sufficient: closed shifts must be excluded from BOTH sides.** 4.5 requires provenance be written unconditionally onto a closed shift, so provenance-scoping alone still admits every shift whose money the fold deliberately declined. The money arm reads

```sql
and s.deleted_at is null
and s.native_modified_at is null          -- <- the closed-shift exclusion
and s.client_updated_at <= statement_timestamp()
```

and `v_source_cents` excludes the source rows of those same shifts, so the comparison is over exactly the population where equality is a real invariant: shifts nobody has touched, derived from rows nobody has moved. Without the exclusion the check fired on the most ordinary sequence there is, with no concurrency and no clock skew (see 3.1's measured three-run raise).

Capture, in the same statement that computes them and **before** the insert: `v_touched uuid[]` (the group keys derived), `v_source_ids uuid[]` (every non-deleted source row id read), `v_source_cents bigint` (non-wage cents over exactly those rows, derived the way `grouped` does, minus the closed-shift rows). A row that commits mid-transaction is simply not in `v_source_ids` and is left for the next invocation; the shared lock makes that window empty in practice, and the **scoping** is what still matters.

**The duplicate count must be a one-row scalar.** *Measured:* the earlier form (`select count(*) into v_dupes from (...) x group by x.eid having count(*) > 1`) returns one arbitrary group's **occurrence** count and `NULL` when there are no duplicates, which is why every real raise printed `dupes=<NULL>` and read as "the check did not run". It silently disabled half the check for a whole review round.

```sql
select count(*) into v_dupes from (
  select eid from (
    select unnest(s.legacy_entry_ids) as eid
    from public.shifts s where s.user_id = v_uid   -- deleted shifts INCLUDED, on purpose
  ) u
  where eid = any(v_source_ids)
  group by eid having count(*) > 1) d;
```

The predicate asserts a **partition, never a count bijection**: every captured source row is claimed by exactly one shift (live or deleted) and no source row appears in two. Never `count(source rows) == count(shifts)`, because `update_tip_entry` accepts `shift_id` so an agent may already have moved a row, and `legacyRowCount == 0` must pass trivially.

Tests: `the_dupes_count_is_never_null`; the non-vacuity pair `a_wrong_partition_is_still_recorded` / `a_wrong_money_split_is_still_recorded`, each asserting `conservation_failed_at` is set **and** the transaction committed; and the three cases that must **not** record anything — `aNativelyEditedShiftWhoseLegacyRowsWereDeletedDoesNotFlagConservation`, `aClosedGroupInTheBacklogDrainsWithoutFlagging`, `aLegalEditFollowedByThreeReInvocationsNeverFlags`.

### 5.4 The audit row

```sql
create table public.shift_migration_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  migrated_at timestamptz,
  migration_version integer not null default 1,
  source_row_count integer, shift_count integer,
  source_non_wage_cents bigint, shift_non_wage_cents bigint,
  native_shift_count integer, edited_since_conversion_count integer,
  rows_in_closed_shifts integer,
  duplicate_work_date_count integer, duplicate_work_dates date[],
  remaining_group_count integer,
  unconverted_legacy_cents bigint,   -- derived from shift_legacy_conflicts, see 4.4
  conservation_failed_at timestamptz, bulk_legacy_rewrite_at timestamptz,
  last_legacy_write_at timestamptz, last_run_at timestamptz, rollback_at timestamptz);

alter table public.shift_migration_state enable row level security;
create policy sms_read_own on public.shift_migration_state for select to authenticated
  using ((select auth.uid()) = user_id);
revoke all on table public.shift_migration_state from anon, authenticated;
grant select on table public.shift_migration_state to authenticated;
-- No write grant: only the definer functions write it.
```

It is **not** `migration_receipts.schema_version`: that table is keyed `(user_id, device_id)` (`20260831164348:118-132`) and means "this device verified its own upload", so overloading it lets device A trigger the conversion while device B never writes a v2 receipt and any gate reading it concludes B is un-converted.

**`migrated_at` records the FIRST conversion instant and must not move on a re-run.** *Measured:* a second call with nothing unmigrated moved it from `15:38:00.45385` to `15:38:00.491464`. Not rare: the client re-invokes whenever the unmigrated count is positive, and a reinstalled device meeting an already-converted server lands here exactly. Write it as an explicit `CASE` so the next reader sees the rule rather than a missing line:

```sql
migrated_at = case when v_wrote > 0
                   then coalesce(public.shift_migration_state.migrated_at, statement_timestamp())
                   else public.shift_migration_state.migrated_at end,
last_run_at = now()
```

`rollback_at` is likewise never overwritten. Tests `two_consecutive_no_op_invocations_leave_migrated_at_byte_identical`, `an_edit_made_between_two_invocations_is_still_found_by_the_rollback_query`.

**Why `converted_at` exists per shift.** With `adopted_at` deleted, "has the user edited this shift since its conversion?" is a timestamp comparison, and `migrated_at` stops meaning that once conversion is continuous: a shift the trigger converts three months later has `client_updated_at` far above `migrated_at` while being a pure legacy artifact, so rollback would preserve rows it should tombstone and any "edited since" count is inflated. The existing columns cannot substitute: the one-shot writes `client_updated_at = least(source_max_updated_at, statement_timestamp())` while `legacy_source_max_updated_at` is the max over source rows **including tombstoned ones**, so the two are deliberately unequal and comparing them gives both false positives and false negatives. Invariant test: a freshly converted shift has `client_updated_at <= converted_at`, an edited one has `client_updated_at > converted_at`.

**The account-wide counters are informational and never a raise condition.** Column comment: a native post-conversion shift has money in no source sum; an edit moves only the shift side (R1 forbids rewriting `tip_entries`); a post-conversion deletion removes money from the shift side while its sources stay live; and here every trigger conversion is another legal reason, forever. Recorded every run, displayed in Data health. The real check is the invocation-scoped one.

### 5.5 Reported, not prevented

**Same-day duplication.** A post-conversion native shift is keyed by a random `UUID()` because the product supports lunch and dinner on one date, while a folded legacy group keys on `payday_legacy_shift_id(work_date)`. The ids differ, both rows are legal under the composite key, and the night is counted twice. Shape 2 accepted this as a one-time boundary effect; here an old build can produce it any week for years, and refusing to commit would wedge the fold. So it is a **standing surface**, scoped to the touched work dates on the trigger path and account-wide on the RPC path:

```sql
select count(*), array_agg(distinct work_date) into v_dup_dates_count, v_dup_dates
from (select work_date from public.shifts
      where user_id = v_uid and deleted_at is null
      group by work_date, coalesce(shift_period, '')
      having count(*) > 1
         and count(*) filter (where array_length(legacy_entry_ids, 1) > 0) > 0
         and count(*) filter (where array_length(legacy_entry_ids, 1) is null) > 0) d;
```

Data health: "2 shifts logged for Jul 4, review", with a merge action. Test `a_late_legacy_row_for_a_day_that_already_has_a_native_shift_is_reported_not_silently_doubled`.

**Money into a closed shift** is `rows_in_closed_shifts` plus the account-wide total over `shift_legacy_conflicts`, rendered as "$20.00 from an older device arrived for a shift you deleted" and, per conflict row, "An older device reported $70.00 for Jul 4; Payday is showing $50.00" with **[Keep mine]** and **[Use theirs]** (4.5). Silently accepting is not the same as the user having seen it, and surfacing without a resolution is not the same as fixing it.

**A bulk rewrite** is bounded and visible: an invocation touching more than 50 groups, or reopening more than 5 tombstones, stamps `bulk_legacy_rewrite_at` once and Data health shows a banner. That is the defence against one device's cleared defaults rewriting months of `shifts`.

**`last_legacy_write_at`** is stamped by the trigger only when the stored value is older than an hour, so the write rate is bounded and "is any old build still writing, and when did the last one stop?" is one query. It is the only fact that could ever end the transition (1.6).

### 5.6 The companion count

`public.payday_unmigrated_tip_row_count()`, `stable`, definer. **It is literally the 5.2 predicate, plus this account's backlog size:**

```sql
select (select count(*) from ( <the 5.2 `named` + `unmigrated` CTEs> ) u)
     + (select count(*) from private.shift_fold_backlog where user_id = v_uid);
```

One shared SQL definition, the way 3.1 already does for `private.legacy_group_key`, so the count and the predicate are the same expression **by construction** rather than by assertion, and 5.7's "cannot disagree" argument covers the count too.

The first draft described it as "a gin containment count over `shifts.legacy_entry_ids` plus this account's backlog size" while the one-shot acted on the four-armed predicate, and never said which one the client loop was gated on. *Measured in the state of 3.1's failing sequence (closed shift, its one legacy row tombstoned, provenance still naming it):* the containment reading returned **0** while the predicate the one-shot acts on returned **1**. Reading 0, the client never re-invokes, the group is silently never reconciled, and 4.8's alert never fires for the one class of drift it exists to catch. Reading 1, the client loops on the RPC every sync forever. Neither is acceptable and the difference decided the blast radius of a P0.

**The client calls the one-shot at most once per `synchronize` pass** (step 6a of 7.5), never in a loop inside one, and only when the count is positive. `PaydayCloudGate.synchronize` is already wrapped in `while outcome.requiresFollowUpSync` (`PaydayCloudGate.swift:364-371`), so an in-pass loop on a non-decreasing count would be a non-terminating hot loop of 60-second definer calls that never reaches the checkpoint write at `PaydaySyncService.swift:479` and never surfaces, because the `.ready` path swallows and backs off at `:378-387`. `requiresFollowUpSync` is set only when `remaining_group_count` **strictly decreased** this pass.

Alert on a sustained non-zero. Tests `theCompanionCountIsZeroExactlyWhenTheOneShotHasNothingToDo`, driven from a table of the four `unmigrated` arms plus a backlogged group, asserted in the same fixture states as the conservation tests; and `aNonDecreasingRemainingCountIssuesAtMostOneRPCPerPass`.

### 5.7 Why the trigger and the one-shot cannot disagree

One body (`private.derive_shifts`); one group key (`private.legacy_group_key`); one gratuity rule (`private.receipt_gratuity_cents`); one unmigrated expression, shared by the predicate and the count (5.6); one lock namespace (`payday:shiftmig:<uid>`), taken by all **three** writers — the fold, the one-shot and `private.write_shifts` — so their writes are serialized per account and no two can deadlock; one primary key, so re-deriving lands on the same row; one conservation behaviour, since `p_strict` is gone; and one `source` value (`'migration'`), because provenance already distinguishes them and a second value would invite a reader to branch on it.

---

## 6. Client reads and writes

### 6.1 The rules

1. **`shifts` is authoritative for reads** once this account's conversion is verified.
2. **`ShiftCommands` is the only new-build writer of shift state** (section 8).
3. **No device ever derives a shift.** No local grouping of legacy rows into a `ShiftRecord`, no local minting of a legacy shift id for a group the server has keyed, no sweep. The device's `ShiftRecord` store is a **pull-through cache**.

### 6.2 Two legs, and one provably disjoint addition

The device has money that exists only as local `TipEntry` rows in two real cases: an upgrade while offline, and a baseline upload that never completed. Sign-in is mandatory (`PaydayCloudGate.swift:433-456` renders `content()` only in `.ready`), so the never-signed-in case is moot, but those two are not, and with no device derivation those users would see **nothing**.

```swift
@Query private var legacyEntries: [TipEntry]
@Query private var shiftRecords: [ShiftRecord]
private var rows: [ProjectedShiftRow] {
    ShiftProjection.rows(legacy: legacyEntries, records: shiftRecords,
                         readsRecords: cloudState.shiftsAreAuthoritative)
}
```

Both `@Query` declarations exist, because `@Query` is a dependency-tracking property wrapper and a static function returning values is not: replacing the declarations with a call would stop every screen refreshing after a log, edit or delete, and would break `LogTipSheet`'s own 400 ms live-edit total. It is a read projection, not a second deriver: it mints no ids and writes nothing.

**The shift leg is exclusive. The legacy leg is additive, over a disjoint set.**

- `readsRecords == true`: emit rows from `records` only. Nothing reads `legacyEntries`.
- `readsRecords == false`: emit rows from `legacy`, **plus** every `record` whose `legacyEntryIDs` is **empty**.

The first draft said "never a union" and refused all `ShiftCommands` writes on the legacy leg instead (8.7). That was shape 2's "the app goes dark" arriving through the write path. Today an upgraded 1.0 install reaches `.ready` from the cached report with no network at all (`PaydayCloudGate.swift:98-104`) and can log offline all night; after that draft's PR 2 the same user saw their whole history and **could not record tonight's money**, behind copy implying a wait that 4.7's budget, the backlog, or one unfoldable group could make permanent. There was no timeout, no override and no escape, and 6.3's flag is sticky in one direction only.

**The addition cannot double-count, by construction, and the reason is a type-level invariant rather than a review item.** A locally authored `ShiftRecord` carries an empty `legacyEntryIDs` — `ShiftCommands.create` never writes one and only the server's fold ever populates it — so no legacy row in the store names it and no legacy row it names exists. A folded record always carries a non-empty `legacyEntryIDs` and is therefore excluded from the additive leg, where its sources are being read instead. `ShiftProjectionTests` asserts the invariant directly (`aNativeRecordsIDIsNeverInAnyLegacyRowsGroup`, over every fixture) rather than inferring it.

So `ShiftCommands.create` is **allowed** on the legacy leg (8.7), a shift logged offline on the first post-upgrade launch is visible immediately, and it reaches the server exactly once because it has one id from birth.

**Write the reason as a comment on the legs themselves.** The legacy leg is permanent (1.6), and a future PR that deletes it because "the account is converted" reintroduces a $0 history for every offline upgrade.

The imperative sibling `ShiftProjection.rows(in: ModelContext, readsRecords:)` is for contexts with no view to invalidate: `PaydayWidget.swift:67` (verified: that line is `context.fetch(FetchDescriptor<TipEntry>())`), `PeriodTotalIntent.swift:33`, `LogTipsIntent.swift:142`, `MainTabView.swift:138`'s QA deep-link hook, and tests.

**`readsRecords` has exactly ONE definition, reachable from every process.** `PaydaySyncState.shiftsAreAuthoritative(for:)` reads the checkpoint field of 6.3, and the widget, both intents and the app all call it. This is a build fact with teeth: `project.yml:102-136` enumerates the widget's sources file by file and `Payday/Sync/PaydaySyncState.swift` is **not** among them, so S9 must add it along with `ShiftRecord.swift`, `ShiftProjection.swift` and `LegacyShiftRow.swift`, and must touch `project.yml` (which S9's first-draft file list did not). Job B catches the build break; the tempting workaround does not — `AppGroup.swift` **is** in the widget's sources (`project.yml:123`), so a fresh `AppGroup` bool would compile, create a second source of truth for `readsRecords` that no section 11 test covers, and leave the widget printing pre-conversion numbers on the Lock Screen while the app shows post-conversion ones. `design-lint.sh` pins the accessor to one definition, and 11.2's `widgetEntryCents` assertion runs the widget's `buildEntry` through the imperative projection so a diverging flag fails job B.

### 6.3 The reader's switch predicate

Both predecessors keyed the reader on `MigrationRunner.completedVersion`, a local fact produced by a local pass that no longer exists. Read legacy too long and every newly logged shift is invisible, so the user logs it twice and two ids reach the server; switch too early and the history is empty or partial. So the predicate is a **server-sourced coverage fact**, persisted as one checkpoint field, `shiftsAreAuthoritativeAt: String?`, set in the same pass that observes both of:

1. the first `shifts` baseline pull completed (`shiftServerCursor != nil`), and
2. every local non-deleted `TipEntry` id appears in the union of `legacyEntryIDsRaw` across the pulled `ShiftRecord`s, or is in `pendingTipDeletions`.

Never inferred from "zero shifts pulled", which is indistinguishable from an empty account. Once set it is cleared only by `forget`, an account switch, or a rollback.

Predicate 2 is also what contains 4.7's non-blocking under-count on a **first** switch: a backlogged group's legacy ids are named by no shift, so coverage fails and the device stays on the legacy leg. It does **not** protect an already-switched device, which is why the drain is a numbered step in 7.5 and why the count includes the backlog (5.6).

Because the legacy leg is now additive (6.2) and `create` is allowed there (8.7), a long or permanently unsatisfiable coverage wait costs the user **staleness in one direction**, not the ability to use the app. That is the difference between this and the first draft.

### 6.4 The one Swift-side id mint

`MigrationRunner.backfillShiftIDs` decides the key the server sees for the oldest rows, and its defect is live on any fresh install or restored store: `MigrationRunner.swift:65` is `let existing = rows.compactMap(\.shiftID).first` over an unordered `Dictionary(grouping: all)` bucket (line 61), so two devices holding the same day can adopt different ids, and the version-1 arm still runs whenever `version < 1` (line 13, gated only by `guard !pending.isEmpty` on line 50). A nondeterministic backfill splits one night into two shifts **on the server**.

```swift
let distinct = Set(rows.compactMap(\.shiftID))
let id = distinct.count == 1
    ? distinct.first!
    : ShiftDays.deterministicShiftID(for: day, calendar: calendar)
```

Two changes to the first draft, and only one of them is the bug fix. `Set(...)` in place of `.first` is the fix: a day carrying two distinct stored ids plus a nil row leaves the nil row on the **derived** id rather than picking one at random.

**The generation stays 0.** The first draft switched the mint to `ShiftDays.legacyShiftID` (the `5aac5d01` md5 form) and called it "safe by construction". It is not: every shipped 1.0 build still mints `ShiftDays.deterministicShiftID`, the `5aac5d00` day-index form (`ShiftDays.swift:105-124`), and `MigrationRunner.runPending` still runs the `version < 1` arm whenever the AppGroup version key is 0 (`MigrationRunner.swift:13`), which is the state of a store restored from backup into a fresh install. On an account where two devices each hold nil-`shift_id` rows for the same day, one on 1.0 and one on the new build, both backfill and both push, and `upsert_tip_entries` rewrites `shift_id` unconditionally (`20260904134500:138-139`), so that day's group key **flips between the two generations on every pass** — a repeating group-key change, which is the trigger for 4.4 arm 2a's failure family, and it makes the `.first` nondeterminism observable server-side rather than only locally. The stored id is the group key either way (`private.legacy_group_key` is `coalesce(shift_id, ...)`), so generation 0 is already correct and the switch bought nothing.

Consequence: **`ShiftDays.legacyShiftID` is never written** and the Swift md5 port is deleted (2.6). `deterministicShiftID` is not deprecated. Do not change `MigrationRunner.currentVersion`'s step-1 gate. Test `a_1_0_device_backfilling_the_same_day_does_not_rekey_the_group`.

**MigrationRunner's existing steps are legacy writes made by the new build.** Steps 1 and 2 mutate `TipEntry` rows, which bumps `modifiedAt` (every stored property carries `didSet { modifiedAt = .now }`, `TipEntry.swift:46-77`), which puts those ids into `changedIDs`, which the live push leg uploads, which fires the trigger. **Safe by construction** given the fix above: the id `backfillShiftIDs` assigns is the same generation-0 id every shipped build assigns for that day, and the server reads a stored `shift_id` back verbatim as the group key, so nothing is re-keyed by any device on any pass. `recomputeExactHours` changes `hours_worked` and so refolds the group; if the shift is closed, the change is recorded as a conflict. Test `aFreshInstallRunningMigrations1And2DoesNotSplitOrRekeyAnyServerShift`.

### 6.5 Why a stored `shiftID` is trustworthy to the server

`reconcileTips` writes `entry.date = PaydayRemoteDate.parseDay(row.workDate)` (`PaydaySyncService.swift:613`, assigned `:624`), i.e. local midnight of the received civil day **in the zone held at pull time**, and `PaydayRemoteDate.day(_:calendar:)` re-extracts in `.current` (`PaydayRemoteModels.swift:12-20`). So a civil day recomputed from a stored `Date` is zone-dependent and a relocated device derives the **adjacent** day. That is exactly why the server keys off its own `work_date` column and the `shift_id` it actually holds, and never off anything a device recomputes. The whole `LegacyServerFact` apparatus that existed to reconcile a device-derived id with the server's is deleted, because no device derives.

Harmless divergence, noted so nobody chases it: `ShiftDays.groupedByShift` still groups the shipped screens by `row.shiftID ?? deterministicShiftID(for:)` (`ShiftDays.swift:39`). Nothing double-counts, because the shift leg is exclusive and the legacy leg's addition is disjoint by construction (6.2), and nothing suppresses by group key.

---

## 7. Sync changes

### 7.1 What pushes and pulls

| table | push | pull |
|---|---|---|
| `tip_entries` | **unchanged** | **unchanged** (see 7.6) |
| `shifts` | `upsert_shifts`, `soft_delete_shifts`, `restore_shifts` | baseline and keyset delta |
| `paycheck_records` | unchanged | unchanged |
| `user_settings` | unchanged | unchanged |

### 7.2 New checkpoint fields, and the decoder rules

Added to `Snapshot`: `shiftIDs`, `shiftServerCursor`, `shiftClientUpdatedAt`, `shiftServerAckedIDs`, `shiftWriteAttempts`, `pendingShiftRestores`, `shiftsAreAuthoritativeAt`.

**A missing decode line in `Snapshot` is a silent default, not a throw.** It already has a hand-written `init(from:)` using `decodeIfPresent` for every key (`PaydaySyncState.swift:82-93`) and an explicit private `CodingKeys` (`:70-80`), so a forgotten line produces a **write-only field that always loads as its default**: no throw, no checkpoint loss, no test failure. A non-persisting `pendingShiftRestores` loses an undone shift; a non-persisting cursor re-baselines every pass. A lint phrased as "fail any `Codable` with no `init(from:)`" can never fire on this struct. So: `design-lint.sh` compares each `Codable`'s stored-property list in `PaydaySyncState.swift` against the keys assigned in `init(from:)` **and** listed in `CodingKeys`, failing on any property missing from either; and `everySnapshotFieldSurvivesEncodeDecode` is built from a **fully non-default** `Snapshot` and asserted equal after a round trip, so a forgotten key fails as a value mismatch even if the lint is bypassed.

**`PendingDeletions` needs a hand-written all-optional decoder.** It has a **synthesized** decoder (`:100-103`) and `loadPending` swallows `DecodingError` with `try?` (`:305-309`). Swift's synthesized decoder does not use property defaults, so adding keys makes every 1.0-written blob throw `keyNotFound` and **silently drops every queued tip and paycheck deletion**, which is the only carrier of a deletion the 1.0 build made and never flushed.

```swift
private struct PendingDeletions: Codable {
    var tipEntries: [UUID: Date] = [:]
    var paychecks: [UUID: Date] = [:]
    var shifts: [UUID: Date] = [:]
    var shiftTombstones: [UUID: ShiftTombstone] = [:]
    private enum CodingKeys: String, CodingKey { case tipEntries, paychecks, shifts, shiftTombstones }
    init() {}
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        tipEntries = try v.decodeIfPresent([UUID: Date].self, forKey: .tipEntries) ?? [:]
        paychecks = try v.decodeIfPresent([UUID: Date].self, forKey: .paychecks) ?? [:]
        shifts = try v.decodeIfPresent([UUID: Date].self, forKey: .shifts) ?? [:]
        shiftTombstones = try v.decodeIfPresent([UUID: ShiftTombstone].self, forKey: .shiftTombstones) ?? [:]
    }
}
struct ShiftTombstone: Codable, Equatable { var deletedAt: Date; var flushedToServer: Bool = false }
```

`ShiftTombstone` is local only, never a wire type. **Normative: every persisted `Codable` in `PaydaySyncState.swift` has a hand-written decoder in which every key is optional. No exceptions.**

Test `pendingDeletionsDecodeA10ShapedBlob`: write a 1.0-shaped blob into `AppGroup.defaults`, assert `pendingTipDeletions(for:).count == 1` and `pendingShiftDeletions(for:).isEmpty`.

**The 1.0-shaped blob is an ARRAY, not an object, and the first draft's fixture was wrong in a way that would have sent a worker to change the storage shape.** `[UUID: Date]` is not encoded as a JSON object, because `UUID` does not conform to `CodingKeyRepresentable`; Swift encodes it as a flat unkeyed array with `Date` as a number. *Measured:*

```
encoded:  {"tipEntries":["11111111-1111-1111-1111-111111111111",0],"paychecks":[]}
the draft's literal {"tipEntries":{"<uuid>":"…"},"paychecks":{}} decodes as:
  DecodingError.typeMismatch: Expected to decode Array<Any> but found a dictionary
  instead. Path: tipEntries
```

`loadPending`'s `try?` (`PaydaySyncState.swift:305-309`) swallows that, so the count is 0 and the test fails against a **correct** decoder. A worker chasing it is most likely to change `PendingDeletions`' storage shape, which breaks reading every real 1.0-written blob — the exact loss this section exists to prevent. So the fixture is **generated by encoding a two-field struct**, never hand-written, and the section carries the note that these dictionaries are arrays on the wire so nobody "fixes" the shape.

(The section's premise is verified correct: *measured*, Swift's synthesized decoder ignores property defaults and throws `keyNotFound` on an old blob, so the hand-written all-optional decoder is genuinely required.)

### 7.3 Delete `PaydaySyncState.save`; every write goes through `mutate`

`save` (`:264-290`) takes four required parameters, defaults the rest, and constructs a **fresh** `Snapshot`, so any caller that omits a field erases it. Both shipped callers pass the shipped nine only (`PaydaySyncService.swift:479-503`, `PaydayMigrationService.swift:116-131`). Leaving it in place erases every new shift field at the end of every pass: re-baseline every pass, re-push every shift every pass, and `pendingShiftRestores` lost, which silently deletes an undone shift.

```swift
static func mutate(userID: UUID, _ body: (inout Snapshot) -> Void) {
    var s = load(for: userID); body(&s)
    if let data = try? JSONEncoder().encode(s) { AppGroup.defaults.set(data, forKey: key(for: userID)) }
}
```

`save` is **removed**; both callers become one read-modify-write assigning only that pass's outputs. Lint: `PaydaySyncState.save(` appears nowhere. Tests `clearingOneFlagPreservesEveryOtherField`, `aFullSyncPassPreservesPendingShiftRestores`.

### 7.4 Cache baseline: a sibling, not an extra arm

```swift
static func shiftCacheRequiresBaseline(localShiftIDs: Set<UUID>,
                                       pendingShiftDeletionIDs: Set<UUID> = [],
                                       checkpoint: Snapshot) -> Bool {
    !checkpoint.shiftIDs.subtracting(pendingShiftDeletionIDs).isSubset(of: localShiftIDs)
}
```

More load-bearing here: the device may not derive, so a rebuilt cache that lost every `ShiftRecord` is repairable only by a server baseline, and without the sibling the device pulls deltas after a cursor describing shifts it no longer holds and the history is permanently empty. Merging a shift arm into the shipped `cacheRequiresBaseline` (`:216-227`) is wrong in both directions, and `needsServerBaseline` (`PaydaySyncService.swift:335-344`) must **not** gain `shiftServerCursor`, or a first `shifts` sync forces a full tip and paycheck re-download. Evaluate **and persist** in the same pass. Keep the shipped tip and paycheck arms byte-identical.

### 7.5 Ordering inside `synchronize`

The shipped order is push-then-pull (`:321-328`, then `:346-393`), and inverting it globally breaks two verified things: the delta branch's `fetchPaychecks` confirmation read and `verifyServerContainsChangedRows` live **inside** the pull block (`:371-384`), so a pull moved ahead of the paycheck upsert evaluates the subset check before the rows exist and every sync fails with `paycheckMismatch`; and `apply(_:force:)` is called with `force == (PaydaySettingsSyncClock.modifiedAt == localSettings.clientUpdatedAt)` (`:447-448`), true whenever the user did not touch settings during the pass, so a pull ahead of `upsertSettings` clobbers a locally changed wage. **So "pull before push" applies to the SHIFT leg only.**

```
 0. restore_shifts (from the durable pendingShiftRestores queue)
 1. upsertTips            UNCHANGED
 2. upsertPaychecks       UNCHANGED
 3. softDeleteTips        UNCHANGED
 4. softDeletePaychecks   UNCHANGED
 5. upsertSettings (if changed)  UNCHANGED
 6a. payday_unmigrated_tip_row_count(); if > 0, ONE call to
     migrate_tip_entries_to_shifts (5.6). Never a loop inside the pass.
 6. fetchShiftSnapshot | fetchShiftChanges     <- shift PULL, before the shift push
 7. upsertShifts
 8. softDeleteShifts
 9. fetchShifts(ids: writtenIDs ∪ pendingShiftDeletions.keys)   <- post-push readback
10. PULL paychecks + settings   UNCHANGED
11. reconcileShifts / reconcileTips / reconcilePaychecks / apply
12. checkpoint via mutate
```

Recorded-call-order test `firstShiftsSyncPullsBeforePushingAndReadsBackAfter` asserts the sequence and the readback id set, plus `aLocallyChangedWageIsNotRevertedByASyncPass` and `aBrandNewPaycheckDoesNotThrowPaycheckMismatch`.

**Pull-before-push discards an unpushed local edit unless guarded.** `synchronize` always calls `reconcileTips` with `localVersionsAtStart` (`:424-433`), so the only protected edits are ones made **during** the pass, via `localRowChangedDuringSync` (`:591-598`); the `entry.modifiedAt > modifiedAt` arm (`:599-602`) sits behind `else if !forceRemote` and is **unreachable from a sync pass**. Today that is safe only because the device pushes first, so the pulled row is its own echo. Invert the shift leg and a shift the user edited an hour ago, still unpushed, is overwritten by whatever the server holds, including a refold. So `reconcileShifts` takes an extra exclusion set:

```swift
_ = try Self.reconcileShifts(remoteShifts, in: context,
    localVersionsAtStart: localShiftVersionsAtStart,
    locallyDeletedDuringSync: ...,
    locallyChangedBeforeSync: changedShiftIDs,      // NEW
    restoringIDs: Set(checkpoint.pendingShiftRestores.keys))
```

Those ids are skipped by the **pull** leg; steps 7 and 9 settle them.

**The exclusion applies to pull-sourced rows only, and that has to be said explicitly.** `reconcileShifts` is otherwise called once over the merged pull-plus-readback set — the shape `merged` already produces for tips at `PaydaySyncService.swift:385-386` — and an exclusion implemented *inside* `reconcileShifts` the way `locallyDeletedDuringSync` is (`:581`) would discard the **step-9 readback** rows for exactly those ids. The device would then never adopt the server's canonical result for the rows it just wrote — a `client_updated_at` clamped by `least(<incoming>, statement_timestamp())` per 7.8, a sanitized receipt payload per 2.5, or a refold — while still acking its own local value through `acknowledgedVersions` (`:484-490`), so `changedIDs` reports the row clean on the next pass and the divergence is permanent and unpushable. So either call `reconcileShifts` **twice** (pull rows with the exclusion, then readback rows without it) or pass the readback id set explicitly so it can be exempted from `locallyChangedBeforeSync`. Tests `aPulledRefoldDoesNotClobberAnUnpushedLocalEdit` and `aServerClampedClientUpdatedAtOnAJustPushedShiftIsAdopted`.

`reconcileShifts` is otherwise a field-for-field copy of `reconcileTips` (`:570-643`) with **no `forceRemote`**, plus the `restoringIDs` exemption. Reuse `localVersionsAtStart`, `IDsChangedDuringSync`, `localRowChangedDuringSync`, `acknowledgedVersions` and the `locallyDeletedDuringSync` set difference verbatim: copying the shipped shapes is near-zero risk, inventing a rule is not. Keep `requiresFollowUpSync`.

### 7.6 Change nothing in the tip direction

The largest simplification in the sync layer, and deliberate. The shipped push leg keeps flushing `pendingTipDeletions` through `soft_delete_tip_entries` and the shipped pull leg keeps running. Consequences:

- A deletion the 1.0 build queued and never flushed still reaches the server after the upgrade, and the trigger folds it in the same transaction, so the money leaves the shift. The drain apparatus existed only to beat a freeze, so the correct implementation is **no code**. Tests `aDeletionQueuedByTheOldBuildStillReachesTheServerAfterUpgrade`, `anUpgradedDeviceWithNothingPendingIssuesNoTipRPC` (already true: `PaydayRemoteRepository.send` guards `!rows.isEmpty`).
- `verifyServerContainsLocalSnapshot`'s `localTipIDs ⊆ remoteTipIDs` arm (`:534-543`) stays true, so the cutover's whole P0 family around rewriting `fetchSnapshot` and a `tipEntryMismatch` on every launch is moot, and `checkpoint.tipEntryIDs` keeps being refreshed.
- The visible cost: every device keeps downloading `tip_entries` deltas forever and keeps a full local legacy mirror, roughly doubling sync payload and store size. Fine at Tyler's scale. **The danger is that the cost is obvious while the reason is not**, so write the reason as a comment on the legs themselves.

### 7.7 Write outcomes, acked ids, readback

**The write outcome set is total over the rows sent.** A conflict-predicate miss, a violated CHECK, a revoked grant or a fold racing the same primary key can each leave a row unwritten, and acknowledging an id the server did not write is the one way a natively authored shift is lost silently.

```swift
struct ShiftWriteOutcome { enum Status { case written, closedTarget, notWritten }
                           let requestedShiftID: UUID; let status: Status }
```

`upsert_shifts` returns one outcome per requested row; `writeShifts` carries a DEBUG assertion that the outcome id set equals the sent id set. `shiftClientUpdatedAt` advances **only** for `written`. A `notWritten` id is retried on a 1/2/4/8-pass backoff in `shiftWriteAttempts` and surfaced after five attempts as "1 shift couldn't be saved to your account. [Try again] [Show details]". Never dropped locally, never acknowledged: a loop, not a loss.

**`shiftServerAckedIDs` comes from server responses only**, never a local fetch (which would assert local presence as server durability): `acked = (ids returned this pass) minus (ids returned tombstoned)`. The **full** check runs in the baseline branch only, `verifyServerRetainsAcknowledgedShifts(acknowledged:pendingShiftDeletionIDs:remoteShiftIDs:)`; the delta branch calls the same function with `acknowledged` **intersected** with the delta ids, because an accumulating persisted set is unsatisfiable against a keyset delta (pass 2 with nothing changed pulls 0 rows, and N acked ids are not a subset of the empty set).

**Read back in BOTH branches, asserting only ids the server said it wrote.** Today the baseline branch takes `fetchSnapshot` (`:349`) with no per-id readback while `verifyServerContainsChangedRows` runs only in the delta branch (`:379-384`), so the one sync that pushes the whole history verifies nothing. Cursors advance from **pull** rows only; keep the shipped comment at `:387-391` verbatim in the shift leg.

**The shift cursor must not advance into the in-flight window, and this is the one place the shipped cursor shape is NOT safe to copy.** `PaydaySyncState.ServerCursor.advanced` takes the max `updated_at` among **pulled** rows (`PaydaySyncState.swift:19-34`), and `updated_at` is written by `private.touch_shift_row()` as `now()`, which in Postgres is the **transaction** timestamp, while the fold runs in the AFTER-STATEMENT trigger at the end of a 1.0 device's batch transaction (`batchSize = 500` plus up to 50 groups of fold work). Failing sequence: T1 begins at 10:00:00.000 and folds shift S with `updated_at = 10:00:00.000`, committing at 10:00:02; T2 pulls deltas at 10:00:01, cannot see uncommitted S, sees an unrelated row at 10:00:01.500 and advances there; T1 commits; every later delta filters `updated_at > 10:00:01.500` and **S is never returned again**. On the tip leg this hazard is pre-existing and survivable; on the shift leg it is fatal, for three reasons the first draft never stated: `shifts` is the only read surface on that leg (6.2), the writer is a **third party** so step 9's `fetchShifts(ids: writtenIDs ∪ pendingShiftDeletions)` never covers it, and `shiftCacheRequiresBaseline` (7.4) compares **ID sets** only, so a present-but-stale shift never forces a baseline. The PR 2 build then shows the pre-fold number indefinitely.

So the shift delta RPC returns `statement_timestamp()` alongside each page as `serverNow`, and the client advances to

```swift
min(max(updated_at) among pulled rows, serverNow - Self.shiftCursorSafetyWindow)
```

with `shiftCursorSafetyWindow = 300` seconds. Rows inside the window are re-pulled next pass, which is free: `reconcileShifts` is idempotent and the volume is one account's recent shifts. Do not copy this back onto the tip cursor in PR 2. Test, two sessions: `a_shift_folded_by_a_long_transaction_is_still_delivered_after_the_cursor_advanced`.

**When the shift leg is not ready it is skipped WHOLE**: no pull, no push, no verification, no shift checkpoint field written. **Where it sits, stated to match 7.5's numbered order rather than contradicting it:** after step 5 (`upsertSettings`, `:327`) and before the paycheck and settings **pull** (`:346-393`), the checkpoint at `:479` and `cachedReport` (`:505`). The first draft said "before the paycheck upsert", which a worker following literally would place ahead of `:322` and thereby reintroduce exactly the `paycheckMismatch` (`verifyServerContainsChangedRows`, `:554-556`, fed by the confirmation read at `:375-378`) and the settings clobber (`force:` at `:447-448`) that 7.5 spends a paragraph excluding.

**And the cost of a throw there, stated correctly.** In the first-sign-in `migrate` path it is a full-screen `.failed` (`PaydayCloudGate.swift:331-341`). In `.ready` it is **not** an outage on every launch: `PaydayCloudGate.synchronize` catches at `:378-387` and only backs off. The real cost there is that the checkpoint at `PaydaySyncService.swift:479` is never written, so the account silently re-baselines and re-pushes every pass forever with nothing on screen — worse to diagnose, not worse to survive. Keep the copy "Some shifts didn't sync. Your local copy is unchanged." Tests `serverDroppingAnAcknowledgedShiftStillThrows`, `aDeltaPassThatReturnsNoRowsDoesNotThrow`, `halfMigratedStoreStillSyncsPaychecksAndSettings`, `aThrowingShiftLegStillWritesTheTipAndPaycheckAndSettingsHalfOfTheCheckpoint`, and the recorded-call-order test for the exact step sequence.

### 7.8 No `client_updated_at` gate; `deleted_at` one-way in time

`20260904134500:1-3` deliberately removed that gate ("Device clocks are advisory metadata, never the authority for accepting a write"), and reintroducing it recreates the slow-clock lockout where a backward-clocked device can never update its own shift again. So `upsert_shifts` writes `client_updated_at = least(<incoming>, statement_timestamp())` and has **no** `where excluded.client_updated_at >= existing.client_updated_at`. Arrival order is the conflict order, and the fold never reasons about clocks.

`deleted_at` is one-way in **time**, as a per-column transition rule rather than an acceptance gate, so `restore_shifts` stays admissible:

```sql
deleted_at = case
  when excluded.deleted_at is not null then coalesce(s.deleted_at, excluded.deleted_at)
  when s.deleted_at is null then null
  when excluded.client_updated_at > s.client_updated_at then null
  else s.deleted_at end
```

Both sides are server-clamped, so it cannot be gamed forward.

### 7.9 Phase, receipt order, and the input pipe

An unfinished conversion is a **non-blocking sub-state, not a `Phase`**. The first draft made it `PaydayCloudState.Phase.awaitingAccountConversion(report)` and said "`syncIfReady` does not fire `synchronize` in that phase" — which the shipped code turns into a total account outage, because `PaydayCloudState.syncIfReady` opens with `guard case .ready = phase else { return }` (`PaydayCloudGate.swift:215`) and `queueSyncAfterLocalChange` routes through the same function (`:526-535`). The moment the phase were not `.ready`, **nothing** would sync: no tip pull, no tip push, no paycheck or settings sync, and no flush of `pendingTipDeletions`, which is the only carrier of a deletion the 1.0 build queued and never sent. That falsifies `aDeletionQueuedByTheOldBuildStillReachesTheServerAfterUpgrade`, the single test 7.6 offers as proof that deleting the drain apparatus was safe. It also contradicts 7.7's own promise that the shift leg is skipped whole while everything else runs, and `halfMigratedStoreStillSyncsPaychecksAndSettings` would have failed.

So: `phase` stays `.ready`, `PaydaySyncReport` carries `conversionPending: Int?` (the remaining group count of 5.1), steps 1-5 and 10-12 of 7.5 run normally, only steps 0 and 6-9 are skipped, and the wait is a **banner** with `[Try again]` and `[Details]`. The wait is longer here than in either predecessor, because the device waits on an upload plus a server fold. Keep `halfMigratedStoreStillSyncsPaychecksAndSettings` as the gate and add `anUnfinishedConversionStillFlushesAPendingTipDeletion`. Copy, verbatim:

> "Payday couldn't finish updating your shifts. Nothing was changed or deleted, and your shifts are exactly as they were." with `[Try again]` and `[Details]`.

> `PaydayMigrationError.conversionIncomplete`: "Payday is still updating your shifts. Everything you've logged is saved and already backed up to your account; your shifts start syncing as soon as that finishes."

That first sentence is true **only because `tip_entries` is never rewritten**, so the copy and R1 ship together.

**The receipt is the last thing written.** `PaydayMigrationService.migrate` currently upserts `migration_receipts` at `:99-102`, **before** `PaydaySyncService.reconcile` (`:104`) and before the checkpoint with `migrationVerified: true` (`:116-120`), so it claims the account holds this device's data whether or not the rest ran, and never retries. The order inverts to: upload, the server folds, pull, verify, **then** the receipt. The per-device receipt keeps its per-device meaning and is never read as an account-level fact.

**The insert-only upload leg is now THE input pipe.** With no device derivation, local-only rows have exactly one route to becoming visible money: upload them and let the trigger fold them. That promotes `importTips` (`PaydayMigrationService.swift:69`, insert-only, `on conflict (id) do nothing` at `20260904134500:80`) from safety net to load-bearing. Keep the shipped order `importTips`, `importPaychecks`, `importSettings` and its comment, and **add**: the first `shifts` pull happens after the import, in the same pass, never before. Test `aFirstSignInUploadsLegacyRowsBeforePullingShifts`.

The first-sign-in order is therefore **import, migrate, pull, reconcile by id, never push-first**, and no device may mint a shift id for a group the server has keyed. The gate for that must be a **server** fact, never a local checkpoint, because `MigrationRunner.runPending(in: modelContext)` executes at `PaydayCloudGate.swift:484`, one line before `await cloudState.restore(...)` at `:485`, so on the first new-build launch of every existing install there is **no session** and any per-device "verified" field is nil: gating on it would protect only the population that was never at risk.

`PaydaySyncState.forget` (`:120-127`) already removes whole keys; keep it that way. An account switch clears `shiftsAreAuthoritativeAt` with them and resets the reader to the legacy leg.

---

## 8. `ShiftCommands`

### 8.1 API

```swift
@MainActor
enum ShiftCommands {
    struct Draft: Equatable {           // a value, never a model reference
        var workDate: Date
        var shiftPeriod: ShiftPeriod?
        var cashCents: Int = 0
        var creditCents: Int = 0
        var tipOutCents: Int?
        var salesCents: Int?
        var hoursWorked: Double?
        var clockIn: Date?
        var clockOut: Date?
        var serverCount: Int?
        var receiptMetrics: ShiftReceiptMetrics?
        var note: String?

        var hasContent: Bool {
            cashCents > 0 || creditCents > 0 || (hoursWorked ?? 0) > 0
                || (receiptMetrics?.employeeGratuityFeesCents ?? 0) > 0
        }
    }
    struct Snapshot: Codable, Equatable { /* every ShiftRecord field, by value */ }

    @discardableResult static func create(_ draft: Draft, in context: ModelContext) throws -> ShiftRecord
    static func update(_ record: ShiftRecord, with draft: Draft, in context: ModelContext) throws
    @discardableResult static func delete(_ record: ShiftRecord, in context: ModelContext) throws -> Snapshot
    static func restore(_ snapshot: Snapshot, in context: ModelContext) throws
    @discardableResult static func duplicate(_ record: ShiftRecord, onto date: Date, in context: ModelContext) throws -> ShiftRecord
    static func addTips(cashCents: Int, creditCents: Int, tipOutCents: Int?,
                        to record: ShiftRecord?, on date: Date, in context: ModelContext) throws
}
```

`Snapshot` is by value and `Codable` because the SwiftData instance is gone from the context by the time Undo is tapped. `hasContent` reads the **receipt's** gratuity, not `separatedGratuityFeesCents`, so a gratuity-only v1 draft and the record it becomes can never disagree about emptiness.

### 8.2 Atomic save

```swift
private static func perform<T>(in context: ModelContext, _ body: () throws -> T) throws -> T {
    do { let r = try body(); try context.save(); PaydayWidgetRefresh.request(); return r }
    catch { context.rollback(); throw error }
}
```

**`SharedModelContainer` must set `shared.mainContext.autosaveEnabled = false`, and it must land in S9, not S1.** It sets nothing on `mainContext` today (verified: zero matches for `autosaveEnabled` across `Payday/`, `PaydayWidget/`, `PaydayTests/` and `Packages/`), so a run-loop autosave between the mutation and a throw persists a partial change that `rollback()` cannot undo, and the atomicity claim would be false as written.

**But landing the flag before the write paths are replaced loses money.** Every SwiftUI write path in the tree depends on autosave today and several never call `save()` at all: `PaycheckEntrySheet.save` (`Payday/Views/Periods/PaycheckEntrySheet.swift:659-701`, `modelContext.insert(record)` at `:691`) and `.delete` (`:703-709`); `BackfillSheet.performSave` (`:170-171`); `LogTipSheet.saveNew`, `commitLiveEdit`, `pruneZeroedRows` and `delete`; plus every live field edit, which persists only through `didSet` plus autosave. The first draft landed `autosaveEnabled = false` in **S1**, declared "parallel with S2", so it merged to `production` before S9 replaced those paths: in that window a logged shift or an edit is lost on relaunch, and any build cut from it (TestFlight, a second device) loses money. Worse and permanent, `PaycheckEntrySheet` appeared in **no** slice's file list, so after the full PR paycheck entry and deletion would have silently stopped persisting. Both also stop firing `ModelContext.didSave`, which is what `PaydayCloudGate.swift:504` uses to queue a sync, so nothing would sync either.

So the flag moves into S9's commit, and S9's file list gains `Payday/Views/Periods/PaycheckEntrySheet.swift` and `Payday/Views/Shared/BackfillSheet.swift` with explicit `try context.save()` and a `rollback()` on throw, through the same `perform` helper. Gate: open the App Group store, write a paycheck through the sheet's save path, reopen the container, assert the row is present — plus the same for a backfilled shift and a live field edit. The `ShiftCommands` test asserts the **observable** invariant (no half-written record after a forced throw), not the mechanism.

Failure copy, verbatim: "That shift is no longer here." / "Add tips, hours, or gratuity to save this shift." / "Payday couldn't save that. Nothing was changed."

### 8.3 The call-site map

The two-row reconciliation exists only because a shift was two rows. With one record there is nothing to reconcile, no non-anchor row to delete, no zeroed sibling to prune, no scanned-zero identity to preserve. About 150 lines of `LogTipSheet` go away: the largest client simplification.

| site | today | after |
|---|---|---|
| `LogTipSheet.saveNew` (`:1400`) | `ShiftWriter.insertShift` (`:1442`) | `create(draft)`, reveal still **computed before** the write (`:1416-1439`), assigned after `create` returns |
| `liveSaveEdit` / `commitLiveEdit` (`:1487`, `:1499`) | row reconciliation, `recordTipDeletions` (`:1511`) | `update(record, with: draft)`, keeping the 400 ms debounce and the flush on dismissal |
| `pruneZeroedRows` (`:1551`, guards `rows.count > 1`) | prunes a zeroed sibling | **deleted** |
| `isDeferringReceiptScanRowDeletion` (`:166`, `:552`, `:1151`, `:1162`, `:1197`, `:1238`, `:1334`, `:1374`) | defers a row delete across a scan | **deleted** |
| `LogTipSheet.delete` (`:1586`) | `recordTipDeletions(rows.map(\.id))` (`:1589`) | `delete(record)`; the toast carries the returned `Snapshot` |
| `LogTipSheet.canSave` (`:268-270`) | `cashCents > 0 \|\| creditCents > 0` | `draft.hasContent` |
| `TipEntrySheetTarget.edit(TipEntry)` | model reference | `.edit(shiftID: UUID)`, so a record deleted underneath the sheet dismisses cleanly instead of dangling |
| `BackfillSheet.performSave` (`:171`) | one `insertShift` per row | one `create` per row |
| `ShiftContextMenu`'s inline duplicate | inline row copy | `duplicate(record, onto:)` |
| `UndoDeleteToastState` (`UndoDeleteToast.swift:60-92`) | `[DeletedTipSnapshot]` | one `ShiftCommands.Snapshot`; `DeletedTipSnapshot` (`:8-51`) **deleted**. The toast keeps its public shape (`snapshot != nil`, "Shift deleted", "Undo", 4 seconds, haptics, the `UIAccessibility` announcement), so its three call sites change only in argument type |
| accepted receipt scan | writes metrics onto a row | `update` with merged metrics; `ShiftReceiptMetrics.merging` unchanged |

**The wage-only regression is real and is fixed here.** `newEntries` is appended only when `cashCents > 0` (`ShiftWriter.swift:41`) or `creditCents > 0` (`:46`), and `ShiftDetails.write(... into: newEntries)` is then called with an **empty array** (`:53`), whose body returns immediately at `guard let primary = entries.first(...)` (`ShiftDetails.swift:42`). So an hours-only save silently discards hours, tip-out, sales, punches and receipt metrics. Nothing about the server converting changes this.

Slice split, because a test naming `ShiftWriter.insertShift` cannot outlive it: **S1** lands `ShiftWriterTests.wageOnlyShiftIsLostToday` as a characterization test whose output is pasted into the PR body; **S5** deletes it with `ShiftWriter.swift` and keeps only `ShiftCommandsTests.wageOnlyShiftSaves`. The S5 gate references the recorded characterization, never a test that must survive its own subject.

### 8.4 The one-direction fence

```swift
static func recordLegacyEntryDeletions(_ ids: some Sequence<UUID>, at date: Date = .now)
static func cancelLegacyEntryDeletions(_ ids: some Sequence<UUID>)

@available(*, unavailable,
    message: "TipEntry is read-only in this build. Delete the shift through ShiftCommands. The pending-deletion queue written by 1.0 is still flushed, through its own private storage.")
static func recordTipDeletions(_ ids: some Sequence<UUID>, at date: Date = .now) {}

@available(*, unavailable, message: /* same */)
static func cancelTipDeletions(_ ids: some Sequence<UUID>) {}
```

Both annotated, not just one. Keep the sentence: **this is the single most dangerous line in the PR**, because if a projection ever enqueued a server tombstone it would soft-delete real rows. Land it as its **own commit after** both the commands slice and the sync slice have merged, or the tree is red either way round.

**Which means the fence's gate cannot be a count of compile errors.** Five call sites exist in the tree and nowhere else, all verified: `LogTipSheet.swift:1511`, `:1580`, `:1589`, `UndoDeleteToast.swift:70`, and `UndoDeleteToast.swift:85` (`cancelTipDeletions`, a different symbol). But S9 already deletes `pruneZeroedRows` (`:1551-1584`, which contains `:1580`), replaces `commitLiveEdit`'s row reconciliation (`:1511`) and `LogTipSheet.delete` (`:1589`), and edits `UndoDeleteToast.swift` (`:70`, `:85`). By the time S10 runs there is nothing left to break. So the **five call sites are S9's acceptance list** — the set S9 must have converted — and **S10's gate is `design-lint.sh`**: zero references to `recordTipDeletions` or `cancelTipDeletions` anywhere outside `PaydaySyncState.swift`. The `@available(*, unavailable)` annotations stay as the permanent guard against reintroduction, which is their real job.

`ShiftCommands.delete` is the one narrow legacy write: inside the **same** `perform` block it records the pending shift deletion, writes the durable `ShiftTombstone`, **and** calls `recordLegacyEntryDeletions(record.legacyEntryIDs)` so the source rows are tombstoned through the shipped `soft_delete_tip_entries`. No new RPC, no floor, no drain. Tombstoning the sources fires the trigger, which recomputes the group, finds no live rows, and reaches arm 2b, which tombstones the shift idempotently; and because the delete is a native write the shift is closed, so nothing can refold it.

**Three things make that cascade actually work, and the first draft had none of them.**

1. **The legacy deletion queue needs its OWN storage key.** `recordLegacyEntryDeletions` writes `PendingDeletions.legacyEntries`, not `.tipEntries`. `synchronize` cancels any pending tip deletion whose local `TipEntry` row still exists — `restoredTipIDs = currentTipIDs.intersection(pendingTipDeletions.keys)` at `PaydaySyncService.swift:311`, removed at `:313`, **persisted as cancelled** by `clearTipDeletions` at `:315`, all before `softDeleteTips` runs at `:323` — and `currentTipIDs` (`:304`) is every row in the store, unfiltered, because there is no local soft-delete flag. That is correct today only because `LogTipSheet.delete` (`:1590-1592`) and `UndoDeleteToastState.delete` (`UndoDeleteToast.swift:71`) hard-delete the local rows in the same breath. Under 8.4 `ShiftCommands.delete` deletes only the `ShiftRecord` and 7.6 deliberately keeps the full local legacy mirror, so every id queued into `.tipEntries` is still in `currentTipIDs` on the next pass and the queue would be emptied **without one `soft_delete_tip_entries` call ever being issued**: the shift tombstone reaches the server, the legacy rows stay live forever, 12.3 row 1 is false, and on any reinstall or `forget` those live ids are named by no live shift so 6.3 predicate 2 can never be satisfied. The new key is flushed in step 3 alongside `.tipEntries` and the restore-cancel arm does not touch it. (Fix the `@available` message too: the first draft said the 1.0 queue is flushed "through its own private storage" while pointing the new tombstones at the same `soft_delete_tip_entries` — they were the same storage.)
2. **The flush must read the RPC's return set.** `public.soft_delete_tip_entries` updates only `where ... and p_deleted_at >= client_updated_at` (`20260831165043:167`) and returns the ids it actually wrote, and `p_deleted_at` is the device's local clock while `client_updated_at` was server-clamped by `upsert_tip_entries`. A new-build device whose clock is behind the server silently tombstones **nothing**, and the shipped client never checks: `clearTipDeletions(pendingTipDeletions.keys, for: userID)` clears the whole queue unconditionally (`PaydaySyncService.swift:457`). So the flush compares the returned id set against the requested set, keeps the unwritten ids queued on the same 1/2/4/8-pass backoff as `shiftWriteAttempts` (7.7), and surfaces after five attempts. Do **not** clamp `p_deleted_at` server-side: `least(p_deleted_at, statement_timestamp())` would only lower the value and make the guard fail *more often* for the device that is behind. The skew is bounded (`client_updated_at` is itself `least(device clock, server clock)`), so retrying converges.
3. **Undo after the flush must restore the legacy sources, and needs no new RPC.** 7.6's `upsert_tip_entries` writes `deleted_at = excluded.deleted_at` with no staleness guard (`20260904134500:137-154`) and `RemoteTipEntry.init(entry:userID:)` hardcodes `self.deletedAt = nil` (`PaydayRemoteModels.swift:106`), so **re-pushing the rows un-deletes them**. `ShiftCommands.restore` therefore calls `restoreLegacySources(record.legacyEntryIDs)`, which clears the queued-but-unflushed ids and, for ids already flushed, touches `modifiedAt` on the local `TipEntry` rows so they enter `changedIDs` and the ordinary push leg re-sends them. That is a metadata write, not a money write, so R1 holds. The refold that follows lands on a shift that `restore_shifts` has closed (`native_modified_at` set), so arm 2b cannot re-empty it. The first draft deleted `restoreLegacyEntries` and `pendingLegacyRestores` outright (14.2) while 8.5 admits the flushed case is the **common** one (2 s debounce inside a 4 s window), so a 1.0 build would have permanently lost a night the user un-deleted. Test `undoAfterTheFlushRestoresTheLegacySources`.

**No cascade beyond that.** `soft_delete_shifts` alone does not touch `tip_entries`; only `ShiftCommands.delete` queues the legacy tombstones, on the device, as one user action. Test: a native shift delete produces exactly one `soft_delete_tip_entries` call carrying every `legacyEntryID`, run over a store where those rows are still present.

### 8.5 Undo is an exact inverse

Four jointly necessary pieces, each of which arrived inside an otherwise-deleted cluster, so the risk is a worker pruning them by association:

1. **A durable local `ShiftTombstone`** written by `delete`, cleared only by `restore`, never pruned by time or by a sync.
2. **`restore_shifts` as step 0 of `synchronize`**, from the durable `pendingShiftRestores` queue, cleared only after a confirmation read shows `deletedAt == nil`.
3. **In `reconcileShifts`, at the top of the tombstone branch:** `if restoringIDs.contains(row.id) { activeIDs.insert(row.id); continue } // Deleting here would make Undo a no-op.`
4. **`restoreLegacySources(record.legacyEntryIDs)`** (8.4 item 3), which clears queued-but-unflushed legacy deletions and re-pushes already-flushed ones so the 1.0 build gets its night back. Without it, Undo restores the shift on the new build while the old build has permanently lost it, and 12.3 row 1 destroys it on both sides.

Why (3) is not optional: `reconcileTips` is always called with `localVersionsAtStart` (`:424-433`), so the `entry.modifiedAt > modifiedAt` arm (`:599-602`) is unreachable from a sync pass, and the live guard (`:591-598`) only asks whether the row changed **during** this pass, so a restore made **before** the pass falls through to the tombstone branch (`:604-607`) and the record is deleted. And the flushed case is the **common** case: the sync debounce is `Task.sleep(for: .seconds(2))` (`PaydayCloudGate.swift:532`) inside a **4-second** undo window (`UndoDeleteToast.swift:76`).

`restore(_:)` assigns `modifiedAt = .now` **last**, after every other field, because that is what puts the id into `changedIDs`.

Tests `undoBeforeTheNextPassSurvivesAPulledTombstone`, `aRealTombstoneForAnIDNotBeingRestoredStillDeletes` (so the exemption is not a hole), `undoAfterALegacyRefoldConvergesOnOneShift`, `undoAfterTheFlushRestoresTheLegacySources`. **Gate:** `delete` and `undo` are byte-identical inverses for both shapes (inside the debounce, and after the tombstone flushed), asserted field by field with `modifiedAt` the only permitted difference.

### 8.6 The intent

`LogTipsIntent.targetShiftID` (`:90-100`) becomes "today's most recent record missing this kind", a pure function over `[(id: UUID, cashTipsCents: Int, creditTipsCents: Int, recordedAt: Date?)]`, with the predicate strengthened from "that kind is already present" (`:98`) to "that kind is **non-zero**". It also loses a caveat that disappears under records: legacy rows with a nil `shiftID` are filtered out today (`:91`) and cannot be completed into. `perform` becomes one `addTips` call and one save, collapsing the `ShiftDetails.resolve` / `.write` dance at `:135-137`. Both dialog strings (`:151-152`) and the `PaydayAuthorizationState.allowsFinancialAccess` refusal (`:107-109`) are kept; its five unit tests are rewritten, not deleted.

**The gate of 8.7 lives in `ShiftCommands`, not in the view layer, because the intent and the widget have no `PaydayCloudState`.** `LogTipsIntent.perform` runs against `SharedModelContainer.shared.mainContext` (`LogTipsIntent.swift:121`) in its own process with no view to show a banner on, and the widget's Log deep link and `OpenLogSheetIntent` are the same. So the authority fact is read through `PaydaySyncState.shiftsAreAuthoritative(for:)` (6.2) and **`ShiftCommands` itself refuses**, returning a dialog rather than relying on a caller to check: `IntentDialog("Payday is still setting up your shifts. Open the app once and try again.")`. Test `aSiriLogIsRefusedBeforeShiftsAreAuthoritativeAndLeavesNoRecord`. Note this refusal now applies only to `update` and `delete` of an unconfirmed record (8.7); `create` and `addTips` onto a **new** record are allowed on the legacy leg, so the ordinary Siri log keeps working.

### 8.7 The write gate, narrowed

The hazard the first draft was defending against is real: a `ShiftRecord` written into a store nothing reads means every screen shows nothing, the user logs it again, and both copies later reach the server as two shifts with different ids. But refusing **every** mutation on the legacy leg was the wrong answer, and 6.2 removes the need for it: the legacy leg now additively reads native records whose `legacyEntryIDs` is empty, so a shift created there is visible immediately and by construction cannot double-count.

| while `shiftsAreAuthoritativeAt == nil` | |
|---|---|
| `create`, `duplicate`, `addTips` onto a **new** record | **allowed.** The record is read back on the additive leg (6.2), carries one id from birth, and pushes exactly once. |
| `update`, `delete`, `addTips` onto an **existing** record whose `legacyEntryIDs` is **empty** | **allowed.** The device authored it; nothing else holds it. |
| `update`, `delete` of a record with **non-empty** `legacyEntryIDs` | **refused**, behind the banner plus `[Try again]`. That record is a fold result the device has not yet confirmed, and editing it before the pull could clobber a refold. |

Gate tests `aShiftLoggedOnTheLegacyLegIsVisibleImmediatelyAndReachesTheServerExactlyOnce`, `editingAnUnconfirmedFoldedShiftIsRefusedWithTheBanner`, and `aPermanentlyUnfoldableGroupDoesNotMakeTheAppReadOnly` (the S13 case that the first draft's version failed).

---

## 9. The agent API after the change

### 9.1 Which endpoints write which table

| verb | table written | change in PR 2 |
|---|---|---|
| `create_shift` (`index.ts:2132`, `createShift` `:1097-1160`) | `tip_entries` (batch insert `:1144`) | none beyond 9.3. The trigger folds it in the same transaction, so `create_shift` then `get_shift` is consistent. |
| `create_tip_entry` (`:2134`), `update_tip_entry` (`:2136`), `delete_tip_entry` (`:2138`), `restore_tip_entry` (`:2148`) | `tip_entries` | none |
| `update_shift`, `delete_shift`, `restore_shift` | `public.shifts` | **not in PR 2.** PR 6. |

The cutover deleted the four legacy write verbs because gating them was impossible through the service-role client. That was a **lockout** argument. With on-arrival conversion a write through them is as correct as an old build's write, so keeping them (with their three MCP entries at `:2398`, `:2413`, `:2446` and their router lines `:2134-2152`) is right, and deleting `restore_tip_entry` would **hide** the un-delete problem that arm 3 fixes.

**Residual hazard, and 4.3 alone does not cover it.** `update_tip_entry` accepts `shift_id`, so an agent can move a legacy row between shifts and cause **two** groups to refold in one write, one losing money and one gaining it; `create_tip_entry` can plant a legacy row on a day that already holds a native shift. 4.3's old-keys-union-new-keys is necessary but not sufficient, because if the **losing** group is a closed shift the first draft's arm 2 skipped it entirely and the night was displayed twice, on two dates, with 5.5's detector unable to see it (it groups by `work_date`). What covers it is 4.4 **arm 2a**, which releases provenance unconditionally, plus 4.3, plus 5.5. Tests `anAgentMovingARowBetweenShiftsRefoldsBothGroups`, `anAgentMovingARowAwayFromAClosedShiftClearsItsClaim`, `aClientToleratesAShiftLosingMoneyToASiblingBetweenTwoPasses`.

### 9.2 Reads cut over, no read-through fallback

`list_shifts`, `get_shift` and `payday_agent_summary` read `public.shifts` once the account's conversion is verified. **No conditional fallback** to a legacy derivation: it would be untestable dead code returning pre-normalization numbers.

`get_shift` gains a step-2 lookup, which is both a fix and a persisted old-id to new-id map: step 1 by `(user_id, id)`, step 2 `where legacy_entry_ids @> array[id]::uuid[]`. It is needed because `getShift` filters `.eq("shift_id", id)` on `tip_entries` today (`:1544-1547`) while `groupShifts` keys a nil-`shift_id` row on its own `row.id` (`:1342-1345`), and the fold keys that group on `payday_legacy_shift_id(work_date)`.

`CHANGE_TABLES` becomes `["shifts", "tip_entries", "paycheck_records", "user_settings"]`. `tip_entries` **stays**, because it still exists and is still a legitimate change table, so `changeCursor`'s `invalid_cursor` 400 for an unknown table (`:1826`) never fires for a pre-existing cursor and the cutover's deliberate hard-error signal and its "discard your cursors" docs instruction are both unnecessary. The one-time ordering change at a page boundary remains, covered by the step-2 lookup.

### 9.3 The replay branch

`createShift`'s 23505 recovery (`:1146-1152`) keeps `.eq("shift_id", shiftID)`, which is **correct** because it still writes `tip_entries`. Two narrow corrections: `.eq("agent_idempotency_key", ctx.idempotencyMarker ?? "")` becomes `ctx.idempotencyMarker!` with an assertion at the top of the handler, because `idempotent()` rejects a keyless mutation at `:2063-2069` so the `?? ""` branch only hides a bug; and the test must force the state that actually reaches this arm, since an ordinary retry replays at `reserveIdempotency` (`:2021-2026`) and only `abandonIdempotency` (`:2049-2055`) or an `IDEMPOTENCY_STALE_MS` release (`:1993-2014`) gets here. Then assert 200 twice, the same `shift_id`, and exactly `rows.length` rows carrying that marker.

### 9.4 The signed corrections table

`sql_corrections.ts` exports `{ id, field, before, after, sign, fixture }`. Every disagreement between the old readers and the new one is a named signed fixtured correction rather than a surprise.

| id | field | before | after | fixture |
|---|---|---|---|---|
| D1 | `work_date` | `max` over the group (`index.ts:1352-1358`) | `min` (`ShiftDays.swift:56`, `StatsEngine.swift:226`) | L1 |
| D2a-d | cursor and ordering details | one-time deploy facts | | L2 |
| D3 | metrics owner per civil day | per-row key | `metrics_rank` | L2 |
| D4 | null is not zero | `coalesce(...,0)` as `20260904125000:77-95` does | resolved-by-rank `Int?` | N3 |
| D5 | `tip_entry_count` | derived count | retired to null, no `derived_count` | P6 |
| D6 | shift-level scalars and the metrics owner on a group with two rows of one kind | `first { .credit } ?? first { .cash }` per field, array-order dependent (`ShiftDetails.swift`, `TipBreakdown.swift`, `index.ts:1342-1370`) | `detail_rank` / `metrics_rank`, first non-null across all rows | P7 |
| C1 | cursor format unchanged, ordering changed | | | P6 |

**Struck, and it must stay struck:** the per-row tip-out bug attributed to `groupShifts` **does not exist**. `index.ts:1399` resolves the tip-out once via `detail("tip_out_cents")` and `:1400-1401` subtracts that single value. Test `tipOutIsResolvedOnceByBothImplementations` asserts `groupShifts(N1)[0].tip_out_cents === 1000`. A worker "fixing" that line would assert a bug into existence.

`tipFacts` and `groupShifts` stay **exported and unreferenced by any handler** for exactly one PR so the differential is checkable at all; `differentialAgainstGroupShifts` asserts both directions. Fixtures L1 and L2 make D1, D2 and D3 observable, and **P7 makes D6 observable**: `groupShifts` sorts by id and then applies the same first-credit rule, so it deterministically returns the 10000 shape on that group and the differential must report it as a signed correction rather than a surprise.

---

## 10. Keeping the 13 `@Query` views and the 609 tests compiling

### 10.1 The projection

Reinstate the base design's **one-row-per-kind** projection, not the cutover's `[ShiftRow]` overloads. This is the one harvest reversal and it removes a whole apparatus.

```swift
protocol LegacyShiftRow {
    // the 16 members TipEntry already satisfies as written
    var id: UUID { get } ; var date: Date { get } ; var amountCents: Int { get }
    var kind: TipKind { get } ; var note: String? { get } ; var recordedAt: Date? { get }
    var shiftID: UUID? { get } ; var hoursWorked: Double? { get }
    var tipOutCents: Int? { get } ; var salesCents: Int? { get }
    var shiftPeriod: ShiftPeriod? { get } ; var clockIn: Date? { get }
    var clockOut: Date? { get } ; var serverCount: Int? { get }
    var receiptMetrics: ShiftReceiptMetrics? { get } ; var isDouble: Bool { get }
    var netCents: Int { get }        // declared: CalendarView sums it row by row
}
extension LegacyShiftRow { var netCents: Int { /* same body as TipEntry.netCents */ } }
extension TipEntry: LegacyShiftRow {}   // source-compatible, no change to TipEntry
```

`ProjectedShiftRow` is a **struct**, deliberately: it cannot be inserted into a `ModelContext`, so double-counting by accidental persistence is a compile error rather than a review item. Its ids derive from the record id, namespaced and stable across rebuilds, so identity-keyed views do not thrash.

Signature-only edits, bodies untouched: `ShiftDetails.resolve<Row: LegacyShiftRow>`, `TipBreakdown.total<Row: LegacyShiftRow>`, `extension TipRecord { init(row: some LegacyShiftRow); init(entry: TipEntry) { self.init(row: entry) } }` (which keeps the `StatsEngine` tests verbatim), plus a generic parameter on `CSVExporter`, `PeriodIncome`, `WageEstimate`, `PredictedPaycheck`, `SmartNudgeScheduler`, `PaydayPushScheduler`.

**Why the protocol beats the overloads.** The cutover replaced it with seven `[ShiftRow]` overloads plus a one-to-two expansion, solely because it had redefined `ShiftRow` as one row per **shift** carrying both cash and credit. One row per **kind** dissolves that objection: `TipRecord.init(row:)` is a faithful 1:1 bridge again, `StatsEngine.shiftFacts`' kind filter (`:228`) and its credit-first resolution (`:222-239`) keep working, and "609 tests compile unchanged" is satisfied **by construction** rather than by a parallel surface.

**The projection rule, stated completely, because the first draft stated it twice and incompatibly.** It said both "the projection emits a credit row and a cash row" and "a wage-only or gratuity-only shift projects as exactly ONE credit row with `amountCents = 0`" — the second sentence forces a per-kind zero-suppression rule that the first forbids. Under suppression a **cash-only** shift (the commonest shape there is for a server who tips the bar out in cash: C=5000, R=0, tip-out 1000) would project as one cash row with every shift-level field nil, so `TipBreakdown.total` resolves `details.tipOutCents ?? 0` = 0 (`TipBreakdown.swift:66`) and `TipEntry.netCents` (`TipEntry.swift:162-165`) reports 5000 where the shift is 4000, with gratuity and hours vanishing the same way. Under no suppression every cash-only shift gains a phantom $0 Credit row in `DayDetailSheet` and `HistoryView`.

The rule is exactly `ShiftWriter` plus `ShiftDetails` semantics, which is what makes it zero-delta against the before side:

1. **One row per kind whose `amountCents` is non-zero.** If both are zero, emit exactly one row, kind `credit`, `amountCents = 0`. (`ShiftWriter.swift:41` and `:46` append only for a non-zero amount.)
2. **Every shift-level field** — `tipOutCents`, `salesCents`, `hoursWorked`, `clockIn`, `clockOut`, `serverCount`, `receiptMetrics`, `shiftPeriod` — goes on the **credit** row when one is emitted, otherwise on the cash row, otherwise on the single zero row. That mirrors `ShiftDetails.resolve`'s **detail rank** (credit first, then lowest id, first non-null across all rows) and `ShiftDetails.write`'s detail rank 1 — not the pre-S3 `credit ?? cash` / `first(where: .credit) ?? first`, which correction D6 replaced.
3. **`note` and `recordedAt` go on EVERY emitted row**, because `ShiftWriter` passes the note to both `TipEntry` initializers (`ShiftWriter.swift:38-48`). This is what keeps `CSVExporter`'s note field (`CSVExporter.swift:37`, `items.compactMap(\.note).joined(separator: "; ")`) byte-identical: a two-kind shift gives "N; N" on both sides, a one-kind shift gives "N" on both sides. Put the note on one row only and the CSV string diverges, with `csv` compared as a whole string in 11.2 and no entry for it in 11.3's delta table.

**The arithmetic proof, which is also the `CalendarView` fix.** For cash `C`, credit `R`, v2 gratuity `G`, tip-out `T`, both non-zero: `TipBreakdown.total` gives `C + R + G - T`; the row-by-row `netCents` path (`CalendarView.swift:35`, `:63`) gives `(R + G - T) + C`. Equal, and no longer double-subtracting the tip-out, which is what fixture N1 declares. New fixture **N6**: a cash-only shift carrying a tip-out, a gratuity and a note, asserting `netCents`, `dayDetailTotals` and the CSV line all match the before side, listed in 11.3 as a **zero-delta** case.

### 10.2 Test disposition

**Nothing is deleted in PR 2**; deletion is PR 8's job and its own gate (and see 1.6). The table is what keeps 609 tests honest rather than quietly narrowed.

| disposition | files |
|---|---|
| **Rewritten** | `ShiftWriterTests` to `ShiftCommandsTests` (the S1/S5 split, 8.3); `LogTipsIntentTests` (5 tests, new predicate) |
| **Extended** | `PaydaySyncStateTests` (the `PendingDeletions` decoder, `mutate`, both cache-baseline functions, the `Snapshot` round trip); `PaydayRemoteRepositoryTests` (the recorded shift call order); `MigrationRunnerTests` (the determinism fix) |
| **Kept as-is, seeding `TipEntry` literals** | `CalendarDayTotalTests`, `TipBreakdownTests`, `ShiftDetailsTests`, `ShiftDaysTests`, `StatsEngineTests`, `CSVExporterTests`, `DashboardLogicTests`, `InsightsNumbersGridTests`, `PeriodIncomeTests`, `PredictedPaycheckTests`, `PaycheckAuditTests`, `CashWeekdayFactsTests` (satisfiable because 10.1 changes signatures only) |
| **New** | `ShiftCommandsTests`, `ShiftProjectionTests`, `ShiftSyncReconcileTests`, `LegacyShiftIdentityTests`, `BridgeParityTests` |
| **Kept and re-baselined** | `RenderFactsPerformanceTests` |

Two CI facts, both already paid for: `RenderFactsPerformanceTests` needs the `budgetScale` fix (`CI == nil ? 1.0 : 4.0` at its five budget lines) or it blocks **every** PR, because the perf budgets flake on shared runners; and `xcodebuild test | grep Executed` reports only the 2 XCTest files (7 `func test` methods), so the 609 swift-testing cases are counted from the `Test run with N tests in M suites` line. A local run has reported `TEST SUCCEEDED` while CI showed 609 failures: trust the CI line.

### 10.3 The five CI jobs

Verified in `.github/workflows/ci.yml`: **A** `PaydayCore (swift test)` on macos; **B** `Payday app + widget (xcodebuild test)` on macos, which must build both targets; **C** `payday-api (deno test)` on ubuntu; **D** `Design lint` on ubuntu; **E** `Supabase migrations (db reset)` on ubuntu with `supabase start` plus `supabase db reset --local`. Job E is where every SQL assertion lives and is what makes section 11 buildable.

---

## 11. The bridge parity test

### 11.1 What it proves

The only artifact that proves a person's screens did not change. With one deriver nothing on the device reproduces the fold, so the gate is no longer "the Swift port equals the SQL". It is:

> The SQL fold, applied to a fixture's legacy rows, produces shift rows whose screens equal the screens the shipped readers already produce from those same legacy rows, except for a declared list of corrections.

### 11.2 How the "before" side stays trustworthy

`ScreenNumbers` is `Equatable + CustomStringConvertible` (a field-by-field diff naming the screen and the cent) over `calendarDailyTotals`, `calendarMonthTotal`, `dayDetailTotals`, `shiftRowCents`, `dashboardHeroCents`, `periodRowCents`, `periodDetailCents`, `chartPointCents`, `insightsGrid`, `daysWorkedCount`, `widgetEntryCents`, `periodTotalIntentCents`, `unlockProgress`, `nudgeFireDates`, `pushFireDates`, and `csv` compared as a **whole string**.

`numbers(from:)` has **one** implementation, calling the real readers (`CalendarFacts.init`, `DashboardFacts.init`, `PeriodDetailFacts.init`, `StatsEngine`, `CSVExporter.export`, the widget's `buildEntry`, `PeriodTotalIntent`, `UnlockProgress`, `SmartNudgeScheduler`, `PaydayPushScheduler`) and **never** a re-derivation.

The "after" side comes from the SQL without porting the grouping into the test target:

- Each shared fixture JSON carries `legacy` (raw `tip_entries` rows), `expectedShifts` (the shift rows the fold must produce, as literals), and `expectedScreens` where a delta is declared.
- **Job E** asserts `derive_shifts(fixture.legacy) == fixture.expectedShifts` on real Postgres, for every fixture.
- **Job B** loads the same JSON, builds `ShiftRecord`s from `expectedShifts`, and asserts `numbers(from: shiftRecords) == numbers(from: legacyRows) ± ExpectedDelta`.

Neither leg re-derives, neither trusts the other's code, and no cross-job artifact plumbing is needed. A change to the fold fails job E; a change to a reader fails job B.

### 11.3 `assertParity` is bidirectionally strict

An undeclared difference fails, a wrong magnitude fails, and a declared delta that has **vanished** fails. The table may declare **only deltas the fixtures can produce**: 5 entries, and deliberately **no** wage-only entry, because `seedTipEntries` inserts raw rows and bypasses `ShiftWriter`, so the hours-only row exists on the **before** side too and the 8.3 regression is invisible to this suite (the characterization test covers it instead). Three fixtures are **zero-delta** and each one exists to catch a specific fix in this document: P6 proves 1415c of wages, one `shiftRowCents` key, one `dailyTotals` key and `daysWorkedCount == 1`; **N5** (3.2) is the only fixture where the metrics owner and the object-payload holder could diverge, and it must produce cash 800 / credit 2000 / gratuity 4200 / non-wage 7000 on all three sides; **N6** (10.1) is the cash-only shift with a tip-out and a note, and it is the only fixture in which the `csv` note field and the one-row-per-kind rule are both observable.

### 11.4 The N4 three-sided gate

`"expectedN4": { "cash": 5000, "credit": 0, "gratuity": 4200, "nonWage": 8200 }` as a **literal in the fixture JSON**, on a fixture whose credit row is deliberately **short** of the folded gratuity, asserted in `PaydayCoreTests`, `PaydayTests` and the Deno twin, with the values taken from `TipBreakdown.total` so the "before" number is the gate rather than a restatement of the new rule. With claims and divergences gone, neither conservation check can see this class of bug: the SQL check compares SQL to a SQL recomputation and the Swift one compares Swift to Swift.

### 11.5 Teeth

Three mutation cases, each running the suite in-process and asserting it **fails**: swap the resolved-by-rank tip-out for a `sum`; swap the v1-to-v2 rule for the whole-gratuity reassignment; change `min(work_date)` to `max`.

Plus the wire cases: `apiShiftArrivesOnce` (build a `RemoteShift` exactly as the server emits it, feed it through `reconcileShifts` **twice**, expect one record with identical cents both times); the v1-rejection, the `1234.6`-rounds-to-1235 case, the three out-of-range clamp cases and the RLS cases in job E; `every_rpc_is_reachable_as_authenticated` asserting 200 or a documented `PTnnn` and **never 42501** for `upsert_shifts`, `soft_delete_shifts`, `restore_shifts`, `migrate_tip_entries_to_shifts`, `payday_unmigrated_tip_row_count` (PostgREST maps `PTnnn` to HTTP `nnn`, retained as knowledge even though no version floor uses it); and a `service_role` write of a `tip_entries` row folding into **that row's owner**, not the caller.

---

## 12. Rollback

### 12.1 Is it simply "stop reading shifts"?

Almost, and that is the point of this shape: `shifts` is derived, `tip_entries` is intact and still written by everybody, and there is no lockout to undo. But three things are not automatic, and skipping any one leaves an account worse off than before.

1. **The trigger must be disabled in the same transaction as the tombstoning**, or the next legacy write from any 1.0 device re-converts its group and partially un-rolls the rollback, leaving an account half rolled back with no record of which half. Neither predecessor had a live re-converter racing rollback.
2. **The client must be walked back deliberately.** A device that cannot be downgraded reads `shifts`, so tombstoning the artifacts without telling it leaves it rendering an **empty history** while intact `TipEntry` rows sit unreadable on disk, which is the outcome the reader promise forbids.
3. **A natively authored shift has no legacy representation**, so rollback **hides** it rather than destroying it (12.3).

### 12.2 The artifact, the inverse, and the client half

`public.rollback_shift_migration(p_user_id uuid)` lives **in the same migration file as the forward function** so a reviewer sees both halves at once.

**It takes no argument.** `alter table ... disable trigger` is **global**, so an earlier draft's `rollback_shift_migration(p_user_id uuid)` disabled conversion for everybody while stamping `rollback_at` for one account. Every other converted account then read null from `payday_shift_rollback_at()`, kept `shiftsAreAuthoritativeAt` set, kept reading `shifts` as authoritative, and kept having 1.0 devices write `tip_entries` that nothing folded on arrival — their new money invisible until some new-build sync happened to run the one-shot, with no banner and no signal anywhere. The draft named the global-disable fact and then drew the opposite conclusion from it. So the unsafe operation is not expressible:

```sql
-- public.rollback_shift_migration() -- NO ARGUMENT. One transaction.
alter table public.tip_entries disable trigger tip_entries_fold_insert;
alter table public.tip_entries disable trigger tip_entries_fold_update;
alter table public.tip_entries disable trigger tip_entries_fold_delete;

update public.shifts set deleted_at = coalesce(deleted_at, statement_timestamp()),
                         deleted_reason = coalesce(deleted_reason, 'converted')
where source = 'migration' and array_length(legacy_entry_ids, 1) > 0;

delete from private.shift_fold_backlog;

update public.shift_migration_state            -- EVERY row, same transaction
   set rollback_at = coalesce(rollback_at, statement_timestamp());
```

Per-account **repair** is a separate artifact that only re-runs `migrate_tip_entries_to_shifts(p_user_id)`, which is idempotent and touches no trigger.

Two operational facts go in the function comment. `alter table ... disable trigger` takes **ACCESS EXCLUSIVE** on `public.tip_entries`, so rollback blocks every device's writes on the app's only legacy write table for its duration and queues behind any open transaction on it. And re-enabling is an explicit separate operator step (`alter table ... enable trigger`) which must be followed by one `migrate_tip_entries_to_shifts` run per account, because the backlog was deleted.

`shifts.source` plus `legacy_entry_ids` is the **only** safe rollback query, which is why `source = 'migration'` is load-bearing: writing `'device'` there would leave no way to tell a conversion artifact from a shift the user authored.

`public.payday_shift_rollback_at()` is `stable`, definer, and read at the **top** of `synchronize`, one call site, lint-pinned. On a non-null value the client, through `mutate`, clears `shiftIDs`, `shiftServerCursor`, `shiftClientUpdatedAt`, `shiftServerAckedIDs`, `shiftWriteAttempts`, `pendingShiftRestores` and `shiftsAreAuthoritativeAt`, stops pushing shifts, and **also deletes every local `ShiftRecord` and every durable `ShiftTombstone`**, or a later re-forward-migration meets a stale cache.

**Clearing `shiftsAreAuthoritativeAt` is what returns the reader to the legacy leg.** An earlier draft added "resets the local `MigrationRunner` version key from 3 to 2" and called that "the only thing that stops a non-downgradable device rendering an empty history". There is no version 3 in this shape: `MigrationRunner.currentVersion` is 2 (`MigrationRunner.swift:8`), 1.5 deletes device-side Migration 3 as a deriver, 6.4 says not to change the step-1 gate, and the key is unreachable anyway (`versionKey` is `private static let`, `:7`). A worker following it either writes dead code or bumps `currentVersion` to 3 and re-runs a migration step that no longer exists. The sentence is deleted.

A 1.0 device reads nothing about rollback and simply keeps writing, which is correct: with the trigger disabled its writes land in `tip_entries` and are read by its own screens, exactly as before PR 2.

### 12.3 What rollback cannot undo

| loss | why | compensating action |
|---|---|---|
| A post-conversion **deletion** resurrects | **not** automatically covered. `ShiftCommands.delete` queues the legacy tombstones, but 8.4 item 2 means the flush can legitimately have written none of them, and 8.4 item 3 means an Undo may have re-pushed them | run `soft_delete_tip_entries` over the `legacy_entry_ids` of every shift with `deleted_reason = 'user'` **before** tombstoning the artifacts, and assert its **return set** equals the requested set. Test `a_post_conversion_deletion_is_not_resurrected_by_rollback`, with a variant where the device's flush had failed the staleness guard |
| A post-conversion **edit** reverts | the old build renders the pre-edit legacy values, and R1 means `tip_entries` was never rewritten | dump `shifts where native_modified_at is not null` to CSV. **Not** `converted_at < client_updated_at`: arm 1 writes `converted_at = statement_timestamp()` unconditionally while `client_updated_at` sits inside the `shift_is_open_to_fold` CASE and is preserved on a closed shift, so the moment 4.5's own headline case occurs — the user edits Jul 4, then an old phone pushes one unsynced $20 cash tip for Jul 4 — `converted_at` jumps above `client_updated_at` and the edited shift drops out of the dump, and out of `shift_migration_state.edited_since_conversion_count` (5.4), which is pinned with the same comparison. Nothing is destroyed, but the prescribed recovery silently omitted exactly the shifts most likely to need it. `native_modified_at` is written only by `private.write_shifts` (4.5), so it is the right predicate for both. Keep `converted_at` for the display fact. Tests `a_post_conversion_edit_appears_in_the_dump`, `an_edited_shift_that_later_received_a_legacy_write_is_still_in_the_dump` |
| A **natively authored** shift becomes invisible | it has no `tip_entries` representation, by design | dump `shifts where array_length(legacy_entry_ids,1) is null and deleted_at is null`. **Nothing is destroyed**, it is only unreadable by a legacy reader |
| A shift the fold tombstoned in arm 2 whose sources were later un-deleted | `deleted_reason = 'converted'` is tombstoned again | none needed: the legacy rows are live, so the old build shows the night |

**Nothing on the legacy side is unrecoverable.** `tip_entries` is never rewritten by the new build and is the entire reversibility artifact. That is the whole rollback story, and it is why R1 is a design rule rather than a preference.

---

## 13. Implementation slices

Each slice is worker-sized, names its files, tests and gate, and says what it may run beside. No slice merges on a red job.

**S1. `ShiftRecord`, container, build wiring, earnings writer.** Files: `Payday/Models/ShiftRecord.swift` (new), `ShiftReceiptMetrics.swift` (`normalizedToV2`), `SharedModelContainer.swift` (`static let schema` only — **`autosaveEnabled = false` moves to S9**, 8.2), `project.yml`, `scripts/design-lint.sh` (the three bans, the `Snapshot` key check, the `gratuityFeesCents'`-in-SQL ban, the `on conflict`-with-`where` ban, and the single-definition pins on `shiftsAreAuthoritative`, `recordTipDeletions` and `payday_shift_rollback_at`), `PaydayAccountEraser.swift`.
Tests: `ShiftRecordTests` (encode-only setter, `receiptPayloadIsUnreadable`, the `?? .device` fallback, canonical id string), `ShiftReceiptMetricsTests` (+ `normalizedToV2` idempotence and the N4 numbers), `ShiftWriterTests.wageOnlyShiftIsLostToday` as a **characterization** test pasted into the PR body.
Gate: job B builds **app and widget**, job D green, plus one measured probe recorded in the PR body: **open the App Group store with the 1.0 two-entity schema after a `ShiftRecord` has been written**, and record whether SwiftData tolerates the extra entity or falls back to in-memory. Downgrade is now an ordinary path (TestFlight, a second device, a restore), and the in-memory fallback plus `openingFailed` is the same "goes dark" premise that killed shape 2 arriving through downgrade. A failing probe is a decision for Tyler before any build ships. **Parallel with S2.**

**S2. SQL, schema only.** Files: one migration with `public.shifts` (composite key, both generated columns via `private.receipt_gratuity_cents` with the numeric clamps, both receipt CHECKs, the 2.4 comments), `private.receipt_gratuity_cents` and its never-edit comment, `payday_legacy_shift_id`, `private.legacy_group_key`, `private.touch_shift_row` and its trigger, the three shifts indexes plus `tip_entries_user_group_all_idx`, RLS and the **select-only** grant, `shift_migration_state` (with `remaining_group_count`), `shift_legacy_conflicts`, `private.shift_fold_backlog` (with its FK and `queued_at` index), `private.shift_fold_failures` (with its FK), the `20260911150000` cascade comment naming all five tables.
Tests (E): both identity vectors; `theDerivedIDIsIdenticalAcrossUsersAndThatIsFine`; a cross-account upsert returns 1 row and both rows exist; `shifts_receipt_is_v2` rejects absent / json-null / `"1"` / `true` and accepts `2`; `shifts_receipt_is_object` rejects `[1,2]`; `1234.6` **rounds to 1235**; `99999999999`, `1e30`, `-500` and `2147483000 + 2000000` all insert with clamped values and no `22003`; `non_wage_earnings_cents` goes legally negative; `an_authenticated_direct_insert_into_shifts_is_denied`; `delete_my_account` leaves zero rows in all five new tables.
Gate: job E from a clean `supabase db reset --local`. **Parallel with S1.**

**S3. SQL, the single deriver.** Files: `private.derive_shifts(uuid, uuid[])` — no `p_strict`, one `v_grouped` local read by all four arms, `payday.folding` cleared before every return including the handler.
Tests (E): N1 (duplicated tip-out subtracts once); N4; **N5** (object-first metrics ranking: cash 800 / credit 2000 / gratuity 4200 / non-wage 7000, and the as-written `is not null` ranking gives 11200); L1 (`min(work_date)`); L2 (metrics owner); N3 (null is not zero); P6; every junk-payload row of 3.4 including the three out-of-range ones; the stored payload of every fixture decodes as `ShiftReceiptMetrics` on the Swift side (2.5); two calls produce byte-identical rows; the range filter precedes grouping; `aNativeShiftWriteAfterAFoldInTheSameTransactionStillBumpsVersion`. Gate: E. **Depends on S2.**

**S4. SQL, the trigger.** Files: `private.fold_legacy_writes()`, the three triggers, the try-lock, the **reserved** 40/10 budget with the backlog delete and `on conflict do nothing`, the five-arm exception block (`query_canceled`, `assert_failure`, `others`, each recording **and** queueing), arms 1 / 2a / 2b / 3 / 4, `last_legacy_write_at`, `bulk_legacy_rewrite_at`, the account-deletion no-op.
Tests (E): the full **S-gate** table of 4.6, all five abort classes; the two-session race under **`pg_try_`** gives `cash 5000 / credit 0 / prov 1 / 1 backlog row` and the blocking variant gives `5000 / 2000 / prov 2 / 0 backlog`, both recorded verbatim; `aConcurrentLegacyWriteThatLosesTheLockIsStillCountedAfterTheNextSync`; `emptying_every_row_of_a_group_tombstones_its_shift`; `aClosedShiftWhoseSourcesMoveAwayLosesItsClaimAndIsReported`; `aNativelyEditedShiftWhoseLegacyRowsWereDeletedKeepsItsMoneyAndRecordsAConflict`; the un-delete arm reopens a `'converted'` tombstone and never a `'user'` one; an UPDATE moving `shift_id` or `work_date` recomputes **both** groups; a `service_role` write folds into the row's owner; `aFiveHundredRowBatchDrainsAtLeastTenBacklogGroups`; `aSaturatingStatementStillDrainsOneBacklogGroup`; `two_sessions_queueing_the_same_group_neither_block_nor_raise`; `delete_my_account` still succeeds with shifts, conflicts, backlog and legacy rows present; `aDownwardLegacyCorrectionOnAClosedShiftIsStillSurfaced`; `aMatchingLateArrivalDoesNotEraseAnEarlierDisagreement`.
Gate: E, plus the measured 500-row timing in the PR body (the reference figure is 14.6 ms for 500 rows / 250 groups). **Depends on S3.**

**S5. SQL, the one-shot, counters, rollback.** Files: `migrate_tip_entries_to_shifts(p_user_id, p_max_groups)` with `remaining_group_count` and the backlog delete, the shared `unmigrated` expression, the scoped conservation check with the closed-shift exclusion and the scalar `v_dupes`, the duplicate detector, `payday_unmigrated_tip_row_count` **defined as that same expression plus the backlog**, `rollback_shift_migration()` (no argument), the per-account repair, `payday_shift_rollback_at`.
Tests (E): `the_dupes_count_is_never_null`; `a_wrong_partition_is_still_recorded`; `a_wrong_money_split_is_still_recorded` (both asserting a commit, not a raise); `aNativelyEditedShiftWhoseLegacyRowsWereDeletedDoesNotFlagConservation`; `aClosedGroupInTheBacklogDrainsWithoutFlagging`; `aLegalEditFollowedByThreeReInvocationsNeverFlags`; `theCompanionCountIsZeroExactlyWhenTheOneShotHasNothingToDo` over all four predicate arms plus a backlogged group; `aTwoThousandGroupHistoryConvergesInCeilingOfTwoThousandOverTwoHundredPassesAndNeverRollsBack`; `two_consecutive_no_op_invocations_leave_migrated_at_byte_identical`; `an_edit_made_between_two_invocations_is_still_found_by_the_rollback_query`; the miss sequences of 5.2; `a_late_legacy_row_for_a_day_that_already_has_a_native_shift_is_reported_not_silently_doubled`; all three rollback tests including `an_edited_shift_that_later_received_a_legacy_write_is_still_in_the_dump`; rollback stamps **every** `shift_migration_state` row, disables the triggers, and a subsequent legacy write converts nothing.
Gate: E. **Depends on S3, parallel with S4.**

**S6. Shift write RPCs and the wire model.** Files: `private.write_shifts` (takes the **blocking** `pg_advisory_xact_lock` on `payday:shiftmig:<uid>` before touching `public.shifts`, stamps `native_modified_at` and `source`, clamps `client_updated_at`, returns outcomes), `public.upsert_shifts`, `soft_delete_shifts`, `restore_shifts` (definer, own-account only), `fetchShiftChanges` returning `serverNow = statement_timestamp()` per page, `PaydayRemoteModels.swift` (`RemoteShift`, `ShiftWriteOutcome`), `PaydayRemoteRepository.swift` (`upsertShifts`, `softDeleteShifts`, `restoreShifts`, `fetchShiftSnapshot`, `fetchShiftChanges`, `fetchShifts(ids:)`).
Tests: E for the RPCs (no clock gate, the `deleted_at` transition table, outcome totality, never 42501); `PaydayRemoteRepositoryTests` for payload shapes. Gate: B, C, E. **Depends on S2.**

**S7. `PaydaySyncState`.** Files: `PaydaySyncState.swift` (delete `save`, add `mutate`, the hand-written `PendingDeletions` decoder, the new `legacyEntries` deletion key of 8.4, `ShiftTombstone`, the seven `Snapshot` fields with decode lines, `shiftsAreAuthoritative(for:)`, `shiftCursorSafetyWindow`, `shiftCacheRequiresBaseline`, the shift deletion and restore queues) and the two converted `save` call sites.
Tests: `PaydaySyncStateTests` (`pendingDeletionsDecodeA10ShapedBlob` with the fixture **generated by encoding**, not hand-written; `everySnapshotFieldSurvivesEncodeDecode`; `clearingOneFlagPreservesEveryOtherField`; `aFullSyncPassPreservesPendingShiftRestores`; `aLegacyDeletionQueueEntrySurvivesARestoreCancelPass`; both cache-baseline functions). Gate: B and D. **Parallel with S6.**

**S8. The sync leg.** Files: `PaydaySyncService.swift` (the shift block in the 7.5 order including step 6a, the two-call `reconcileShifts` split of 7.5, the cursor safety-window clamp of 7.7, `verifyServerRetainsAcknowledgedShifts`, outcomes and backoff, the legacy-deletion flush that reads the RPC's return set, `restoreLegacySources`), `PaydayCloudGate.swift` and `PaydayCloudState` (`conversionPending` on the report and the **banner**, never a blocking `Phase`; `requiresFollowUpSync` only on a strictly decreasing `remaining_group_count`; `shiftsAreAuthoritativeAt`), `PaydayMigrationService.swift` (receipt last, import before the first shift pull).
Tests: `ShiftSyncReconcileTests` plus every test named in 7.5, 7.7, 7.9, 8.4, 8.5 and 4.9, including `anUnfinishedConversionStillFlushesAPendingTipDeletion`, `a_shift_folded_by_a_long_transaction_is_still_delivered_after_the_cursor_advanced`, `aServerClampedClientUpdatedAtOnAJustPushedShiftIsAdopted`, `aNonDecreasingRemainingCountIssuesAtMostOneRPCPerPass`, `undoAfterTheFlushRestoresTheLegacySources`. Gate: B. **Depends on S6 and S7.**

**S9. `ShiftCommands`, the projection, every call site.** Files: `ShiftCommands.swift`, `ShiftProjection.swift`, `LegacyShiftRow.swift` (all new), `SharedModelContainer.swift` (**`autosaveEnabled = false` lands here**, 8.2), **`project.yml`** (the widget target gains `ShiftRecord.swift`, `ShiftProjection.swift`, `LegacyShiftRow.swift` and `Payday/Sync/PaydaySyncState.swift`, 6.2), signature-only edits to `ShiftDetails`, `TipBreakdown`, `TipRecord`, `CSVExporter`, `PeriodIncome`, `WageEstimate`, `PredictedPaycheck`, `SmartNudgeScheduler`, `PaydayPushScheduler`, plus `MigrationRunner.swift` (the `Set(...)` determinism fix only, generation unchanged), `ShiftDays.swift` (`isGeneration0LegacyID`; `deterministicShiftID` stays live and undeprecated; **no `legacyShiftID`**), the 13 `@Query` views, `LogTipSheet.swift`, `BackfillSheet.swift` (explicit save), `Payday/Views/Periods/PaycheckEntrySheet.swift` (explicit save on both `save` and `delete`), `UndoDeleteToast.swift`, `LogTipsIntent.swift`, `PeriodTotalIntent.swift`, `PaydayWidget.swift`, `MainTabView.swift`, `TipEntrySheetTarget.swift`, `ShiftContextMenu`.
Tests: `ShiftCommandsTests` (atomicity under a forced throw, `wageOnlyShiftSaves`, the three copy strings, the delete/undo inverse, the five converted fence call sites), `ShiftProjectionTests` (the full 10.1 rule including N6's cash-only-with-tip-out case and the one-zero-row case, `aNativeRecordsIDIsNeverInAnyLegacyRowsGroup` over every fixture, the additive legacy leg, stable ids), `LogTipsIntentTests` rewritten with `aSiriLogIsRefusedBeforeShiftsAreAuthoritativeAndLeavesNoRecord`, `MigrationRunnerTests` with `a_1_0_device_backfilling_the_same_day_does_not_rekey_the_group`, the persistence tests of 8.2 (paycheck, backfilled shift, live field edit each survive a container reopen), the three write-gate tests of 8.7, and all 12 kept suites green **unchanged**.
Gate: B green with the 609 count intact (read from the `Test run with N tests` line) and the **widget target** built, `RenderFactsPerformanceTests` re-baselined. **Depends on S1; parallel with S4, S5, S6, S7.**

**S10. The fence.** Its own commit, after S8 **and** S9. Files: the two `@available(*, unavailable)` annotations plus the two replacements. Tests: the two 7.6 deletion-queue tests. Gate: B and D, where D is the real gate — **zero references to `recordTipDeletions` or `cancelTipDeletions` outside `PaydaySyncState.swift`**, enforced by `design-lint.sh`. Not a count of compile errors: S9 has already converted all five (8.4).

**S11. Agent API. PREMISE HOLDS — PR 2 work, partly done.** Audited
2026-09-18 against the one question that expired S10: *does this slice
assume legacy is dead or dying?* **No, the opposite.** It specifies
`get_shift` resolving "a pre-conversion nil-`shift_id` id via provenance"
and `anAgentMovingARowBetweenShiftsRefoldsBothGroups`, both of which require
legacy rows and a live fold trigger. Shape 3 keeping legacy alive is the
condition this slice was written for.
State, and the first version of this line was WRONG in a way worth keeping.
It said the shift paths were "served without test coverage". That came from
grepping `index_test.ts` for the strings `listShifts` and `getShift`, which
returns nothing -- because the tests exercise BEHAVIOUR rather than naming
internals. `index_test.ts` has five shift tests going through
`testing.shiftResponse`, the real response-shaping path: the derived money
is read and never recomputed, the gross comes from the stored net, the
owning account does not leak, provenance replaces the embedded rows, and
absent optionals report null rather than vanishing. Same instrument error as
searching for a test SUITE by filename when it is a struct.

**Corrected AGAIN, and S11 is essentially COMPLETE.** The second version of
this line said the query layer was uncovered. Also wrong, by the same
instrument error a third time: I grepped `supabase/tests/` for `get_shift`
and `list_shifts`, the SLICE's names, while the function is
`public.payday_agent_shift_by_id`.

`supabase/tests/agent_api_shifts_test.sql` exists and covers exactly the
case I twice claimed was missing, including
`aPreConversionLegacyIdStillResolvesViaProvenance` -- a pre-conversion
legacy id resolving through the shift that absorbed it -- plus both absorbed
legacy ids, a not-found id, and cross-account isolation.

So both halves are covered:

- **Response shaping and the money:** five tests in `index_test.ts` through
  `testing.shiftResponse`, the production path.
- **The query layer:** `agent_api_shifts_test.sql`, including the
  provenance case.

The slice's named artifact `agent_shifts_test.ts` does not exist; the
coverage lives in the SQL test the slice ALSO asked for ("Tests (C, plus E
for the SQL side)"). A missing filename is not a missing test.

**Three identical instrument errors, one root cause.** Searching for
`DayHeroEqualsItsRowsTests` as a FILE when it is a struct; for
`listShifts`/`getShift` in a test file that names BEHAVIOUR; for `get_shift`
when the function is `payday_agent_shift_by_id`. Each time I searched for
the SPEC's name rather than the CODE's, and each time the absence of a
string read as the absence of a test. All three made things look worse than
they were.

**S11 (original).** Files: `index.ts` (`listShifts`, `getShift` with the step-2 lookup, `payday_agent_summary` on `shifts`, `CHANGE_TABLES`, the `createShift` corrections), `sql_corrections.ts`, `agent_shifts_test.ts`, `docs/PAYDAY_API.md`.
Tests (C, plus E for the SQL side): the six corrections with fixtures; `tipOutIsResolvedOnceByBothImplementations`; `differentialAgainstGroupShifts` both directions; the identity vectors; the forced-stale replay; `anAgentMovingARowBetweenShiftsRefoldsBothGroups`; `get_shift` by a pre-conversion nil-`shift_id` id resolves via provenance. Gate: C and E. **Depends on S3.**

**S12. The bridge parity suite. PREMISE HOLDS — PR 2 work, barely started.**
Same audit. **No** -- a BRIDGE parity suite compares the two
representations, so it requires legacy alive by definition.
State: `BridgeRepresentationParityTests.swift` exists with **2 tests** and
implements none of the specified content -- no `ScreenNumbers` fields, no
delta table, no `apiShiftArrivesOnce`. The name matches; the slice does not.

**S12 (original).** Files: the shared fixture JSONs, `BridgeParityTests.swift`, the job E fold assertion, the `PaydayCoreTests` N4 assertion, the Deno twin. Tests: the 16 `ScreenNumbers` fields, the 5-entry delta table with P6 at zero, the three mutation cases that must fail, `apiShiftArrivesOnce`. Gate: A, B, C, E. **Depends on S3 and S9.**

**S13. Data health and user-facing surfaces. PREMISE HOLDS — PR 2 work,
not started.** Same audit. **No, emphatically** -- the whole slice exists to
surface a conversion IN PROGRESS, which requires legacy alive and
converting.
State: not started. `conversionPending` reaches `ShiftCommands`,
`LogTipsIntent`, `PaydayCloudGate` and `PaydayMigrationService`, but **no
view references it**, so a shift the server is mid-conversion on is refused
by `mayMutate` with nothing on screen explaining why. Partially mitigated
2026-09-18: `LogTipSheet`'s failure alert now renders the specific
`Failure.message` instead of the generic one, so the refusal at least says
"Payday is still syncing this shift." The banner, the conflicts list and the
progress number remain unbuilt.

**S13 (original).** Files: the Data health screen (the conflicts list with **[Keep mine] / [Use theirs]** per row, 4.5; the duplicate-day list with a merge action; rows in closed shifts; `remaining_group_count` as a progress number; the unreadable-receipt line; the bulk-rewrite banner; the conservation-flagged line), the `PaydayCloudState` conversion banner copy, the `[Try again]` / `[Show details]` retry surface. Tests: `PaydayCopyTests`, a snapshot per state, `aConflictResolvedWithUseTheirsMatchesTheLegacyNumbersAndStaysClosed`, `aPermanentlyUnfoldableGroupDoesNotMakeTheAppReadOnly`. Gate: B and D, plus a design review on renders before "done". **Depends on S5 and S8.**

### Audit result, 2026-09-18: S10 was the only slice shape 3 expired

| Slice | Assumes legacy dead or dying? | Holds | Destination | State |
|---|---|---|---|---|
| S10 fence | **YES** — "TipEntry is read-only in this build" | **NO** | **PR 8**, behind the RELEASE_GATE entry condition | reclassified |
| S11 Agent API | No — resolves pre-conversion ids via provenance | Yes | **essentially DONE** | money covered (5 tests) AND query layer covered (`agent_api_shifts_test.sql`) |
| S12 bridge parity | No — a bridge needs both representations | Yes | PR 2, now | 2 tests, none specified |
| S13 data health | No — surfaces conversion in progress | Yes | PR 2, now | not started |

**The consequence is larger than the hygiene.** If the remaining slices had
been deletion-phase work like S10, criterion 1's remainder would collapse
onto criterion 6's dependency -- the records arm out-gating legacy -- and
neither could finish before the other. They did not. S11, S12 and S13 are
all TRANSITION-phase work that requires legacy alive, so **criterion 1's
remainder is independently completable now** and does not wait on PR 8.

**Merge order rule.** No SQL slice merges until job E is green from a clean `supabase db reset --local`, and no client slice merges until job B has built **both** targets. A local `TEST SUCCEEDED` is not evidence.

---

## 14. Harvest ledger

Every id from three prior rounds, with where it landed or why it died. The **why** is deliberately one line: the reasoning lives in the section named, and duplicating it here is how a design doc triples in size.

### 14.1 Kept

| id(s) | in | why it survived |
|---|---|---|
| `Y-1`, `Y-1 / §3.4` | 2.3, 2.4 | More load-bearing, not less: the trigger now mints cross-tenant-identical legacy ids forever, and every reader that caught the silent zero-row drop is deleted. |
| `B-1 + X-1 (SQL half)`, `B-1 + X-1 / §3.1` | 2.6 | Still the group key, now a persisted primary key. `X-1` reason 1 records why this exact form (`A-4`'s SQL produced a 36-char string and did not cast). |
| `B-1 pt 3`, `§6.1 step 2 (group key expression)` | 3.1 | Key is a pure function of ONE row, so the fold is snapshot-independent. Now defined once, in `private.legacy_group_key`. |
| `B-1 pt 4 + pt 5`, `§3.3` | 6.4 | The device still mints `shiftID` on a fresh or restored store and the server groups by it, so the **determinism** fix survives. The *generation change* it was bundled with does not: see 14.2. |
| `base §3.5 body`, `base §3.5 body → §6.1 step 3` | 3.2 | The hardest-won artifact in the 487KB, now the only deriver, extracted so two callers cannot diverge. |
| `cutover §2 + §6.4`, `§6.4 + S4c gate` | 3.3, 11.4 | $22.00 and a different cash/credit split on N4. Unaffected by who converts. |
| `Y-18` | 2.1 | Same $122-for-$80 inflation; a setter that mutates two other stored properties is order-dependent. |
| `cutover §2 receiptPayloadIsUnreadable` | 2.1 | Now the only device-side defence of the receipt contract, because gratuity is a generated column. |
| `base §3.1 (generated columns)`, `§3.4 generated columns` | 2.3 | The fold is a continuous writer of these values, so one implementation per language beats detectable drift. |
| `base §3.1 receipt CHECK (amended)`, `§3.4 shifts_receipt_is_v2` | 2.5, 3.4 | Only server-side guarantee a v1 payload never lands twice-subtracted. New obligation: the fold sanitizes so it can never fire inside a 1.0 transaction. |
| `base §3.1 (object check, re-kept)` | 2.5 | Dropped by the cutover, brought back: `tip_entries` has no object CHECK, so `jsonb_set` can raise inside the 1.0 write. |
| `base §1 legacySourceModifiedAt`, `§6.1 step 2 + §3.4` | 5.2 | Server-side only. The only recovery for every write the trigger never saw. |
| `cutover §6.1 step 3`, `§6.1 step 3 (measured P0)` | 4.4 arm 1 | The measured `INSERT 0 0` no-op. Same statement now runs inside a 1.0 transaction. |
| `base §1 adoptedAt + Y-19` (UN-DROPPED, narrowed) | 2.3, 4.5 | The cutover's premise "no legacy row can change" is false here, permanently. Survives as server-side `native_modified_at` plus `unconverted_legacy_cents` only. |
| `base §0.4`, `C-7 D1` | 3.2, 9.4 | `min(work_date)`. A property of what is computed, not of who computes it. |
| `C-7 D4` | 3.2, 9.4 | "Never entered" and "tipped out nothing" are different facts. |
| `base §1 CloudKit rules + third source value`, `§3.4 source + §2 ?? .device` | 2.1, 12.2 | `?? .device` earns its keep on day one; `source` is the only column rollback can ask about. |
| `base §1.2`, `Y-12 pt 2 (schema half)`, `R-16`, `R-3` | 2.2 | Pure build facts, each of which ships a visibly broken app if missed. |
| `base §0.1 + Y-6 (shifts half)` | 7.8 | Reintroducing the acceptance gate recreates the slow-clock lockout `20260904134500` removed. |
| `base §3.1 indexes (+ one new)`, `§3.4 gin index` | 2.7 | Both surviving gin consumers are containment scans, one now on the hot path; the new non-partial index exists because the fold reads tombstoned rows. |
| `base §3.3 + the 42501 fact`, `§6 header` | 2.7, 4.3 | The definer rule now binds a new object, the trigger, and the `current_user` trap is the same trap. |
| `§6.1 step 1 + B-5 part 1` | 4.7 | The answer to both races. A trigger fires several times per transaction, so the no-temp-table reentrancy rule is fatal rather than theoretical. |
| `§6.1 step 4 (scoping half)` | 5.3 | Account-wide conservation is permanently unsatisfiable once one native shift exists, and an unsatisfiable raise wedges everything. |
| `§6.1 step 4 (v_dupes rewrite)` | 5.3 | Measured bug that printed `dupes=<NULL>` and silently disabled half the check for a round. |
| `A-6 + Y-13 (predicate shape)` | 5.3 | A partition, never a count bijection, because `update_tip_entry` accepts `shift_id`. |
| `§6.1 step 5` | 5.4 | `migrated_at` measured moving on a no-op re-run, and this shape adds re-run paths. |
| `§4.1 shift_migration_state (trimmed)` | 5.4 | The only account-level record, the counters' home, and rollback's only anchor. Not `migration_receipts.schema_version`, which is per device. |
| `§4.1 (counters clause)` | 5.4 | Strictly more legal reasons to disagree now, so the "informational, never a raise" clause must be louder. |
| `§6.1 step 3 (duplicate detector)`, `rows_in_deleted_shifts` | 5.5 | Both conditions are permanent, not one-shot, and refusing to commit would wedge the fold. |
| `§6.2 payday_unmigrated_tip_row_count()` | 5.6, 4.8 | Stops being a progress meter, becomes the watchdog; steady state is exactly 0. |
| `§6.2 (range filter placement)` | 3.2 | A filter-after-grouping bug in the shared deriver would now corrupt writes. |
| `§6.3` | 7.9 | The first-sign-in order, and the rule that the gate is a server fact because `runPending` executes one line before `restore(...)` with no session. |
| `§3.2` (principle only) | 6.5 | The zone hazard is why the server keys off its own `work_date` and nothing the device recomputes. |
| `§4.2 (repurposed)` | 4.1 | Now the central argument for a trigger rather than an RPC wrapper. |
| `base §5.5 / §5.6`, `§5.6 fence narrowed` | 8.4 | One direction needs a compile error; both symbols annotated. The five call sites are S9's acceptance list, not S10's gate, because S9 converts every one of them; S10 gates on `design-lint.sh`. |
| `base §2.0 R1 + R2` | 3.5 | R1 is the entire rollback story; R2 makes idempotency a property of the key. |
| `§13.1 / §13.2`, `§13.1 R1 + §13.3 step 4 + §13.4` | 12 | Needed more, because the server now rewrites continuously; plus the new trigger-disable requirement. |
| `C-3 / X-12 / cutover §8.6` | 7.2 | Synthesized decoder plus `try?` silently drops every queued 1.0 deletion, the only carrier of that money. |
| `C-3 corrected half / cutover §8.2` | 7.2 | A forgotten decode line is a silent default, not a throw, so the obvious lint can never fire. |
| `Y-8 / cutover §8.3` | 7.3 | `save` builds a fresh Snapshot, so leaving it erases every new shift field every pass. |
| `A-3 / X-8 / cutover §8.5` | 7.4 | The device may not derive, so a rebuilt cache is repairable only by a server baseline. Sibling, never an extra arm. |
| `C-1 / cutover §8.4` | 7.7 | Acked from server responses only; full check in the baseline branch only; the leg is skipped whole when not ready. |
| `C-5 (ordering half) / X-7` | 7.7 | The one sync that pushes the whole history currently verifies nothing. |
| `cutover §8.7 (paycheck + settings half)` | 7.5 | Inverting the pull globally throws `paycheckMismatch` every sync and clobbers a locally changed wage. |
| `Y-17 (Swift side)` | 7.7 | Still the correct failure direction; the device is the only holder of a natively authored shift. |
| `Y-6 (shifts half)` | 7.8 | Three writers of one row makes a stale un-delete more reachable, while `restore_shifts` must stay admissible. |
| `C-2 pt1+pt6 / Y-7 / A-2 / X-13` | 8.5 | Nothing reconciles behind Undo now, and the flushed case is the common case (2s debounce inside a 4s window). |
| `cutover §9 + base §7` | 8.1, 8.2 | One mutation boundary; the `autosaveEnabled = false` clause is not optional or atomicity is false as written — but it lands in S9 with the paths that replace autosave, never in S1. |
| `cutover §9.3 / base §7 Draft.hasContent` | 8.1, 8.3 | The wage-only loss is verified line by line in `ShiftWriter.swift`; the characterization test is split S1/S5. |
| `cutover §9.3 / base §7.1 (call-site map)` | 8.3 | About 150 lines go away; the largest client simplification, untouched by the shape change. |
| `cutover §9.3 (intent row)` | 8.6 | The phantom-double bug is real and storage-independent. |
| `base §8.1 + §8.2 + §8.3` (REINSTATED over `cutover §11.2`) | 10.1 | The one reversal: one row per kind dissolves the cutover's own objection, so 609 tests compile by construction. |
| `cutover §11.1 (two @Query)` | 6.2 | `@Query` tracks dependencies; a function call does not, so screens would stop refreshing. |
| `cutover §11.1 (write gate)` | 8.7 | A write into an unread store makes the user log it twice and two ids reach the server. |
| `A-7 (phase half)` | 7.9 | The only place "no screen shows $0" is implemented, and the wait is longer here. |
| `Y-11 / A-7 (receipt-last half)` | 7.9 | The receipt currently claims something that may not have happened, and never retries. |
| `Y-12 pt 4` | 7.9 | Promoted from safety net to the only route local-only rows have to becoming visible money. |
| `base §5.3 step 1, de-scoped` | 7.6 | The correct implementation of "flush the 1.0 queue" is no code at all. |
| `base §5.6 / A-0` | 2.2, 7.9 | Otherwise a deleted account leaves rows on disk and a checkpoint the next Apple ID inherits. |
| `R-14` | 7.5 | Reusing the shipped during-pass shapes is near-zero risk; inventing a rule is not. |
| `cutover §11.2 / base §8.4 / STATUS.md` | 10.2, 10.3 | Nothing is deleted in PR 2, so the table keeps 609 honest. Both CI facts are already paid for. |
| `cutover §12 / base §9.1 + §9.4 / C-8` | 11 | The only artifact proving a person's screens did not change, with teeth so it cannot degrade. |
| `cutover §10 (agent reads) + §10.1` | 9.2, 9.3 | No read-through fallback; `get_shift`'s provenance lookup is both the fix and the old-id map. |
| `cutover §10.2 (C-7) + X-18` | 9.4 | Named signed fixtured corrections, and the strike stops a worker asserting a non-bug into existence. |

### 14.2 Dropped

| id(s) | why |
|---|---|
| `base §3.2 + §3.3 (claims)`, `base §2.0 R3 server half`, `Y-1 claims-FK half`, `B-2`, `B-3`, `B-4`, `Y-15`, `Y-16`, `X-5`, `X-6`, `X-16`, `shift_legacy_claims` + its index + RLS + the design's only `grant ... delete` | A claim arbitrates between two writers of one legacy row. One writer per account and one `group by`, which cannot emit a row into two groups, makes a duplicate claim unrepresentable rather than detected. The composite-FK pattern carries forward. |
| `base §3.5 / §3.6` framing: read-through derivation, `persisted UNION ALL derived`, `derived boolean`, disjointness-by-claims, "the server persists nothing" | Its populations (un-migrated phones, unswept rows) are gone and the server now persists on arrival. A worker must not carry "the server persists nothing" in. The body survives as the fold. |
| `Y-3`, `cutover §3.2`, `LegacyServerFact`, `legacyServerFacts`, `legacyKey(for:facts:calendar:)`, its recording point, its v3 pruning, the zone identity tests | Existed to make a **device-derived** id agree with the server's. No device derives. The zone finding survives in 6.5. |
| `ShiftRecord.legacyDayKey`, `shifts.legacy_day_key` | Nothing re-keys. Redundant for a legacy group, and a lie for a `shift_id` group spanning two work dates (L1). |
| `legacySourceModifiedAt` (Swift), `adoptedAt` (client field), `earningsSchemaGeneration` | Mirrors of the sweep and the adoption-aware reconcile. The watermark is server-only and the guard is server-set so it cannot be forged; `applyEarnings` + the v2 CHECK make generation an invariant, not a stamp. |
| `C-4`'s original `normalizedToV2(cashCents:creditCents:)` | A port of the edit path. 6000 versus 8200 on N4 and a different split. Named so no worker resurrects it. |
| `X-11`, `A-4`, `Y-2`, `Y-4`, `Y-5`, `Y-14`, `X-3`, `X-10`, `base §5.4 sweep`, `CT-2`, all `ShiftDivergence` / `ShiftDivergenceStore` / `LegacyShiftConverter.sweep` / arms (a1)(a2)(a3)(b)(c)(c-partial) / `SweepEvidence` / `.noneYet` / clause (d) / `rePartitionLedger` + oscillation guard | The dual-representation engine. A trigger folding in the writer's own transaction does that job once per write. Every `Kind` case needs a second device-side writer, so the type has no surviving case. `Y-4` and `Y-5`'s obligations move into fold arms 2 and 3. |
| `A-1`, `A-2 (legacy half)`, `C-2 pts 2/3/4/7`, `§5.5 exceptions 1-3`, `X-2`, `Y-6 (tip half)`, `LegacyRowSnapshot`, `restoreLegacyEntries`, `pendingLegacyRestores`, a client `restore_tip_entries`, the converter's tombstone skip, the `upsert_tip_entries` coalesce amendment, `ShiftTombstone.reassertions` + budget | Undo restores one `ShiftRecord`, and 4.5 closes it to the fold. `upsert_tip_entries` and `soft_delete_tip_entries` are frozen as shipped, because amending them is another way to reject an old build's write. The real un-delete hazard is answered by arm 3. |
| `cutover §4` and `§5` entire: the version floor and its storage/enforcement/copy, `write_policy`, `min_write_version`, `shift_writes_enabled`, `legacy_writes_force_open`, `PAYDAY_WRITE_PROTOCOL_VERSION`, `check-protocol-version.sh`, `assert_write_allowed` + the per-RPC gating table, `retired_at`, `reject_frozen_legacy_write`, the freeze trigger, `legacy_writes_frozen_at`, the `payday.migrating` exemption, `drain_tip_entries`, drain-then-lock, the drain's sync leg, `legacyDrainedAt`, `legacyDrainMetFreeze`, `repository.drainTips`, `migration_receipts.drained_at`, `isLegacyWritesFrozen`, leg ordering, the four drain tests, `§4.3`'s `clientTooOld`, `§4.4`, every "please update" surface | **No lockout.** 1.0 is shipped with no handling for a rejected write, so no prompt it could show is reachable and there is no freeze to drain before. Two facts survive as knowledge: PostgREST maps `PTnnn` to HTTP `nnn`, and `CFBundleVersion` MDDYY+seq is not monotonic as an integer (`11032040 > 1152041`), so any build-number gate is wrong by construction. |
| `base §2` entire (device Migration 3 as a deriver) and its supports: the local derive pass, `Migration3Verification`, `Y-13`'s device assertion, `A-6`'s comparable-set scoping, `A-5` + `Y-12 pts 1/3` (the backup triple, fileExists probe, row-count window, no-space-is-fatal, the population-aware abort and three-strike escape), the 200-group batched save, `localClaimant`, `base §2.2 step 3`, `Migration3Receipt`, the `CloudProgressView` pass, `stampShiftMigrationComplete`, `shiftMigrationVerifiedAt`, `anAbortedMigrationLeavesZeroShiftRecords` | "The device never derives" deletes all of it, and nothing rewrites the local store destructively, so the backup has no subject. **Warning to keep:** if a device ever derives again, the N4 split divergence becomes a live money bug, because two derivers would write the same primary key continuously. |
| `base §0.3 corollary`, `base §0.2`, `§1.3`, `base §4 (T1-T14)` + the timeline gate | The id is now a persisted primary key, so "non-durable" and "agree on the partition, not the id" stay reversed. Mixed versions are the permanent correct state, not a window, so a 14-step walk becomes steady-state invariant tests. Downgrade is an ordinary path, measured in S1. |
| `Y-19` claims halves: `suppressed_legacy_cents`, `unresolved_divergence_cents`, `unresolved_divergence_count`, `A-8` | Sums over claims and unresolved divergences, of which there are none, and a user-resolved divergence has no producer. |
| The Swift/SQL id-equality merge gate as the money-loss tripwire, and its assertion in `BridgeParityTests` | With one deriver an id disagreement cannot double-count at runtime. The vectors survive as a never-edit gate. |
| `base §2.4`, `§8.3` union reader (`rows(fromLegacy: unclaimed(...))`), `§9.2` legs C and D, `§9.4 projectionFallback` | The dual-representation union is what produced the original P0s, and `unclaimed` has no definition without claims. What survives is narrower and provable: an exclusive shift leg, plus a legacy leg that additively reads native records whose `legacyEntryIDs` is **empty**, a set disjoint from every legacy row by construction (6.2). |
| `base §3.5`'s read-only view, "the server derives for reads only and never writes one", and `check (source in ('device','api'))` | False twice over. Replaced by the three-value CHECK and a third Swift case, which is a schema change, not a comment edit. |
| `cutover §11.2`'s `[ShiftRow]` overloads, `TipRecord.records(from:)` one-to-two expansion, `aShiftRowRoundTripsToTheSameShiftFacts` | Superseded by one row per kind; the apparatus existed only to work around a row carrying both cash and credit. |
| `cutover §8.1` (delete the tip pull leg) and its whole P0 family incl. `aBaselinePassWithLocalTipRowsAndNoRemoteTipsDoesNotThrow` | Dropping the change drops the bug. Both legs intact keeps the snapshot verification true and `tipEntryIDs` refreshed. |
| `cutover §10` (delete the four legacy write verbs, their 3 MCP entries, their router lines, the capability note, the `426` test) | A lockout argument. A write through them is now as correct as an old build's write, and deleting `restore_tip_entry` would hide the un-delete problem that arm 3 fixes. |
| `cutover §10`'s `CHANGE_TABLES` rewrite and `§10.3`'s cursor-discard instruction | `tip_entries` is still a legitimate change table, so `invalid_cursor` never fires for an existing cursor. |
| `base §5.4`'s DECISION "app-side, not a trigger", reasons 1 and 2 | Reason 1 is answered (both callers share one extracted deriver, so still two implementations, not three). Reason 2 is answered by md5-over-the-day-string plus pinned vectors. Reasons 3 and 4 were never answered and became 4.6 and 4.7. |
| `§6.2`'s "after the drain and before the shift pull" ordering | No drain to be after. |
| `A-3` / `Y-11` launch-sweep gating, `A-7`'s drain-dependent middle, `Y-12 pt 3`'s `legacyDrainedAt` grounding, `Y-12 pt 4`'s "above the floor", `CT-7`, `X-15`, `B-1 pt 3` client half, `X-18`'s group-key clause, `base §2.2 step 3` claimant arm | All hang off the drain, the floor, a device derivation or a claim. `Y-13`'s finding survives as 4.3's third producer and 9.1's residual hazard. |
| `plan line 97` ("idempotent on `legacy_entry_ids`") | Too weak in both ways that bite: concurrency (the lock) and late arrivals (the watermark). Weaker still with continuous arrival. |
| `plan lines 95-96` | 95's acceptance gate does not exist in the shipped RPCs and would recreate the slow-clock lockout; 96's grouping is zone-dependent and unreproducible in SQL. |
| `A-1` / `Y-5` positive server tombstones and replicated `ShiftTombstones` | They let a device decide from incomplete knowledge that sources are gone. The server has complete knowledge. Only "provenance survives a soft delete" remains. |
| `p_strict`, `derive_shifts`' third parameter, `payday_migration_conservation_failed`, and the raise on the RPC path | Unsatisfiable against 4.5 and 5.2 in this same document, *measured raising three times identically on the most ordinary sequence there is* (3.1). 4.6 rule 6's trade applies with more force to the new build than the old one. Conservation records, never raises, on both paths. |
| `ShiftDays.legacyShiftID(forWorkDate:)`, the Swift md5 port, `LegacyShiftIdentityTests`' zone and vector cases, `deterministicShiftID`'s `@available(*, deprecated)` | 6.4 keeps minting generation 0, because every shipped 1.0 build does and `upsert_tip_entries` rewrites `shift_id` unconditionally, so a generation change would flip a day's group key on every pass between two devices. With no Swift mint of the md5 form there is no Swift consumer, and the vectors are pinned in SQL and Deno only. |
| The claim that the gratuity `CASE` must be written twice, and the four hand-written copies it grew into | *Measured:* an `immutable` user function is legal inside a stored generated column. One `private.receipt_gratuity_cents`, read by both generated columns, the deriver, the sanitizer and the conservation check. |
| `where public.shifts.user_id = v_uid` on arm 1's `do update`, and the "refuse every `ShiftCommands` write on the legacy leg" rule | The first was dead code preserving the exact shape of the measured `INSERT 0 0` no-op in the one statement that runs inside a 1.0 transaction. The second was shape 2's dark app arriving through the write path; 6.2's disjoint additive read removes the need for it. |

### 14.3 The three decisions this document closes

1. **Precedence on a conflicting legacy write:** 4.5, shift-wins-when-natively-touched, legacy write recorded. Legacy-wins would make `ShiftCommands.update` a lie.
2. **Cascade from a shift deletion to legacy rows:** 8.4, no cascade in general, one narrow device-side cascade inside `ShiftCommands.delete`, self-consistent via arm 2 plus 4.5.
3. **The read asymmetry** (1.6, 12.3): a natively authored shift never appears in `tip_entries`, so a 1.0 device on the same account shows a subset of the history. The alternative is a legacy shadow write per native shift, which is a second writer and reopens shape 1. **This one is Tyler's to accept in words**, not to discover later.

---

## 15. Skeptic findings resolved

39 findings against revision 1 of this document. One line each: the claim, then the disposition. Sections named are where the fix now lives. Grouped by severity **after** verification, which merges two findings whose fix is one change (the companion count and the re-invoke loop, item 12) and splits one whose two halves land in different places (the write arms, items 33 and 39).

Nothing here is a to-do. Every item below is already folded into the section named; this list exists so the next reviewer can tell a resolved finding from an unexamined one, and so the six places the skeptic was wrong do not get "fixed" back.

### P0

1. **Conservation was unsatisfiable against 4.5 and 5.2; `migrate_tip_entries_to_shifts` raised identically on every run.** CONFIRMED, reproduced three times. Fixed three ways: `p_strict` deleted and conservation now records on both paths (3.1, 4.6 rule 6, 5.3); closed shifts excluded from both sides of the comparison (5.3); `unmigrated` made to terminate by arm 2a (4.4, 5.2). The skeptic's alternative fix — `and s.native_modified_at is null` in the `named` CTE — was **rejected**: it would blind the count to a live row still inside a closed shift's group, which is a real unmigrated row. Releasing provenance is the correct place.
2. **`exception when others` does not catch `57014 query_canceled`, so the one abort class 1.4 names is the one the handler cannot trap.** CONFIRMED and independently re-measured, including in the exact trigger shape: with a `when query_canceled` arm the 1.0-shaped INSERT returns `INSERT 0 1`, the legacy row commits, one failure row lands, and the backlog gets the key. Named arms for `query_canceled` and `assert_failure` added, plus the measured fact that catching 57014 does **not** re-arm the timer, so the handler does two bounded inserts and returns (4.6 rule 1, 1.4).
3. **4.7 cited a blocking-lock measurement as evidence for the non-blocking rule, and 4.9's "over-count, never an under-count" was false.** CONFIRMED. Both variants now printed side by side in 4.7 with the `pg_try_` result (`credit 0`, 1 backlog row) as the shipping one; 4.9 corrected to admit under-counts; the three things that contain it (6.3 predicate 2, the backlog in the count, the explicit drain step) named.
4. **Arm 2's `shift_is_open_to_fold` gate stranded provenance on a closed shift, doubling a night onto two dates and wedging `v_dupes` and the count forever.** CONFIRMED. Arm 2 split into 2a (provenance, unconditional) and 2b (money, gated) with the full failing sequence written out (4.4). This is the single highest-leverage fix in the round: it also closed findings 1, 27 and half of 9.1's residual hazard.
5. **`gratuity_fees_cents`' generated expression had a lower clamp only, so a hallucinated receipt magnitude aborted arm 1 with `22003` inside a 1.0 transaction, violating 4.6 rule 4.** CONFIRMED. Fixed in 2.3 — but **the skeptic's proposed fix does not work**, measured twice: `least(2147483647, greatest(0, (...)::numeric::integer))` still aborts, because the inner `::integer` cast runs before any clamp; and clamping the gratuity alone still aborts, because `non_wage_earnings_cents` sums three `int4` values (`cash 2147483000 + gratuity 2000000` overflows with every input in range). Both expressions now clamp in **`numeric`** space, and the whole sum is clamped at both ends. Measured: `99999999999`, `1e30`, `-500`, `1234.6`, `true`, `"hi"` and the in-range overflow all insert.
6. **The shift delta cursor advances past a fold committed by a long 1.0 transaction, because `touch_shift_row` writes `now()` (transaction time) and the cursor keys on pulled `updated_at`.** CONFIRMED against `PaydaySyncState.swift:19-34`. Fixed with a 300-second safety-window clamp against a server-returned `serverNow` (7.7), plus the three reasons this is fatal on the shift leg and survivable on the tip leg. Deliberately **not** applied to the tip cursor in PR 2.
7. **`awaitingAccountConversion` as a `Phase` stops all syncing, because `syncIfReady` opens `guard case .ready = phase`.** CONFIRMED at `PaydayCloudGate.swift:215` and `:526-535`. It becomes a non-blocking sub-state plus a banner; steps 1-5 and 10-12 run; `anUnfinishedConversionStillFlushesAPendingTipDeletion` added (7.9).
8. **The exception path recorded the failure and returned without queueing the keys, so a caught abort was unrecoverable; and `private.write_shifts` never took the advisory lock, leaving a reachable `40P01`.** CONFIRMED. Queueing added to every handler arm (4.6 rule 1); `private.write_shifts` takes the blocking lock so all three writers serialize per account and the deadlock shape is unrepresentable (4.7, 5.7, S6); `57014` and `40P01` added to the S-gate as their own measured cases.
9. **The one-shot had no budget, no batching and no partial commit, so a long history could never make forward progress.** CONFIRMED. `p_max_groups`, `remaining_group_count`, per-invocation commit and the backlog delete added (5.1), with the client looping across passes on a strictly decreasing count (5.6).
10. **`synchronize`'s `restoredTipIDs` arm cancels and persists-as-cancelled any pending tip deletion whose local row still exists, so `ShiftCommands.delete`'s legacy cascade would never issue one `soft_delete_tip_entries` call.** CONFIRMED at `PaydaySyncService.swift:304-315`, and the reason it works today is that the shipped delete paths hard-delete the local rows in the same breath. The legacy deletion queue gets its own storage key that the restore-cancel arm does not touch (8.4 item 1), and the `@available` message's contradictory "its own private storage" wording is corrected.
11. **10.1 stated the projection rule twice, incompatibly, and either reading loses money or breaks the CSV.** CONFIRMED. The rule is now stated completely in three numbered clauses matching `ShiftWriter` plus `ShiftDetails`, including `note` and `recordedAt` on every emitted row (which is what keeps `CSVExporter.swift:37` byte-identical), plus fixture N6 as a zero-delta case in 11.3.
12. **`payday_unmigrated_tip_row_count()` and the 5.2 predicate return different answers, and the re-invoke loop was unbounded.** CONFIRMED, 0 versus 1 in the same fixture state. The count is now literally the predicate plus the backlog, one shared expression (5.6); the client calls the one-shot at most once per pass, gated on a strictly decreasing `remaining_group_count`, which also kills the hot loop inside `while outcome.requiresFollowUpSync`.
13. **`autosaveEnabled = false` in S1 loses every SwiftUI write until S9 lands, and `PaycheckEntrySheet` was in no slice at all.** CONFIRMED: zero matches for `autosaveEnabled` in the tree, and `PaycheckEntrySheet.save`/`.delete` never call `save()`. The flag moves to S9 with `PaycheckEntrySheet.swift` and `BackfillSheet.swift` and explicit saves (8.2, S1, S9). Note the real path is `Payday/Views/Periods/PaycheckEntrySheet.swift`, not `Views/Shared/`.
14. **The write gate made the app read-only on the legacy leg, which is shape 2's dark app arriving through the write path, with no bound and no escape.** CONFIRMED, and the most important judgement call in the round. 6.2 now reads the legacy leg **additively** over native records whose `legacyEntryIDs` is empty — disjoint by construction, asserted as an invariant, not reviewed — and 8.7 narrows the refusal to `update`/`delete` of an unconfirmed folded record. `create` works offline on first launch again.

### P1

15. **`metrics_rank` ranked on `is not null`, so a non-object payload could own the gratuity while an object payload was stored, inventing $42 and breaking Swift parity.** CONFIRMED and re-measured: 11200 versus the correct 7000. Ranking is now object-first (3.2) with the numbers in a table and fixture N5 added. **The skeptic's second instruction — drop the `filter (where jsonb_typeof(...) = 'object')` — is rejected:** with no object payload anywhere in the group the unfiltered aggregate would store a scalar into `shifts.receipt_metrics` and violate `shifts_receipt_is_object`. The filter stays.
16. **`unconverted_legacy_cents = greatest(0, ...)` cannot represent a downward correction and forgets earlier ones.** CONFIRMED, measured across three arrivals. Redefined as `abs(...)` meaning "latest disagreement magnitude", never accumulated, with the account-wide money figure derived from `shift_legacy_conflicts` instead (4.4, 5.4).
17. **"Spend any leftover budget draining the backlog" yields zero leftover at `batchSize = 500`, and nothing said who deletes a drained row.** CONFIRMED, measured at 500 rows / 250 groups / 0 drained twice in a row. Budget split 40/10 with the drain **reserved**, and the delete rule written out (4.7).
18. **`soft_delete_tip_entries`' `p_deleted_at >= client_updated_at` guard can write nothing while the client clears the whole queue unconditionally; and Undo after the flush had no way back.** CONFIRMED at `20260831165043:167` and `PaydaySyncService.swift:457`. The flush now reads the return set and keeps unwritten ids queued on a backoff; Undo re-pushes through `upsert_tip_entries`, which un-deletes with no new RPC (8.4 items 2 and 3, 8.5 piece 4). **The skeptic's "clamp `p_deleted_at` server-side" is rejected:** `least(p_deleted_at, statement_timestamp())` only lowers the value and makes the guard fail *more* often for the device that is behind. The skew is bounded, so retrying converges.
19. **Switching `backfillShiftIDs` to the md5 generation re-keys a day on every pass while any 1.0 build mints generation 0.** CONFIRMED against `ShiftDays.swift:105`, `MigrationRunner.swift:13` and `20260904134500:138`. Generation stays 0, the determinism fix is kept and decoupled (6.4) — and the consequence is a simplification the skeptic did not claim: the Swift md5 port loses its last consumer and is deleted (2.6, 1.5, 14.2).
20. **4.9's over-count freezes rather than converging if the user edits mid-window.** CONFIRMED. Named explicitly in 4.9 with the exit being 4.5's `[Keep mine]` / `[Use theirs]` action. **The skeptic's recommended fix — reorder steps 1 and 3 — is rejected:** flushing deletions first merely turns the over-count into an under-count, and a user editing a too-low night freezes it just as hard. Making the conflict row actionable is the general answer to every "recorded and surfaced" path in 4.5.
21. **Two concurrent losers of the try-lock insert the same backlog key: one blocks on the other, then raises `23505`.** CONFIRMED. `on conflict (user_id, group_key) do nothing`, in sorted key order, plus a `queued_at` index (4.7).
22. **`private.shift_fold_backlog` and `private.shift_fold_failures` carry `user_id` with no foreign key, so they survive account deletion and `shift_fold_failures.message` retains receipt values.** CONFIRMED against the `20260911150000` header invariant. FKs added to both, all five new tables named in the inventory comment, and the `delete_my_account` test extended (2.7, S2).
23. **The `PendingDeletions` fixture is object-shaped, but `[UUID: Date]` encodes as a flat array, so the test fails against a correct decoder and invites a worker to change the storage shape.** CONFIRMED and re-measured: `{"tipEntries":["1111…",0],"paychecks":[]}`, and the draft's literal throws `typeMismatch ... Path: tipEntries`. The fixture is now generated by encoding rather than hand-written, with the wire-shape note (7.2). The section's premise about the synthesized decoder is verified correct.
24. **12.2 resets a `MigrationRunner` version 3 that does not exist and is unreachable.** CONFIRMED: `currentVersion` is 2 and `versionKey` is `private static let`. Sentence deleted; clearing `shiftsAreAuthoritativeAt` is the mechanism, and local `ShiftRecord`s and `ShiftTombstone`s are cleared too (12.2).
25. **`dump shifts where converted_at < client_updated_at` drops exactly the edited shifts that later received a legacy write, because arm 1 stamps `converted_at` unconditionally.** CONFIRMED. Both the dump and `edited_since_conversion_count` move to `native_modified_at is not null` (12.3, 5.4).
26. **A per-account `rollback_shift_migration(p_user_id)` disables the triggers globally, leaving every other converted account reading `shifts` with nothing folding on arrival.** CONFIRMED, and the draft named the global-disable fact while drawing the opposite conclusion. The unsafe operation is no longer expressible: no-argument rollback stamping every row, a separate per-account repair, plus the ACCESS EXCLUSIVE and re-enable facts in the comment (12.2).
27. **7.7's placement sentence contradicts 7.5's numbered order and would reintroduce `paycheckMismatch` and the settings clobber; and the stated cost of a throw is wrong for `.ready`.** CONFIRMED both halves. Placement restated to match 7.5; the `.ready` cost restated as a silently stalled checkpoint with backoff, the `migrate` path as a full-screen `.failed` (7.7).
28. **`locallyChangedBeforeSync` implemented inside `reconcileShifts` would discard the step-9 readback for the same ids, making a divergence permanent and unpushable.** CONFIRMED against the `merged` shape at `PaydaySyncService.swift:385-386` and the ack at `:484-490`. The exclusion is now explicitly pull-only, with the two-call split and `aServerClampedClientUpdatedAtOnAJustPushedShiftIsAdopted` (7.5).
29. **`LogTipsIntent` and the widget have no `PaydayCloudState`, so they cannot honour a view-layer write gate.** CONFIRMED at `LogTipsIntent.swift:121`. The authority fact moves into `PaydaySyncState.shiftsAreAuthoritative(for:)` and `ShiftCommands` itself refuses with an `IntentDialog` (8.6). Largely defused anyway by finding 14: the ordinary Siri log is now allowed.
30. **The widget target's sources are enumerated file by file and do not include `PaydaySyncState.swift`, and no slice touched `project.yml`.** CONFIRMED at `project.yml:102-136`; `AppGroup.swift` **is** there (`:123`), which is exactly the trap. `project.yml` added to S9 with the four files, one lint-pinned accessor, and 11.2's `widgetEntryCents` routed through the imperative projection (6.2, S9).
31. **`grant select, insert, update` on `public.shifts` defeats 4.5's `native_modified_at` invariant and 12.2's rollback query.** CONFIRMED. Select only; the insert and update policies are dropped; `an_authenticated_direct_insert_into_shifts_is_denied` added (2.7, S2).
32. **S10's gate cannot be demonstrated, because S9 has already deleted or replaced all the call sites it claims will break.** CONFIRMED: five call sites exist, and S9 touches every one. The five become S9's acceptance list and S10's gate becomes the `design-lint.sh` reference count (8.4, S9, S10).

### P2

33. **The four write arms reference a CTE with no stated sharing mechanism, giving four copies of the gratuity rule and four snapshots.** Accepted as a specification gap a worker cannot close safely. `grouped` is materialized once into a `jsonb` local read by all four arms and the conservation check (4.4, 2.4). The skeptic's parenthetical that generated columns "cannot call" an `immutable` helper is **wrong** — *measured:* they can — so the fix is stronger than proposed: `private.receipt_gratuity_cents` is the single implementation and 2.3's "written twice on purpose" is deleted.
34. **`::numeric::integer` rounds, it does not truncate.** CONFIRMED and re-measured: `1234.6` to 1235, `1234.5` to 1235, `1234.4` to 1234. Sentence corrected, and the fold now sanitizes `gratuityFeesCents` through the same helper so the stored payload stays `Int`-decodable on device (3.4, 2.5) — which is the real consequence, since otherwise `ShiftReceiptMetrics.swift:53` fails to decode and the shift becomes permanently uneditable.
35. **`payday.folding` is set transaction-local and never cleared, so any later shift UPDATE in that transaction silently stops bumping `version`.** Accepted as latent and verified unreachable in PR 2 (every native write path is its own PostgREST request; the fold never writes `tip_entries`). Cleared before every return including the handler, with `aNativeShiftWriteAfterAFoldInTheSameTransactionStillBumpsVersion` shipping now because PR 6 adds agent shift writes (2.7, S3).
36. **`where public.shifts.user_id = v_uid` on arm 1's `do update` is dead code preserving the shape of the measured `INSERT 0 0` no-op.** CONFIRMED. Deleted, replaced by a comment, and `design-lint.sh` bans `on conflict` combined with `where` on `public.shifts` (4.4, S1).
37. **"BOTH shipped `tip_entries` indexes are partial" — there are three, and the third is not partial.** CONFIRMED at `20260831164348:49-57`. Reworded to name all three and say why the non-partial one cannot serve a group lookup (2.7).
38. **The write gate has no bound on how long the app stays read-only.** Same defect as finding 14, correctly rated higher there. Resolved by 6.2's additive leg; `aPermanentlyUnfoldableGroupDoesNotMakeTheAppReadOnly` is in the S13 gate.
39. **`grouped`'s isolation across arms is undefined at READ COMMITTED.** Folded into 33: one evaluation, one snapshot, stated as normative in 4.4 and in the 2.4 comment block.
