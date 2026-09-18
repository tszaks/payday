-- PR 2, slice S2: the shift representation, schema only.
--
-- The SERVER converts. A later slice adds private.derive_shifts (the single
-- deriver) and the on-arrival trigger on public.tip_entries that folds every
-- incoming legacy write into this representation in the same transaction.
-- This migration is the schema those two stand on and nothing else: no
-- deriver, no trigger on tip_entries, no write RPCs.
--
-- public.tip_entries stays the legacy write surface indefinitely and every
-- shipped 1.0 build keeps working untouched. Nothing here may ever fail an
-- old build's write, which is why every money value that a converted row can
-- carry is clamped in `numeric` space instead of being validated by a CHECK.

-- ---------------------------------------------------------------------------
-- The gratuity rule, ONE implementation in SQL. Read by both generated
-- columns, by the deriver's arithmetic and by the fold's sanitizer.
-- ---------------------------------------------------------------------------

create or replace function private.receipt_gratuity_cents(p jsonb)
returns integer language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p -> 'gratuityFeesCents') = 'number'
              then least(2147483647::numeric,
                     greatest(0::numeric, (p ->> 'gratuityFeesCents')::numeric))::integer
              else 0 end;
$$;

comment on function private.receipt_gratuity_cents(jsonb) is
  'The gratuity rule. Read by two STORED generated columns, so CREATE OR '
  'REPLACE here silently changes the rule WITHOUT recomputing any stored '
  'row (measured: the replace succeeds and existing values are untouched). '
  'It may not be edited. Changing it requires a migration that also '
  'rewrites every public.shifts row.';

-- ---------------------------------------------------------------------------
-- Identity. One caller: private.legacy_group_key.
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- public.shifts
--
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
-- ---------------------------------------------------------------------------

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

comment on table public.shifts is
  'One row per shift. Read-authoritative once an account''s conversion is '
  'verified; written only by the definer RPCs and by private.derive_shifts.';
comment on column public.shifts.non_wage_earnings_cents is
  'cash + credit + gratuity - tip_out, computed and clamped in numeric space. '
  'Deliberately has NO non-negativity check: a tip-out larger than the '
  'night''s tips is real and already representable.';
comment on column public.shifts.source is
  'device | api | migration. ''migration'' plus legacy_entry_ids is the only '
  'safe rollback query, so a conversion artifact must never be written '
  'as ''device''.';
comment on column public.shifts.unconverted_legacy_cents is
  'The MAGNITUDE of the latest disagreement between this shift and its legacy '
  'sources (abs, never accumulated). Not "unconverted money": the honest '
  'account-wide figure is derived from public.shift_legacy_conflicts.';
comment on column public.shifts.agent_idempotency_key is
  'Server-only by convention: the sync client''s column list never names it, '
  'exactly as for public.tip_entries.';

-- ---------------------------------------------------------------------------
-- RLS, grants, indexes
-- ---------------------------------------------------------------------------

alter table public.shifts enable row level security;
create policy shifts_select_own on public.shifts for select to authenticated
  using ((select auth.uid()) = user_id);
-- SELECT ONLY. No insert, update or delete policy and no such grant: every
-- client write goes through the definer RPCs, so a direct grant is
-- unnecessary AND it would defeat three invariants the rest of this design
-- rests on -- "native_modified_at is written by private.write_shifts and by
-- nothing else", "source plus legacy_entry_ids is the only safe rollback
-- query", and private.shift_is_open_to_fold's meaning. With insert/update
-- granted, a session could set source, legacy_entry_ids, deleted_reason or
-- native_modified_at on its own rows and make rollback tombstone a shift the
-- user authored, spare a conversion artifact, or reopen a closed shift to
-- the fold.
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

-- ---------------------------------------------------------------------------
-- The version trigger. public.shifts must NOT reuse
-- private.touch_versioned_row(), which increments `version` on every UPDATE:
-- the agent API mutates with .eq("version", expected_version), so a fold
-- fired by an unrelated 1.0 write would return a 409 for something the agent
-- did nothing wrong on.
-- ---------------------------------------------------------------------------

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

comment on function private.touch_shift_row() is
  'payday.folding is set transaction-local by private.derive_shifts and by '
  'nothing else, and cleared by it immediately before every return including '
  'inside its exception handler. A GUC set and never reset is invisible at '
  'the call site that breaks: the first function that folds a legacy row and '
  'then updates a shift in one transaction would silently stop bumping '
  'version, turning the agent''s .eq("version", expected_version) guard into '
  'a no-op instead of a 409.';

create trigger shifts_touch_version before update on public.shifts
for each row execute function private.touch_shift_row();

-- ---------------------------------------------------------------------------
-- The group key. The key is a pure function of ONE row and never adopts a
-- sibling's stored id, which is what makes the fold's result independent of
-- which rows are visible in a given transaction.
-- ---------------------------------------------------------------------------

create or replace function private.legacy_group_key(p_shift_id uuid, p_work_date date)
returns uuid language sql immutable set search_path = '' as $$
  select coalesce(p_shift_id, public.payday_legacy_shift_id(p_work_date));
$$;

-- ---------------------------------------------------------------------------
-- The audit row. One per account, written only by the definer functions.
-- ---------------------------------------------------------------------------

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
  unconverted_legacy_cents bigint,   -- derived from shift_legacy_conflicts
  conservation_failed_at timestamptz, bulk_legacy_rewrite_at timestamptz,
  last_legacy_write_at timestamptz, last_run_at timestamptz, rollback_at timestamptz);

comment on table public.shift_migration_state is
  'The only account-level conversion record and rollback''s only anchor. NOT '
  'migration_receipts, which is keyed (user_id, device_id) and means "this '
  'device verified its own upload".';
comment on column public.shift_migration_state.migrated_at is
  'The FIRST conversion instant. Never moved by a re-run (measured: a second '
  'no-op call moved it), so it is written through an explicit CASE.';
comment on column public.shift_migration_state.last_legacy_write_at is
  'The one fact that could ever end the transition: whether any 1.0 build is '
  'still writing tip_entries.';
comment on column public.shift_migration_state.remaining_group_count is
  'Progress as a number. The client re-invokes the one-shot only while this '
  'strictly decreases, which is what stops a hot loop of definer calls.';

alter table public.shift_migration_state enable row level security;
create policy sms_read_own on public.shift_migration_state for select to authenticated
  using ((select auth.uid()) = user_id);
revoke all on table public.shift_migration_state from anon, authenticated;
grant select on table public.shift_migration_state to authenticated;
-- No write grant: only the definer functions write it.

-- ---------------------------------------------------------------------------
-- The conflict record: append-only, low volume, informational. The device
-- only renders it. NOT the deleted ShiftDivergence: no resolve behaviour, no
-- Kind cases, no store.
-- ---------------------------------------------------------------------------

create table public.shift_legacy_conflicts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  shift_id uuid not null,
  detected_at timestamptz not null default now(),
  shift_cents_before integer not null,
  legacy_cents_after integer not null);
create index shift_legacy_conflicts_user_idx
  on public.shift_legacy_conflicts (user_id, detected_at desc);

comment on table public.shift_legacy_conflicts is
  'One row per legacy arrival whose money a CLOSED shift declined. Rendered '
  'in Data health with [Keep mine] / [Use theirs]; [Use theirs] is an '
  'ordinary native write, so the shift stays closed and nothing refolds. '
  'No composite FK to public.shifts on purpose: arm 4 of the fold inserts '
  'here inside a shipped 1.0 build''s transaction, and the fold may never '
  'raise, so it takes no constraint it does not need.';

alter table public.shift_legacy_conflicts enable row level security;
create policy shift_legacy_conflicts_select_own on public.shift_legacy_conflicts
  for select to authenticated using ((select auth.uid()) = user_id);
revoke all on table public.shift_legacy_conflicts from anon, authenticated;
grant select on table public.shift_legacy_conflicts to authenticated;
-- SELECT ONLY, same reasoning as public.shifts: the device renders these rows
-- and writes none of them. Supabase's default privileges on schema public
-- grant ALL on a new table to anon and authenticated, so without this revoke
-- every account could read and rewrite every other account's conflicts.
revoke all on sequence public.shift_legacy_conflicts_id_seq
  from public, anon, authenticated;
-- The table and its identity sequence are two separate objects, and
-- `alter default privileges in schema public grant all on sequences` covers
-- the second one too, so the table revoke above does not reach it. Measured
-- on PG 17.11 with this migration unpatched: the sequence carried
-- `anon=rwU/postgres,authenticated=rwU/postgres`, `set local role anon;
-- select last_value from public.shift_legacy_conflicts_id_seq` returned
-- 00000 with a global cross-tenant conflict count, and `w` is the setval
-- primitive -- `set local role authenticated; select setval(..., 1, false)`
-- returned 00000, after which arm 4's definer-shaped insert raised 23505 on
-- every retry. 4.6's `when others` arm swallows that, so no 1.0 write is
-- rejected, but the group is recorded as a failure, queued to the backlog
-- and never converted, for every account, permanently. Same treatment and
-- same reason as 20260831173136_payday_agent_api.sql:93, the only other
-- `generated always as identity` table in the schema. No service_role grant:
-- arm 4 is security definer and runs as owner, and no service-role path
-- inserts conflicts directly. private.shift_fold_failures needs no such
-- revoke -- schema private has no usage grant, so the schema-public default
-- privileges never reach its sequence (verified: schema public holds exactly
-- two sequences).

-- ---------------------------------------------------------------------------
-- The fold's two private tables. Both carry a cascading user_id FK: a foreign
-- key does not require the table to be reachable by `authenticated`, and
-- without it these rows survive account deletion -- shift_fold_failures.message
-- holds SQLERRM text that for 22P02 and 22003 embeds the offending value out
-- of the user's receipt payload.
-- ---------------------------------------------------------------------------

create table private.shift_fold_backlog (
  user_id uuid not null references auth.users(id) on delete cascade,
  group_key uuid not null,
  queued_at timestamptz not null default now(),
  primary key (user_id, group_key));
create index shift_fold_backlog_queued_idx
  on private.shift_fold_backlog (user_id, queued_at);

comment on table private.shift_fold_backlog is
  'Group keys a statement could not afford (beyond the reserved 40) or lost '
  'the try-lock on. Every insert is `on conflict (user_id, group_key) do '
  'nothing`, in sorted key order: without both, two concurrent 1.0 writes '
  'that miss the try-lock block on each other''s uncommitted index entry and '
  'then raise 23505. Drained by any later legacy write (reserved 10 per '
  'statement), by a new-build sync, or by service_role. No cron.';

create table private.shift_fold_failures (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  group_keys uuid[] not null,
  sqlstate text not null, message text not null,
  at timestamptz not null default now());

comment on table private.shift_fold_failures is
  'Every abort the fold swallowed. The fold never raises: it records here, '
  'queues the same keys into private.shift_fold_backlog, and returns. '
  'query_canceled (57014, what statement_timeout raises) and assert_failure '
  'are NOT caught by `when others` and need their own arms.';
