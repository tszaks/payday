-- PR 2, slice S4: tests for private.fold_legacy_writes(), the on-arrival trigger.
--
-- Same convention as the other two SQL suites: a plain psql script, every
-- assertion lands in a temporary results table, and the last statement raises
-- if any row is false, which makes psql exit non-zero under -v ON_ERROR_STOP=1.
--
-- CI (job E, "Supabase migrations (db reset)"), after `supabase db reset --local`:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/shift_fold_test.sql
--
-- Locally with no Docker: `bash scripts/db-test-local.sh`.
--
-- EVERY write to public.tip_entries in this suite goes through the SHIPPED 1.0
-- surfaces -- public.upsert_tip_entries and public.soft_delete_tip_entries, as
-- the authenticated role with a JWT claim -- or through a service-role direct
-- table write, which is what the agent API does. Nothing here inserts into
-- tip_entries as the owner, because the point of the slice is what happens
-- inside a shipped 1.0 build's own transaction.
--
-- ONE STRUCTURAL RULE, PAID FOR: a mutation and its assertion are NEVER in the
-- same statement. A single SELECT has ONE snapshot, so an inline subquery
-- reading a table that a volatile function mutated EARLIER IN THE SAME
-- STATEMENT still sees the pre-statement value. Measured here: the first draft
-- of this file wrote the fold and then counted shift_legacy_conflicts in one
-- statement and read 0 every time; worse,
-- `lastLegacyWriteAtIsStampedAtMostHourly` PASSED off the stale snapshot while
-- the opposite assertion on the next line failed. A false pass on a
-- money-adjacent counter is why this rule is written down. So: mutate in one
-- statement, capturing the RPC's own return value into `calls`, and assert in
-- the next.
--
-- WHAT IS NOT IN HERE. Five facts need two concurrent sessions, which a single
-- psql script cannot produce: the try-lock race, the blocking-lock variant,
-- the loser's non-blocking-ness, the concurrent duplicate backlog insert, and
-- the 40P01 deadlock row of the S-gate. Those live in scripts/db-test-race.sh,
-- which drives real psql processes and is its own CI step. Neither file skips a
-- gate item; they split the gate by what one session can observe.

\set ON_ERROR_STOP on
\timing off
\pset pager off

create temporary table results (
  seq serial primary key, name text not null, ok boolean not null, detail text not null default '');

-- What a 1.0-shaped RPC returned, recorded by the mutating statement so the
-- assertion in the NEXT statement can read it.
create temporary table calls (name text primary key, n integer);

create function pg_temp.expect(p_name text, p_ok boolean, p_detail text default '')
returns void language sql as $$
  insert into results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail);
$$;

create function pg_temp.called(p_name text) returns integer language sql as $$
  select n from calls where name = p_name;
$$;

-- Runs one statement and reports what it raised: '00000' when it succeeded.
create function pg_temp.outcome_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return '00000';
exception when others then
  return sqlstate;
end;
$$;

-- A 1.0-SHAPED WRITE. The authenticated role, a JWT claim, and the shipped
-- public.upsert_tip_entries.
--
-- SET LOCAL and set_config(..., is_local => true) revert at the end of the
-- enclosing implicit transaction, i.e. at the end of the one top-level
-- statement that calls this, so the next statement is back to postgres with no
-- test GUC. `reset role` before returning is still required: SET LOCAL outlives
-- the FUNCTION, so without it the calling statement would continue as
-- `authenticated` and could not write a temporary table (measured:
-- "permission denied for table results").
--
-- p_test is the only way to reach the fold's two forced-abort hooks. A
-- p_timeout parameter is deliberately absent: a statement_timeout set INSIDE a
-- running statement does not re-arm a timer that started with the outer
-- statement, so the 57014 case sets the timeout as its own top-level
-- statement, below.
create function pg_temp.device_upsert(p_user uuid, p_rows jsonb, p_test text default '')
returns integer language plpgsql as $$
declare n integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user)::text, true);
  if p_test <> '' then
    perform set_config('payday.fold_test_abort', p_test, true);
  end if;
  set local role authenticated;
  select count(*) into n from public.upsert_tip_entries(p_rows);
  reset role;
  return n;
end;
$$;

-- The same shape, returning the elapsed wall-clock milliseconds of the whole
-- RPC including the fold, for the work-budget measurement.
create function pg_temp.device_upsert_ms(p_user uuid, p_rows jsonb)
returns numeric language plpgsql as $$
declare t0 timestamptz; t1 timestamptz; n integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user)::text, true);
  set local role authenticated;
  t0 := clock_timestamp();
  select count(*) into n from public.upsert_tip_entries(p_rows);
  t1 := clock_timestamp();
  reset role;
  return round(extract(epoch from (t1 - t0))::numeric * 1000, 1);
end;
$$;

-- The shipped soft delete: the 1.0 deletion path, and the one narrow exception
-- where the new build writes tip_entries (ShiftCommands.delete).
create function pg_temp.device_delete(p_user uuid, p_ids uuid[], p_at timestamptz default now())
returns integer language plpgsql as $$
declare n integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user)::text, true);
  set local role authenticated;
  select count(*) into n from public.soft_delete_tip_entries(p_ids, p_at);
  reset role;
  return n;
end;
$$;

-- A service-role direct table write: no RLS, no auth.uid(), exactly what
-- ctx.admin.from("tip_entries").insert(payload) does in the agent API.
create function pg_temp.service_write(p_sql text) returns void language plpgsql as $$
begin
  set local role service_role;
  execute p_sql;
  reset role;
end;
$$;

-- One group's shift row as a jsonb blob, so an assertion can name several
-- columns at once and report all of them when it fails.
create function pg_temp.shift_facts(p_user uuid, p_key uuid) returns jsonb
language sql as $$
  select coalesce(
    (select to_jsonb(x) from (
       select s.work_date, s.cash_tips_cents, s.credit_tips_cents, s.tip_out_cents,
              s.hours_worked, s.gratuity_fees_cents, s.non_wage_earnings_cents,
              s.receipt_metrics, s.source, s.legacy_entry_ids,
              coalesce(array_length(s.legacy_entry_ids, 1), 0) as prov,
              s.deleted_at is not null as is_deleted, s.deleted_reason,
              s.unconverted_legacy_cents, s.version, s.derived_version,
              s.native_modified_at is not null as is_closed,
              s.converted_at is not null as converted
       from public.shifts s where s.user_id = p_user and s.id = p_key) x),
    'null'::jsonb);
$$;

create function pg_temp.conflicts(p_user uuid, p_shift uuid) returns text language sql as $$
  select coalesce(string_agg(shift_cents_before || '->' || legacy_cents_after, ' ' order by id), '')
  from public.shift_legacy_conflicts where user_id = p_user and shift_id = p_shift;
$$;

create function pg_temp.backlog_keys(p_user uuid) returns uuid[] language sql as $$
  select coalesce(array_agg(group_key order by group_key), '{}'::uuid[])
  from private.shift_fold_backlog where user_id = p_user;
$$;

create function pg_temp.failures(p_user uuid) returns text language sql as $$
  select coalesce(string_agg(sqlstate || ' [' || left(message, 60) || ']', ' | ' order by id), '')
  from private.shift_fold_failures where user_id = p_user;
$$;

-- 500 rows over N groups, in the shape PaydayRemoteRepository sends
-- (batchSize = 500): two rows per group, one cash and one credit.
create function pg_temp.batch_rows(p_seed integer, p_groups integer)
returns jsonb language sql as $$
  select jsonb_agg(r order by r ->> 'id')
  from (
    select jsonb_build_object(
      'id', ('53000000-0000-4000-8000-' || lpad((p_seed * 100000 + g * 10 + k)::text, 12, '0'))::uuid,
      'shift_id', ('53000000-0000-4000-9000-' || lpad((p_seed * 100000 + g)::text, 12, '0'))::uuid,
      'work_date', (date '2026-01-01' + g)::text,
      'amount_cents', 1000 + g,
      'kind', case k when 0 then 'cash' else 'credit' end,
      'client_updated_at', '2026-06-01T00:00:00Z') as r
    from generate_series(1, p_groups) g, generate_series(0, 1) k
  ) x;
$$;

-- Fixture accounts -----------------------------------------------------------

delete from auth.users where id in (
  '53000000-0000-4000-8000-000000000001',
  '53000000-0000-4000-8000-000000000002',
  '53000000-0000-4000-8000-000000000003',
  '53000000-0000-4000-8000-000000000004',
  '53000000-0000-4000-8000-000000000005',
  '53000000-0000-4000-8000-000000000006');
insert into auth.users (id, email) values
  ('53000000-0000-4000-8000-000000000001', 'payday-s4-arms@test.invalid'),
  ('53000000-0000-4000-8000-000000000002', 'payday-s4-aborts@test.invalid'),
  ('53000000-0000-4000-8000-000000000003', 'payday-s4-budget@test.invalid'),
  ('53000000-0000-4000-8000-000000000004', 'payday-s4-deletion@test.invalid'),
  ('53000000-0000-4000-8000-000000000005', 'payday-s4-agent-a@test.invalid'),
  ('53000000-0000-4000-8000-000000000006', 'payday-s4-agent-b@test.invalid');

-- =============================================================================
-- 1. The triggers exist in the one shape that works
-- =============================================================================

-- `after insert or update ... referencing new table as nt for each statement`
-- fails with "transition tables cannot be specified for triggers with more
-- than one event", and an OLD TABLE is invalid for INSERT. So: three triggers,
-- one function, AFTER (never BEFORE, so tip_entries_touch_version is
-- undisturbed), STATEMENT-level (a per-row trigger folds the same group up to
-- 500 times inside one old build's transaction, and timeout-proneness IS a
-- rejected write).
select pg_temp.expect('threeStatementLevelAfterTriggersOverOneFunction',
  (select count(*) = 3
     and bool_and(t.tgtype & 1 = 0)          -- 0 = STATEMENT level
     and bool_and(t.tgtype & 2 = 0)          -- 0 = AFTER
     and bool_and(p.proname = 'fold_legacy_writes')
   from pg_trigger t
   join pg_proc p on p.oid = t.tgfoid
   where t.tgrelid = 'public.tip_entries'::regclass
     and t.tgname in ('tip_entries_fold_insert','tip_entries_fold_update','tip_entries_fold_delete')),
  (select coalesce(string_agg(t.tgname || '(type=' || t.tgtype || ')', ' ' order by t.tgname), 'none')
   from pg_trigger t where t.tgrelid = 'public.tip_entries'::regclass and not t.tgisinternal));

-- Each trigger declares exactly the transition tables its own event allows.
select pg_temp.expect('eachTriggerDeclaresOnlyTheTransitionTablesItsEventAllows',
  (select bool_and(case t.tgname
            when 'tip_entries_fold_insert' then t.tgnewtable is not null and t.tgoldtable is null
            when 'tip_entries_fold_update' then t.tgnewtable is not null and t.tgoldtable is not null
            when 'tip_entries_fold_delete' then t.tgnewtable is null and t.tgoldtable is not null
          end)
   from pg_trigger t where t.tgrelid = 'public.tip_entries'::regclass
     and t.tgname like 'tip_entries_fold_%'),
  (select coalesce(string_agg(t.tgname || ':' || coalesce(t.tgoldtable,'-') || '/' || coalesce(t.tgnewtable,'-'), ' ' order by t.tgname), 'none')
   from pg_trigger t where t.tgrelid = 'public.tip_entries'::regclass and t.tgname like 'tip_entries_fold_%'));

-- The five arms are named, and the body contains no `raise` of its own. A
-- `when others` handler alone would let 57014 and P0004 through, and one
-- `raise` anywhere rejects a shipped build's write.
select pg_temp.expect('theFoldNamesFiveArmsAndRaisesNothing',
  (select prosrc like '%when query_canceled then%'
      and prosrc like '%when assert_failure then%'
      and prosrc like '%when deadlock_detected then%'
      and prosrc like '%when unique_violation then%'
      and prosrc like '%when others then%'
      -- every line with its `--` comment stripped, then searched for the
      -- statement keyword: the body's prose says "raise" a dozen times, so a
      -- plain LIKE over prosrc would be a permanent false positive
      and not exists (
        select 1 from regexp_split_to_table(prosrc, E'\n') as line
         where regexp_replace(line, '--.*$', '') ~* '(^|[^[:alnum:]_])raise([^[:alnum:]_]|$)')
     from pg_proc where oid = 'private.fold_legacy_writes()'::regprocedure),
  (select coalesce(string_agg(trim(line), ' / '), 'five arms and no raise')
     from pg_proc p, regexp_split_to_table(p.prosrc, E'\n') as line
    where p.oid = 'private.fold_legacy_writes()'::regprocedure
      and regexp_replace(line, '--.*$', '') ~* '(^|[^[:alnum:]_])raise([^[:alnum:]_]|$)'));

-- =============================================================================
-- 2. The ordinary path: one 1.0 statement, one fold
-- =============================================================================

insert into calls (name, n)
select 'oneRow', pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000101","shift_id":"53000000-0000-0000-0000-000000000100",
   "work_date":"2026-07-04","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-07-04T23:00:00Z"}]'::jsonb);

select pg_temp.expect('aOneRowLegacyPushFoldsInTheSameTransaction',
  pg_temp.called('oneRow') = 1
  and (f ->> 'cash_tips_cents')::integer = 5000
  and (f ->> 'prov')::integer = 1
  and f ->> 'source' = 'migration'
  and (f ->> 'converted')::boolean
  and (f ->> 'version')::integer = 1
  and (f ->> 'derived_version')::integer = 0,
  f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000100') as f;

-- TWO more rows of the SAME group in ONE statement must fold ONCE, not twice:
-- derived_version moves 0 -> 1. That is the whole reason the trigger is
-- statement-level. A per-row trigger is correct but recomputes per row, and
-- PaydayRemoteRepository.batchSize = 500 makes that up to 500 recomputes
-- inside one old build's transaction.
insert into calls (name, n)
select 'twoRowsOneStatement', pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000102","shift_id":"53000000-0000-0000-0000-000000000100",
   "work_date":"2026-07-04","amount_cents":2000,"kind":"credit","tip_out_cents":1000,
   "client_updated_at":"2026-07-04T23:05:00Z"},
  {"id":"53000000-0000-0000-0000-000000000103","shift_id":"53000000-0000-0000-0000-000000000100",
   "work_date":"2026-07-04","amount_cents":500,"kind":"cash",
   "client_updated_at":"2026-07-04T23:06:00Z"}]'::jsonb);

select pg_temp.expect('twoRowsOfOneGroupInOneStatementFoldExactlyOnce',
  pg_temp.called('twoRowsOneStatement') = 2
  and (f ->> 'cash_tips_cents')::integer = 5500
  and (f ->> 'credit_tips_cents')::integer = 2000
  and (f ->> 'tip_out_cents')::integer = 1000
  and (f ->> 'non_wage_earnings_cents')::integer = 6500
  and (f ->> 'prov')::integer = 3
  and (f ->> 'derived_version')::integer = 1
  and (f ->> 'version')::integer = 1,
  f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000100') as f;

-- 4.9: a shift whose rows arrive in separate TRANSACTIONS is the normal case
-- for every 1.0 edit, not an edge case -- synchronize calls upsertTips then
-- softDeleteTips as two PostgREST RPCs. One transaction per row leaves the
-- shift half-arrived, and no reader may throw on it.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000111","shift_id":"53000000-0000-0000-0000-000000000110",
   "work_date":"2026-07-05","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-07-05T23:00:00Z"}]'::jsonb);

select pg_temp.expect('aHalfArrivedShiftIsWrittenWithTheLegItHas',
  (f ->> 'cash_tips_cents')::integer = 5000
  and (f ->> 'credit_tips_cents')::integer = 0
  and (f ->> 'prov')::integer = 1,
  f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000110') as f;

select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000112","shift_id":"53000000-0000-0000-0000-000000000110",
   "work_date":"2026-07-05","amount_cents":2000,"kind":"credit",
   "client_updated_at":"2026-07-05T23:05:00Z"}]'::jsonb);

select pg_temp.expect('aShiftThatGainsItsSecondLegLaterUpdatesInPlace',
  (f ->> 'cash_tips_cents')::integer = 5000
  and (f ->> 'credit_tips_cents')::integer = 2000
  and (f ->> 'prov')::integer = 2
  -- the same id, not a second shift for the night
  and (select count(*) from public.shifts
        where user_id = '53000000-0000-4000-8000-000000000001' and work_date = '2026-07-05') = 1,
  f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000110') as f;

-- A nil-shift_id row keys on payday_legacy_shift_id(work_date). The key is a
-- pure function of ONE row and never adopts a sibling's stored id, which is
-- what makes the fold's result independent of which rows are visible in a
-- given transaction.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000121",
   "work_date":"2026-07-06","amount_cents":3000,"kind":"cash",
   "client_updated_at":"2026-07-06T23:00:00Z"}]'::jsonb);

select pg_temp.expect('aNilShiftIdRowFoldsOntoTheLegacyDateKey',
  (f ->> 'cash_tips_cents')::integer = 3000, f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         public.payday_legacy_shift_id('2026-07-06')) as f;

-- An ordinary fold never flags conservation. The fold stamps
-- conservation_failed_at from private.derive_shifts' returned in/out numbers,
-- and a false flag in Data health is its own defect.
select pg_temp.expect('ordinaryFoldsNeverFlagConservation',
  conservation_failed_at is null
  and last_legacy_write_at is not null
  and bulk_legacy_rewrite_at is null,
  'cons=' || coalesce(conservation_failed_at::text,'null')
  || ' last=' || coalesce(last_legacy_write_at::text,'null')
  || ' bulk=' || coalesce(bulk_legacy_rewrite_at::text,'null'))
from public.shift_migration_state where user_id = '53000000-0000-4000-8000-000000000001';

-- last_legacy_write_at is stamped only when the stored value is older than an
-- hour, so a chatty device cannot turn every legacy write into a state UPDATE.
update public.shift_migration_state set last_legacy_write_at = now() - interval '10 minutes'
 where user_id = '53000000-0000-4000-8000-000000000001';
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000122",
   "work_date":"2026-07-06","amount_cents":100,"kind":"credit",
   "client_updated_at":"2026-07-06T23:10:00Z"}]'::jsonb);

select pg_temp.expect('aTenMinuteOldStampIsNotRefreshed',
  last_legacy_write_at < now() - interval '5 minutes',
  'last=' || last_legacy_write_at::text)
from public.shift_migration_state where user_id = '53000000-0000-4000-8000-000000000001';

update public.shift_migration_state set last_legacy_write_at = now() - interval '2 hours'
 where user_id = '53000000-0000-4000-8000-000000000001';
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000123",
   "work_date":"2026-07-06","amount_cents":100,"kind":"credit",
   "client_updated_at":"2026-07-06T23:11:00Z"}]'::jsonb);

select pg_temp.expect('anHourOldStampIsRefreshed',
  last_legacy_write_at > now() - interval '1 minute',
  'last=' || last_legacy_write_at::text)
from public.shift_migration_state where user_id = '53000000-0000-4000-8000-000000000001';

-- =============================================================================
-- 3. The touched set is old keys UNION new keys
-- =============================================================================

-- upsert_tip_entries updates shift_id AND work_date unconditionally with no
-- staleness guard, and RemoteTipEntry.workDate is computed in the DEVICE's
-- current zone at push time, so a relocated 1.0 phone re-pushes the same row
-- under the adjacent civil day. Recompute only the NEW key and the old shift
-- keeps the money while the new one gains it: the night is displayed twice, on
-- two different dates, and the duplicate detector groups by work_date so it
-- can never report it.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000131","shift_id":"53000000-0000-0000-0000-000000000130",
   "work_date":"2026-08-01","amount_cents":7000,"kind":"cash",
   "client_updated_at":"2026-08-01T23:00:00Z"}]'::jsonb);
-- the same row, re-pushed under the adjacent civil day AND a new shift_id
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000131","shift_id":"53000000-0000-0000-0000-000000000132",
   "work_date":"2026-07-31","amount_cents":7000,"kind":"cash",
   "client_updated_at":"2026-08-02T00:00:00Z"}]'::jsonb);

select pg_temp.expect('anUpdateMovingShiftIdAndWorkDateRecomputesBothGroups',
  -- the OLD group lost its money and its claim, and is tombstoned 'converted'
  (o ->> 'cash_tips_cents')::integer = 0
  and (o ->> 'non_wage_earnings_cents')::integer = 0
  and (o ->> 'prov')::integer = 0
  and (o ->> 'is_deleted')::boolean
  and o ->> 'deleted_reason' = 'converted'
  -- ... and the NEW group has it, exactly once
  and (n ->> 'cash_tips_cents')::integer = 7000
  and (n ->> 'prov')::integer = 1
  and n ->> 'work_date' = '2026-07-31'
  -- ... so the money is on ONE date, not two
  and (select coalesce(sum(cash_tips_cents), 0) from public.shifts
        where user_id = '53000000-0000-4000-8000-000000000001'
          and deleted_at is null and work_date in ('2026-07-31','2026-08-01')) = 7000,
  'old=' || o::text || ' new=' || n::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000130') as o,
     pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000132') as n;

-- =============================================================================
-- 4. Arms 2a / 2b / 3 / 4 through the shipped 1.0 paths
-- =============================================================================

-- Arm 2b: soft-deleting the LAST live row of a group. A `group by` over an
-- empty source emits nothing, so without this arm the shift keeps the money
-- the user deleted on their old phone, permanently.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000201","shift_id":"53000000-0000-0000-0000-000000000200",
   "work_date":"2026-09-01","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-09-01T23:00:00Z"}]'::jsonb);
insert into calls (name, n)
select 'emptyGroup', pg_temp.device_delete('53000000-0000-4000-8000-000000000001',
  array['53000000-0000-0000-0000-000000000201'::uuid]);

select pg_temp.expect('emptying_every_row_of_a_group_tombstones_its_shift',
  pg_temp.called('emptyGroup') = 1
  and (f ->> 'cash_tips_cents')::integer = 0
  and (f ->> 'non_wage_earnings_cents')::integer = 0
  and (f ->> 'is_deleted')::boolean
  and f ->> 'deleted_reason' = 'converted'
  and (f ->> 'prov')::integer = 0
  and (f ->> 'unconverted_legacy_cents')::integer = 0,
  f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000200') as f;

-- Arm 3: a legacy UN-DELETE is a first-class live path on both writers --
-- RemoteTipEntry hardcodes deletedAt = nil and upsert_tip_entries lost its
-- staleness guard, so EVERY 1.0 push of a locally present row writes
-- deleted_at = null over a server tombstone. Without the arm the money is back
-- in tip_entries and the shift stays tombstoned forever: the new build shows
-- nothing while the old build shows the night.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000201","shift_id":"53000000-0000-0000-0000-000000000200",
   "work_date":"2026-09-01","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-09-02T00:00:00Z"}]'::jsonb);

select pg_temp.expect('theUndeleteArmReopensAConvertedTombstoneThroughAShipped10Push',
  (f ->> 'cash_tips_cents')::integer = 5000
  and not (f ->> 'is_deleted')::boolean
  and f -> 'deleted_reason' = 'null'::jsonb
  and (f ->> 'prov')::integer = 1,
  f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000200') as f;

-- ... and NEVER a tombstone the USER set. deleted_reason = 'converted' is
-- exactly why arm 2b is reversible and a user deletion is not.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000211","shift_id":"53000000-0000-0000-0000-000000000210",
   "work_date":"2026-09-02","amount_cents":4000,"kind":"cash",
   "client_updated_at":"2026-09-02T23:00:00Z"}]'::jsonb);
-- private.write_shifts lands in S6; a native soft delete is what it will write.
update public.shifts set deleted_at = now(), deleted_reason = 'user',
                         native_modified_at = now(), client_updated_at = now()
 where user_id = '53000000-0000-4000-8000-000000000001'
   and id = '53000000-0000-0000-0000-000000000210';
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000211","shift_id":"53000000-0000-0000-0000-000000000210",
   "work_date":"2026-09-02","amount_cents":4000,"kind":"cash",
   "client_updated_at":"2026-09-03T00:00:00Z"}]'::jsonb);

select pg_temp.expect('aUserTombstoneIsNeverReopenedByALegacyPush',
  (f ->> 'is_deleted')::boolean and f ->> 'deleted_reason' = 'user', f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000210') as f;

-- Arm 1 declines money on a CLOSED shift and arm 4a records the disagreement
-- with BOTH numbers.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000221","shift_id":"53000000-0000-0000-0000-000000000220",
   "work_date":"2026-09-03","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-09-03T23:00:00Z"}]'::jsonb);
update public.shifts set cash_tips_cents = 6000, native_modified_at = now(),
                         client_updated_at = now()
 where user_id = '53000000-0000-4000-8000-000000000001'
   and id = '53000000-0000-0000-0000-000000000220';
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000222","shift_id":"53000000-0000-0000-0000-000000000220",
   "work_date":"2026-09-03","amount_cents":2000,"kind":"credit",
   "client_updated_at":"2026-09-04T00:00:00Z"}]'::jsonb);

select pg_temp.expect('aClosedShiftKeepsItsMoneyTakesTheProvenanceAndRecordsAConflict',
  (f ->> 'cash_tips_cents')::integer = 6000
  and (f ->> 'credit_tips_cents')::integer = 0
  and (f ->> 'prov')::integer = 2
  and (f ->> 'unconverted_legacy_cents')::integer = 1000
  and pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                        '53000000-0000-0000-0000-000000000220') = '6000->7000',
  f::text || ' conflicts=[' || pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                                                 '53000000-0000-0000-0000-000000000220') || ']')
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000220') as f;

-- A DOWNWARD correction from an old build. unconverted_legacy_cents is abs(),
-- not greatest(0, ...): measured on a closed shift at 6000, a 6000-to-4000
-- correction gave greatest(0, ...) = 0 and Data health showed nothing at all,
-- and downward is the common shape of a real correction.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000221","shift_id":"53000000-0000-0000-0000-000000000220",
   "work_date":"2026-09-03","amount_cents":1000,"kind":"cash",
   "client_updated_at":"2026-09-04T01:00:00Z"}]'::jsonb);

select pg_temp.expect('aDownwardLegacyCorrectionOnAClosedShiftIsStillSurfaced',
  -- shift 6000, legacy now 1000 + 2000 = 3000: a DOWNWARD arrival
  (f ->> 'cash_tips_cents')::integer = 6000
  and (f ->> 'unconverted_legacy_cents')::integer = 3000
  and pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                        '53000000-0000-0000-0000-000000000220') = '6000->7000 6000->3000',
  f::text || ' conflicts=[' || pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                                                 '53000000-0000-0000-0000-000000000220') || ']')
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000220') as f;

-- A later arrival that happens to EQUAL the shift zeroes the per-shift
-- magnitude, which is exactly why shift_legacy_conflicts is append-only and is
-- the honest surface. unconverted_legacy_cents is never accumulated.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000221","shift_id":"53000000-0000-0000-0000-000000000220",
   "work_date":"2026-09-03","amount_cents":4000,"kind":"cash",
   "client_updated_at":"2026-09-04T02:00:00Z"}]'::jsonb);

select pg_temp.expect('aMatchingLateArrivalDoesNotEraseAnEarlierDisagreement',
  (f ->> 'unconverted_legacy_cents')::integer = 0
  and pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                        '53000000-0000-0000-0000-000000000220') = '6000->7000 6000->3000',
  f::text || ' conflicts=[' || pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                                                 '53000000-0000-0000-0000-000000000220') || ']')
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000220') as f;

-- Arm 2a is UNCONDITIONAL, arm 2b is gated. A natively edited shift whose
-- legacy rows are all deleted KEEPS its money -- the user's own edit wins --
-- and LOSES its claim, and arm 4b records the disagreement. If 2a were gated
-- on shift_is_open_to_fold this shift would name rows it no longer derives
-- from forever, which is what made the night display twice on two dates, the
-- duplicate count return 1 forever, and payday_unmigrated_tip_row_count()
-- never reach 0.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000231","shift_id":"53000000-0000-0000-0000-000000000230",
   "work_date":"2026-09-04","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-09-04T23:00:00Z"}]'::jsonb);
update public.shifts set hours_worked = 8.0, native_modified_at = now(), client_updated_at = now()
 where user_id = '53000000-0000-4000-8000-000000000001'
   and id = '53000000-0000-0000-0000-000000000230';
select pg_temp.device_delete('53000000-0000-4000-8000-000000000001',
  array['53000000-0000-0000-0000-000000000231'::uuid]);

select pg_temp.expect('aNativelyEditedShiftWhoseLegacyRowsWereDeletedKeepsItsMoneyAndRecordsAConflict',
  (f ->> 'cash_tips_cents')::integer = 5000
  and not (f ->> 'is_deleted')::boolean
  and (f ->> 'prov')::integer = 0
  and (f ->> 'unconverted_legacy_cents')::integer = 5000
  and pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                        '53000000-0000-0000-0000-000000000230') = '5000->0',
  f::text || ' conflicts=[' || pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                                                 '53000000-0000-0000-0000-000000000230') || ']')
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000230') as f;

-- The same shape on a shift the user DELETED on the new build. Reachable and
-- ordinary rather than a boundary effect: the user deletes the Jul 4 shift on
-- the new build, then an old phone pushes one unsynced $20 cash tip for Jul 4.
-- Money landing in a closed shift is counted and reported, never silently
-- accepted and never raised.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000241","shift_id":"53000000-0000-0000-0000-000000000240",
   "work_date":"2026-09-05","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-09-05T23:00:00Z"}]'::jsonb);
update public.shifts set deleted_at = now(), deleted_reason = 'user',
                         native_modified_at = now(), client_updated_at = now()
 where user_id = '53000000-0000-4000-8000-000000000001'
   and id = '53000000-0000-0000-0000-000000000240';
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000242","shift_id":"53000000-0000-0000-0000-000000000240",
   "work_date":"2026-09-05","amount_cents":2000,"kind":"credit",
   "client_updated_at":"2026-09-06T00:00:00Z"}]'::jsonb);

select pg_temp.expect('moneyArrivingForAUserDeletedShiftIsRecordedNotResurrected',
  (f ->> 'is_deleted')::boolean
  and f ->> 'deleted_reason' = 'user'
  and (f ->> 'cash_tips_cents')::integer = 5000
  and (f ->> 'prov')::integer = 2
  and pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                        '53000000-0000-0000-0000-000000000240') = '5000->7000',
  f::text || ' conflicts=[' || pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                                                 '53000000-0000-0000-0000-000000000240') || ']')
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000240') as f;

-- A CLOSED shift whose sources move AWAY -- re-keyed, not deleted -- loses its
-- claim and is reported. The stranded-provenance case in its purest form: the
-- old group is closed, so arm 2b cannot touch its money, and only the
-- unconditional arm 2a can release the claim.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000251","shift_id":"53000000-0000-0000-0000-000000000250",
   "work_date":"2026-09-06","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-09-06T23:00:00Z"}]'::jsonb);
update public.shifts set hours_worked = 7.5, native_modified_at = now(), client_updated_at = now()
 where user_id = '53000000-0000-4000-8000-000000000001'
   and id = '53000000-0000-0000-0000-000000000250';
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000251","shift_id":"53000000-0000-0000-0000-000000000252",
   "work_date":"2026-09-06","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-09-07T00:00:00Z"}]'::jsonb);

select pg_temp.expect('aClosedShiftWhoseSourcesMoveAwayLosesItsClaimAndIsReported',
  -- the closed shift keeps the money, loses the claim, is recorded
  (o ->> 'cash_tips_cents')::integer = 5000
  and (o ->> 'prov')::integer = 0
  and not (o ->> 'is_deleted')::boolean
  and (o ->> 'unconverted_legacy_cents')::integer = 5000
  and pg_temp.conflicts('53000000-0000-4000-8000-000000000001',
                        '53000000-0000-0000-0000-000000000250') = '5000->0'
  -- ... and the new key holds the money, so nothing is orphaned
  and (n ->> 'cash_tips_cents')::integer = 5000
  and (n ->> 'prov')::integer = 1
  -- the legacy id is named by EXACTLY ONE shift, which is what the duplicate
  -- count and the unmigrated predicate both depend on
  and (select count(*) from public.shifts
        where user_id = '53000000-0000-4000-8000-000000000001'
          and '53000000-0000-0000-0000-000000000251'::uuid = any(legacy_entry_ids)) = 1,
  'old=' || o::text || ' conflicts=[' || pg_temp.conflicts(
      '53000000-0000-4000-8000-000000000001','53000000-0000-0000-0000-000000000250') || ']'
  || ' named_by=' || (select count(*)::text from public.shifts
       where user_id = '53000000-0000-4000-8000-000000000001'
         and '53000000-0000-0000-0000-000000000251'::uuid = any(legacy_entry_ids)))
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000250') as o,
     pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000252') as n;

-- 4.9's frozen case, named rather than papered over: the user opens the
-- wrong-looking night DURING the two-RPC window, which is precisely when a
-- person notices a wrong number and tries to fix it, so native_modified_at is
-- set and the second RPC's correction is declined. The number FREEZES rather
-- than converging, and the exit is [Use theirs] in Data health (S13).
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000261","shift_id":"53000000-0000-0000-0000-000000000260",
   "work_date":"2026-09-07","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-09-07T23:00:00Z"},
  {"id":"53000000-0000-0000-0000-000000000262","shift_id":"53000000-0000-0000-0000-000000000260",
   "work_date":"2026-09-07","amount_cents":2000,"kind":"cash",
   "client_updated_at":"2026-09-07T23:01:00Z"}]'::jsonb);
-- the user "fixes" the over-counted night mid-window
update public.shifts set cash_tips_cents = 5000, native_modified_at = now(), client_updated_at = now()
 where user_id = '53000000-0000-4000-8000-000000000001'
   and id = '53000000-0000-0000-0000-000000000260';
-- the second RPC of the pair: softDeleteTips
select pg_temp.device_delete('53000000-0000-4000-8000-000000000001',
  array['53000000-0000-0000-0000-000000000262'::uuid]);

select pg_temp.expect('anOverCountCorrectedByTheUserMidWindowIsFrozenAndSurfaced',
  (f ->> 'cash_tips_cents')::integer = 5000
  and not (f ->> 'is_deleted')::boolean
  and (f ->> 'prov')::integer = 1
  and (f ->> 'unconverted_legacy_cents')::integer = 0,
  f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000260') as f;

-- bulk_legacy_rewrite_at: more than 5 REOPENED tombstones stamps it once. Five
-- must NOT stamp it; six must. A 1.0 device that loses its checkpoint
-- mass-re-pushes its whole history (changedIDs returns every local id when
-- `acknowledged` is empty), and Data health shows a banner instead of the
-- rewrite being invisible.
do $$
declare v_rows jsonb;
begin
  v_rows := (select jsonb_agg(jsonb_build_object(
      'id', ('53000000-0000-0000-0000-' || lpad((300 + g)::text, 12, '0'))::uuid,
      'shift_id', ('53000000-0000-0000-1000-' || lpad((300 + g)::text, 12, '0'))::uuid,
      'work_date', (date '2026-10-01' + g)::text,
      'amount_cents', 1000, 'kind', 'cash',
      'client_updated_at', '2026-10-01T00:00:00Z'))
    from generate_series(1, 6) g);
  perform pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', v_rows);
  perform pg_temp.device_delete('53000000-0000-4000-8000-000000000001',
    array(select ('53000000-0000-0000-0000-' || lpad((300 + g)::text, 12, '0'))::uuid
          from generate_series(1, 6) g));
end;
$$;
update public.shift_migration_state set bulk_legacy_rewrite_at = null
 where user_id = '53000000-0000-4000-8000-000000000001';
-- reopen FIVE of the six
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001',
  (select jsonb_agg(jsonb_build_object(
     'id', ('53000000-0000-0000-0000-' || lpad((300 + g)::text, 12, '0'))::uuid,
     'shift_id', ('53000000-0000-0000-1000-' || lpad((300 + g)::text, 12, '0'))::uuid,
     'work_date', (date '2026-10-01' + g)::text,
     'amount_cents', 1000, 'kind', 'cash',
     'client_updated_at', '2026-10-02T00:00:00Z'))
   from generate_series(1, 5) g));

select pg_temp.expect('fiveReopenedTombstonesDoNotStampTheBulkBanner',
  (select bulk_legacy_rewrite_at is null from public.shift_migration_state
    where user_id = '53000000-0000-4000-8000-000000000001')
  and (select count(*) from public.shifts
        where user_id = '53000000-0000-4000-8000-000000000001'
          and id in (select ('53000000-0000-0000-1000-' || lpad((300 + g)::text, 12, '0'))::uuid
                     from generate_series(1, 6) g)
          and deleted_at is null) = 5,
  (select 'bulk=' || coalesce(bulk_legacy_rewrite_at::text, 'null')
     from public.shift_migration_state where user_id = '53000000-0000-4000-8000-000000000001')
  || ' reopened=' || (select count(*)::text from public.shifts
       where user_id = '53000000-0000-4000-8000-000000000001'
         and id in (select ('53000000-0000-0000-1000-' || lpad((300 + g)::text, 12, '0'))::uuid
                    from generate_series(1, 6) g)
         and deleted_at is null));

-- re-tombstone all six, then reopen all six in one statement
select pg_temp.device_delete('53000000-0000-4000-8000-000000000001',
  array(select ('53000000-0000-0000-0000-' || lpad((300 + g)::text, 12, '0'))::uuid
        from generate_series(1, 6) g), now() + interval '1 second');
update public.shift_migration_state set bulk_legacy_rewrite_at = null
 where user_id = '53000000-0000-4000-8000-000000000001';
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001',
  (select jsonb_agg(jsonb_build_object(
     'id', ('53000000-0000-0000-0000-' || lpad((300 + g)::text, 12, '0'))::uuid,
     'shift_id', ('53000000-0000-0000-1000-' || lpad((300 + g)::text, 12, '0'))::uuid,
     'work_date', (date '2026-10-01' + g)::text,
     'amount_cents', 1000, 'kind', 'cash',
     'client_updated_at', '2026-10-03T00:00:00Z'))
   from generate_series(1, 6) g));

select pg_temp.expect('sixReopenedTombstonesStampTheBulkBannerOnce',
  (select bulk_legacy_rewrite_at is not null from public.shift_migration_state
    where user_id = '53000000-0000-4000-8000-000000000001')
  and (select count(*) from public.shifts
        where user_id = '53000000-0000-4000-8000-000000000001'
          and id in (select ('53000000-0000-0000-1000-' || lpad((300 + g)::text, 12, '0'))::uuid
                     from generate_series(1, 6) g)
          and deleted_at is null) = 6,
  (select 'bulk=' || coalesce(bulk_legacy_rewrite_at::text, 'null')
     from public.shift_migration_state where user_id = '53000000-0000-4000-8000-000000000001'));

-- =============================================================================
-- 5. A non-object receipt payload, and the jsonb_set fact behind the CASE guard
-- =============================================================================

-- The raw facts, MEASURED and recorded verbatim, because
-- public.tip_entries.receipt_metrics has NO object CHECK and both shapes are
-- storable today, which is why the sanitizer's CASE guard is not optional:
--   jsonb_set on a JSON ARRAY  -> 22P02 'path element at position 1 is not an integer'
--   jsonb_set on a JSON SCALAR -> 22023 'cannot set path in scalar'
select pg_temp.expect('jsonbSetOnANonObjectPayloadRaisesTwoDifferentWays',
  pg_temp.outcome_of($sql$select jsonb_set('[1,2]'::jsonb, '{earningsSchemaVersion}', '2'::jsonb, true)$sql$) = '22P02'
  and pg_temp.outcome_of($sql$select jsonb_set('"hi"'::jsonb, '{earningsSchemaVersion}', '2'::jsonb, true)$sql$) = '22023',
  'array=' || pg_temp.outcome_of($sql$select jsonb_set('[1,2]'::jsonb, '{earningsSchemaVersion}', '2'::jsonb, true)$sql$)
  || ' scalar=' || pg_temp.outcome_of($sql$select jsonb_set('"hi"'::jsonb, '{earningsSchemaVersion}', '2'::jsonb, true)$sql$));

-- ... and through the shipped RPC both fold WITHOUT raising: a non-object
-- payload is excluded by jsonb_typeof, so the group stores no receipt at all
-- rather than violating shifts_receipt_is_object.
insert into calls (name, n)
select 'junkPayload', pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000271","shift_id":"53000000-0000-0000-0000-000000000270",
   "work_date":"2026-09-08","amount_cents":5000,"kind":"cash","receipt_metrics":"hi",
   "client_updated_at":"2026-09-08T23:00:00Z"},
  {"id":"53000000-0000-0000-0000-000000000272","shift_id":"53000000-0000-0000-0000-000000000270",
   "work_date":"2026-09-08","amount_cents":2000,"kind":"credit","receipt_metrics":[1,2],
   "client_updated_at":"2026-09-08T23:05:00Z"}]'::jsonb);

select pg_temp.expect('aNonObjectReceiptPayloadFromAnOldBuildFoldsWithoutRaising',
  pg_temp.called('junkPayload') = 2
  and (f ->> 'cash_tips_cents')::integer = 5000
  and (f ->> 'credit_tips_cents')::integer = 2000
  and f -> 'receipt_metrics' = 'null'::jsonb
  and (f ->> 'gratuity_fees_cents')::integer = 0
  and pg_temp.failures('53000000-0000-4000-8000-000000000001') = '',
  f::text || ' failures=[' || pg_temp.failures('53000000-0000-4000-8000-000000000001') || ']')
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000270') as f;

-- A v1 object payload with an out-of-range gratuity, UNMODIFIED DDL: clamped in
-- numeric space, no 22003, and the stored payload carries the clamped value so
-- the payload and the generated column cannot disagree.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000001', '[
  {"id":"53000000-0000-0000-0000-000000000281","shift_id":"53000000-0000-0000-0000-000000000280",
   "work_date":"2026-09-09","amount_cents":5000,"kind":"cash",
   "receipt_metrics":{"gratuityFeesCents": 99999999999},
   "client_updated_at":"2026-09-09T23:00:00Z"}]'::jsonb);

select pg_temp.expect('anOutOfRangeGratuityFromAnOldBuildIsClampedNotAborted',
  (f ->> 'gratuity_fees_cents')::integer = 2147483647
  and (f ->> 'non_wage_earnings_cents')::integer = 2147483647
  and f -> 'receipt_metrics' -> 'earningsSchemaVersion' = '2'::jsonb
  and pg_temp.failures('53000000-0000-4000-8000-000000000001') = '',
  f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000001',
                         '53000000-0000-0000-0000-000000000280') as f;

-- =============================================================================
-- 6. The S-gate: for each forced abort class, a 1.0-shaped write STILL
--    SUCCEEDS, the legacy row is present, exactly one failure row lands with
--    the expected sqlstate, and the touched keys are queued.
--
--    The 40P01 row of the S-gate table needs two sessions taking row locks in
--    opposite orders and is in scripts/db-test-race.sh.
-- =============================================================================

-- The shipped definition, captured so the DDL fixtures below can be restored
-- from the real source rather than from a hand-copied duplicate that would
-- drift the day the real rule changes.
create temporary table saved_defs as
select 'gratuity'::text as name,
       pg_get_functiondef('private.receipt_gratuity_cents(jsonb)'::regprocedure) as def;

-- CLASS 22P02: a poisoned receipt payload reaching a cast, with the
-- jsonb_typeof guard removed in a test fixture of the DDL. Rule 2 of "the fold
-- never raises" is "every cast is guarded by jsonb_typeof first, no
-- exception", and this is what that rule is worth: without it one junk payload
-- is a rejected write from a shipped build, forever, on every retry.
create or replace function private.receipt_gratuity_cents(p jsonb)
returns integer language sql immutable set search_path = '' as $$
  -- TEST FIXTURE ONLY. The unguarded cast the real rule exists to prevent.
  select case when p ? 'earningsSchemaVersion'
              then (p ->> 'earningsSchemaVersion')::integer else 0 end;
$$;

insert into calls (name, n)
select 'abort22P02', pg_temp.device_upsert('53000000-0000-4000-8000-000000000002', '[
  {"id":"53000000-0000-0000-0000-000000000401","shift_id":"53000000-0000-0000-0000-000000000400",
   "work_date":"2026-07-04","amount_cents":5000,"kind":"cash",
   "receipt_metrics":{"earningsSchemaVersion": true},
   "client_updated_at":"2026-07-04T23:00:00Z"}]'::jsonb);

select pg_temp.expect('aPoisonedPayloadAbortsWith22P02AndTheLegacyWriteStillCommits',
  -- the 1.0 RPC returned its row: the build's write was NOT rejected
  pg_temp.called('abort22P02') = 1
  and (select count(*) from public.tip_entries
        where id = '53000000-0000-0000-0000-000000000401' and deleted_at is null) = 1
  -- exactly one failure row, with the expected sqlstate and the touched key
  and (select count(*) = 1 and min(sqlstate) = '22P02'
              and min(group_keys) = array['53000000-0000-0000-0000-000000000400'::uuid]
         from private.shift_fold_failures
        where user_id = '53000000-0000-4000-8000-000000000002')
  -- ... and the keys are queued, so the work is not silently dropped
  and pg_temp.backlog_keys('53000000-0000-4000-8000-000000000002')
      = array['53000000-0000-0000-0000-000000000400'::uuid]
  -- ... and the rolled-back attempt left nothing in shifts
  and (select count(*) from public.shifts
        where user_id = '53000000-0000-4000-8000-000000000002') = 0,
  'failures=[' || pg_temp.failures('53000000-0000-4000-8000-000000000002') || ']'
  || ' backlog=' || pg_temp.backlog_keys('53000000-0000-4000-8000-000000000002')::text);

-- CLASS 22003: an out-of-range gratuity with the numeric-space clamp removed.
-- {"gratuityFeesCents": 99999999999} is legally storable in tip_entries today,
-- and int4-space arithmetic aborts on it inside a 1.0 build's transaction.
create or replace function private.receipt_gratuity_cents(p jsonb)
returns integer language sql immutable set search_path = '' as $$
  -- TEST FIXTURE ONLY. The clamp removed: int4 space, no least/greatest.
  select case when jsonb_typeof(p -> 'gratuityFeesCents') = 'number'
              then (p ->> 'gratuityFeesCents')::integer else 0 end;
$$;

insert into calls (name, n)
select 'abort22003', pg_temp.device_upsert('53000000-0000-4000-8000-000000000002', '[
  {"id":"53000000-0000-0000-0000-000000000411","shift_id":"53000000-0000-0000-0000-000000000410",
   "work_date":"2026-07-05","amount_cents":5000,"kind":"cash",
   "receipt_metrics":{"gratuityFeesCents": 99999999999},
   "client_updated_at":"2026-07-05T23:00:00Z"}]'::jsonb);

select pg_temp.expect('anOutOfRangeGratuityAbortsWith22003AndTheLegacyWriteStillCommits',
  pg_temp.called('abort22003') = 1
  and (select count(*) from public.tip_entries
        where id = '53000000-0000-0000-0000-000000000411' and deleted_at is null) = 1
  and (select count(*) = 1 and min(sqlstate) = '22003'
         from private.shift_fold_failures
        where user_id = '53000000-0000-4000-8000-000000000002'
          and group_keys = array['53000000-0000-0000-0000-000000000410'::uuid])
  and '53000000-0000-0000-0000-000000000410'::uuid
      = any(pg_temp.backlog_keys('53000000-0000-4000-8000-000000000002')),
  'failures=[' || pg_temp.failures('53000000-0000-4000-8000-000000000002') || ']');

-- Restore the shipped rule from its captured definition, and PROVE it is back
-- by behaviour rather than by having restored it.
do $$ begin execute (select def from saved_defs where name = 'gratuity'); end $$;

select pg_temp.expect('theShippedGratuityRuleIsRestoredAndClampsAgain',
  private.receipt_gratuity_cents('{"gratuityFeesCents": 99999999999}'::jsonb) = 2147483647
  and private.receipt_gratuity_cents('{"gratuityFeesCents": "42"}'::jsonb) = 0
  and private.receipt_gratuity_cents('{"earningsSchemaVersion": true}'::jsonb) = 0,
  'clamped=' || private.receipt_gratuity_cents('{"gratuityFeesCents": 99999999999}'::jsonb)::text);

-- CLASS 57014, the one that matters most: statement_timeout. `when others`
-- does NOT catch it -- PL/pgSQL's OTHERS deliberately excludes QUERY_CANCELED
-- and ASSERT_FAILURE -- and PaydaySyncService retries the identical 500-row
-- payload, so one untrapped timeout is permanent darkness for that device.
--
-- The timeout is set as its own TOP-LEVEL statement, not inside the helper: a
-- statement_timeout set inside a running statement does not re-arm a timer
-- that started with the outer statement.
set statement_timeout = '500ms';
insert into calls (name, n)
select 'abort57014', pg_temp.device_upsert('53000000-0000-4000-8000-000000000002', '[
  {"id":"53000000-0000-0000-0000-000000000421","shift_id":"53000000-0000-0000-0000-000000000420",
   "work_date":"2026-07-06","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-07-06T23:00:00Z"}]'::jsonb, 'sleep');
reset statement_timeout;

select pg_temp.expect('aStatementTimeoutAbortsWith57014AndTheLegacyWriteStillCommits',
  pg_temp.called('abort57014') = 1
  and (select count(*) from public.tip_entries
        where id = '53000000-0000-0000-0000-000000000421' and deleted_at is null) = 1
  and (select count(*) = 1 and min(sqlstate) = '57014'
         from private.shift_fold_failures
        where user_id = '53000000-0000-4000-8000-000000000002'
          and group_keys = array['53000000-0000-0000-0000-000000000420'::uuid])
  -- Catching 57014 does NOT re-arm the timer, which is exactly why the handler
  -- must be two bounded inserts wide and then return: no retry, no re-derive,
  -- no second pass. This is that proof -- both handler inserts completed and
  -- COMMITTED after the timeout had already fired.
  and '53000000-0000-0000-0000-000000000420'::uuid
      = any(pg_temp.backlog_keys('53000000-0000-4000-8000-000000000002')),
  'failures=[' || pg_temp.failures('53000000-0000-4000-8000-000000000002') || ']');

-- CLASS assert_failure (P0004): also NOT caught by OTHERS.
insert into calls (name, n)
select 'abortAssert', pg_temp.device_upsert('53000000-0000-4000-8000-000000000002', '[
  {"id":"53000000-0000-0000-0000-000000000431","shift_id":"53000000-0000-0000-0000-000000000430",
   "work_date":"2026-07-07","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-07-07T23:00:00Z"}]'::jsonb, 'assert');

select pg_temp.expect('anAssertionFailureIsCaughtAndTheLegacyWriteStillCommits',
  pg_temp.called('abortAssert') = 1
  and (select count(*) from public.tip_entries
        where id = '53000000-0000-0000-0000-000000000431' and deleted_at is null) = 1
  and (select count(*) = 1 and min(sqlstate) = 'P0004'
         from private.shift_fold_failures
        where user_id = '53000000-0000-4000-8000-000000000002'
          and group_keys = array['53000000-0000-0000-0000-000000000430'::uuid])
  and '53000000-0000-0000-0000-000000000430'::uuid
      = any(pg_temp.backlog_keys('53000000-0000-4000-8000-000000000002')),
  'failures=[' || pg_temp.failures('53000000-0000-4000-8000-000000000002') || ']');

-- Every group that aborted is still queued, so nothing was dropped. Recording
-- WITHOUT queueing was the earlier draft's silent work-dropper: the group was
-- never converted, the unmigrated count stayed positive forever, and the only
-- recovery was the one-shot, which reproduced the identical abort. One bad
-- receipt scan on one night took the account dark permanently.
select pg_temp.expect('everyAbortedGroupIsQueuedNotDropped',
  (select array_agg(distinct k order by k) from private.shift_fold_failures f,
          unnest(f.group_keys) k where f.user_id = '53000000-0000-4000-8000-000000000002')
  = pg_temp.backlog_keys('53000000-0000-4000-8000-000000000002'),
  'failed=' || (select coalesce((array_agg(distinct k order by k))::text, '{}')
                from private.shift_fold_failures f, unnest(f.group_keys) k
                where f.user_id = '53000000-0000-4000-8000-000000000002')
  || ' queued=' || pg_temp.backlog_keys('53000000-0000-4000-8000-000000000002')::text);

-- A previously-aborted group converts on a LATER legacy write, through the
-- reserved backlog share. This is the pair that makes an abort recoverable at
-- all, and the whole S-gate is worth nothing without it.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000002', '[
  {"id":"53000000-0000-0000-0000-000000000441","shift_id":"53000000-0000-0000-0000-000000000440",
   "work_date":"2026-07-08","amount_cents":100,"kind":"cash",
   "client_updated_at":"2026-07-08T23:00:00Z"}]'::jsonb);

select pg_temp.expect('aPreviouslyAbortedGroupConvertsOnTheNextLegacyWrite',
  -- the timeout group and the assert group are folded now, with their money
  (select cash_tips_cents from public.shifts
    where user_id = '53000000-0000-4000-8000-000000000002'
      and id = '53000000-0000-0000-0000-000000000420') = 5000
  and (select cash_tips_cents from public.shifts
        where user_id = '53000000-0000-4000-8000-000000000002'
          and id = '53000000-0000-0000-0000-000000000430') = 5000
  -- the two DDL-fixture groups fold too, now that the real clamp is back
  and (select count(*) from public.shifts
        where user_id = '53000000-0000-4000-8000-000000000002') = 5
  and cardinality(pg_temp.backlog_keys('53000000-0000-4000-8000-000000000002')) = 0,
  'backlog=' || pg_temp.backlog_keys('53000000-0000-4000-8000-000000000002')::text
  || ' shifts=' || (select count(*)::text from public.shifts
       where user_id = '53000000-0000-4000-8000-000000000002'));

-- =============================================================================
-- 7. The reserved 40/10 work budget, on the shipped 500-row batch
-- =============================================================================

-- MEASURED, one shipped-shaped upsert_tip_entries of 500 rows across 250
-- groups (PaydaySyncService sends batchSize = 500). The design's reference
-- figure is 50 written / 200 backlogged / 0 failures in 14.6 ms.
create temporary table timing (name text, rows integer, written integer,
                               backlog integer, drained integer, failures integer, ms numeric);

do $$
declare v_ms numeric;
begin
  v_ms := pg_temp.device_upsert_ms('53000000-0000-4000-8000-000000000003',
                                   pg_temp.batch_rows(1, 250));
  insert into timing
  select 'batch 1: 500 rows / 250 groups, empty backlog', 500,
         (select count(*) from public.shifts where user_id = '53000000-0000-4000-8000-000000000003'),
         (select count(*) from private.shift_fold_backlog where user_id = '53000000-0000-4000-8000-000000000003'),
         0,
         (select count(*) from private.shift_fold_failures where user_id = '53000000-0000-4000-8000-000000000003'),
         v_ms;
end;
$$;

select pg_temp.expect('aFiveHundredRowBatchFoldsFiftyGroupsAndQueuesTheRest',
  written = 50 and backlog = 200 and failures = 0,
  'written=' || written || ' backlog=' || backlog || ' failures=' || failures || ' ms=' || ms)
from timing where name like 'batch 1%';

-- The reservation is what makes progress guaranteed, and the first draft's
-- "spend any leftover budget" yielded exactly zero leftover in the case that
-- creates the backlog: a second identical 500-row batch folded 50 fresh groups
-- and drained ZERO, which is precisely the first sign-in and checkpoint-loss
-- re-push the budget exists for.
do $$
declare v_before uuid[]; v_after uuid[]; v_ms numeric;
begin
  v_before := pg_temp.backlog_keys('53000000-0000-4000-8000-000000000003');
  v_ms := pg_temp.device_upsert_ms('53000000-0000-4000-8000-000000000003',
                                   pg_temp.batch_rows(1, 250));
  v_after := pg_temp.backlog_keys('53000000-0000-4000-8000-000000000003');
  insert into timing
  select 'batch 2: the same 500 rows, 200-group backlog', 500,
         (select count(*) from public.shifts where user_id = '53000000-0000-4000-8000-000000000003'),
         cardinality(v_after),
         (select count(*) from unnest(v_before) b where not (b = any(v_after))),
         (select count(*) from private.shift_fold_failures where user_id = '53000000-0000-4000-8000-000000000003'),
         v_ms;
end;
$$;

select pg_temp.expect('aFiveHundredRowBatchDrainsAtLeastTenBacklogGroups',
  drained >= 10,
  'drained=' || drained || ' backlog=' || backlog || ' written=' || written || ' ms=' || ms)
from timing where name like 'batch 2%';

-- A SATURATING statement -- 40 or more touched groups, so the touched share is
-- fully spent -- still drains its reserved 10. "The 10 roll into the touched
-- keys only when the backlog is empty" is the whole rule.
do $$
declare v_before uuid[]; v_after uuid[];
begin
  v_before := pg_temp.backlog_keys('53000000-0000-4000-8000-000000000003');
  perform pg_temp.device_upsert('53000000-0000-4000-8000-000000000003',
                                pg_temp.batch_rows(2, 60));
  v_after := pg_temp.backlog_keys('53000000-0000-4000-8000-000000000003');
  insert into timing
  select 'saturating: 120 rows / 60 groups, non-empty backlog', 120,
         0, cardinality(v_after),
         (select count(*) from unnest(v_before) b where not (b = any(v_after))),
         0, 0;
end;
$$;

select pg_temp.expect('aSaturatingStatementStillDrainsOneBacklogGroup',
  drained >= 1, 'drained=' || drained)
from timing where name like 'saturating%';

-- With an EMPTY backlog the reserved 10 roll into the touched keys: 50 fresh
-- groups, not 40.
delete from private.shift_fold_backlog where user_id = '53000000-0000-4000-8000-000000000003';
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000003', pg_temp.batch_rows(3, 60));

select pg_temp.expect('theReservedTenRollIntoTheTouchedKeysWhenTheBacklogIsEmpty',
  (select count(*) from public.shifts
    where user_id = '53000000-0000-4000-8000-000000000003'
      and id in (select ('53000000-0000-4000-9000-' || lpad((3 * 100000 + g)::text, 12, '0'))::uuid
                 from generate_series(1, 60) g)) = 50,
  'written=' || (select count(*)::text from public.shifts
    where user_id = '53000000-0000-4000-8000-000000000003'
      and id in (select ('53000000-0000-4000-9000-' || lpad((3 * 100000 + g)::text, 12, '0'))::uuid
                 from generate_series(1, 60) g)));

-- Over 50 touched groups in one invocation stamps the bulk banner.
select pg_temp.expect('overFiftyTouchedGroupsStampsTheBulkBanner',
  bulk_legacy_rewrite_at is not null,
  'bulk=' || coalesce(bulk_legacy_rewrite_at::text, 'null'))
from public.shift_migration_state where user_id = '53000000-0000-4000-8000-000000000003';

-- Nothing in the whole budget exercise ever raised.
select pg_temp.expect('theWholeBudgetExerciseRecordedZeroFailures',
  pg_temp.failures('53000000-0000-4000-8000-000000000003') = '',
  'failures=[' || pg_temp.failures('53000000-0000-4000-8000-000000000003') || ']');

-- =============================================================================
-- 8. service_role, and more than one account in one statement
-- =============================================================================

-- The agent API writes tip_entries by DIRECT TABLE ACCESS with the
-- service-role client, so RLS is bypassed and auth.uid() is null. The account
-- comes from the ROWS: scoping by auth.uid() would write user_id null -- a NOT
-- NULL violation, i.e. a rejected write -- or fold nowhere.
insert into calls (name, n)
select 'serviceWrite',
  case pg_temp.outcome_of($sql$select pg_temp.service_write($x$
    insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
    values ('53000000-0000-0000-0000-000000000501','53000000-0000-4000-8000-000000000005',
            '53000000-0000-0000-0000-000000000500','2026-07-04',4500,'cash','2026-07-04 23:00:00+00')
  $x$)$sql$) when '00000' then 1 else 0 end;

select pg_temp.expect('aServiceRoleWriteFoldsIntoTheRowsOwner',
  pg_temp.called('serviceWrite') = 1
  and (f ->> 'cash_tips_cents')::integer = 4500
  and (f ->> 'prov')::integer = 1,
  f::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000005',
                         '53000000-0000-0000-0000-000000000500') as f;

-- ONE service-role statement carrying rows of TWO accounts folds each into its
-- own account. Folding both into whichever account auth.uid() happened to name
-- would move money between people.
insert into calls (name, n)
select 'twoAccounts',
  case pg_temp.outcome_of($sql$select pg_temp.service_write($x$
    insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
    values ('53000000-0000-0000-0000-000000000511','53000000-0000-4000-8000-000000000005',
            '53000000-0000-0000-0000-000000000510','2026-07-05',1100,'cash','2026-07-05 23:00:00+00'),
           ('53000000-0000-0000-0000-000000000521','53000000-0000-4000-8000-000000000006',
            '53000000-0000-0000-0000-000000000520','2026-07-05',2200,'cash','2026-07-05 23:00:00+00')
  $x$)$sql$) when '00000' then 1 else 0 end;

select pg_temp.expect('oneStatementWithTwoAccountsFoldsEachIntoItsOwn',
  pg_temp.called('twoAccounts') = 1
  and (a ->> 'cash_tips_cents')::integer = 1100
  and (b ->> 'cash_tips_cents')::integer = 2200
  and (select count(*) from public.shifts
        where user_id = '53000000-0000-4000-8000-000000000006') = 1,
  'a=' || a::text || ' b=' || b::text)
from pg_temp.shift_facts('53000000-0000-4000-8000-000000000005',
                         '53000000-0000-0000-0000-000000000510') as a,
     pg_temp.shift_facts('53000000-0000-4000-8000-000000000006',
                         '53000000-0000-0000-0000-000000000520') as b;

-- Both accounts got their own bookkeeping row, each stamped inside its own
-- per-account advisory lock.
select pg_temp.expect('eachAccountInAMultiAccountStatementGetsItsOwnStateRow',
  (select count(*) = 2 and bool_and(last_legacy_write_at is not null)
     from public.shift_migration_state
    where user_id = any(array['53000000-0000-4000-8000-000000000005'::uuid,
                              '53000000-0000-4000-8000-000000000006'::uuid])),
  (select coalesce(string_agg(right(user_id::text, 4) || '=' || coalesce(last_legacy_write_at::text, 'null'), ' '), 'none')
     from public.shift_migration_state
    where user_id = any(array['53000000-0000-4000-8000-000000000005'::uuid,
                              '53000000-0000-4000-8000-000000000006'::uuid])));

-- =============================================================================
-- 9. The DELETE arm no-ops during account deletion
-- =============================================================================

-- public.delete_my_account() deletes the auth.users row and every Payday table
-- cascades. MEASURED with a probe trigger in this exact shape: by the time the
-- cascade's DELETE on tip_entries fires its statement trigger, the auth.users
-- row is ALREADY invisible and public.shifts has ALREADY been emptied. Without
-- the no-op the fold would re-insert a shifts row for a user that no longer
-- exists, raise 23503, hit the same FK again inside the handler's own insert,
-- and FAIL account deletion -- the Guideline 5.1.1(v) requirement Payday was
-- rejected over once already.
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000004', '[
  {"id":"53000000-0000-0000-0000-000000000601","shift_id":"53000000-0000-0000-0000-000000000600",
   "work_date":"2026-07-04","amount_cents":5000,"kind":"cash",
   "client_updated_at":"2026-07-04T23:00:00Z"}]'::jsonb);
-- close the shift so the next arrival records a conflict row
update public.shifts set native_modified_at = now(), client_updated_at = now()
 where user_id = '53000000-0000-4000-8000-000000000004';
select pg_temp.device_upsert('53000000-0000-4000-8000-000000000004', '[
  {"id":"53000000-0000-0000-0000-000000000602","shift_id":"53000000-0000-0000-0000-000000000600",
   "work_date":"2026-07-04","amount_cents":2000,"kind":"credit",
   "client_updated_at":"2026-07-05T00:00:00Z"}]'::jsonb);
insert into private.shift_fold_backlog (user_id, group_key)
values ('53000000-0000-4000-8000-000000000004','53000000-0000-0000-0000-000000000699')
on conflict (user_id, group_key) do nothing;
insert into private.shift_fold_failures (user_id, group_keys, sqlstate, message)
values ('53000000-0000-4000-8000-000000000004',
        array['53000000-0000-0000-0000-000000000699'::uuid], '57014', 'fixture');

select pg_temp.expect('allFiveTablesHoldRowsBeforeTheAccountDeletion',
  (select count(*) > 0 from public.shifts where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) > 0 from public.shift_legacy_conflicts where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) > 0 from public.shift_migration_state where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) > 0 from private.shift_fold_backlog where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) > 0 from private.shift_fold_failures where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) > 0 from public.tip_entries where user_id = '53000000-0000-4000-8000-000000000004'),
  'shifts=' || (select count(*)::text from public.shifts where user_id = '53000000-0000-4000-8000-000000000004')
  || ' conflicts=' || (select count(*)::text from public.shift_legacy_conflicts where user_id = '53000000-0000-4000-8000-000000000004')
  || ' backlog=' || (select count(*)::text from private.shift_fold_backlog where user_id = '53000000-0000-4000-8000-000000000004'));

create function pg_temp.delete_account(p_user uuid) returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user)::text, true);
  set local role authenticated;
  perform public.delete_my_account();
  reset role;
  return '00000';
exception when others then
  reset role;
  return sqlstate || ': ' || sqlerrm;
end;
$$;

create temporary table deletion_outcome as
select pg_temp.delete_account('53000000-0000-4000-8000-000000000004') as outcome;

select pg_temp.expect('delete_my_account_still_succeeds_with_the_fold_installed',
  (select outcome from deletion_outcome) = '00000'
  and (select count(*) from auth.users where id = '53000000-0000-4000-8000-000000000004') = 0,
  (select outcome from deletion_outcome));

select pg_temp.expect('theCascadeLeftNothingBehindAndTheFoldRecordedNoFailure',
  (select count(*) = 0 from public.shifts where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) = 0 from public.tip_entries where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) = 0 from public.shift_legacy_conflicts where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) = 0 from public.shift_migration_state where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) = 0 from private.shift_fold_backlog where user_id = '53000000-0000-4000-8000-000000000004')
  and (select count(*) = 0 from private.shift_fold_failures where user_id = '53000000-0000-4000-8000-000000000004'),
  'shifts=' || (select count(*)::text from public.shifts where user_id = '53000000-0000-4000-8000-000000000004')
  || ' failures=' || (select count(*)::text from private.shift_fold_failures
       where user_id = '53000000-0000-4000-8000-000000000004'));

-- =============================================================================
-- Report
-- =============================================================================

select name, rows, written, backlog, drained, failures, ms from timing order by name;

-- An assertion whose driving SELECT returns no row never calls pg_temp.expect
-- and would vanish from the report instead of failing, so the count is pinned.
select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 46,
  'ran ' || (select count(*) from results)::text || ' of 46');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed
from results;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'shift_fold_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'shift_fold_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id in (
  '53000000-0000-4000-8000-000000000001',
  '53000000-0000-4000-8000-000000000002',
  '53000000-0000-4000-8000-000000000003',
  '53000000-0000-4000-8000-000000000004',
  '53000000-0000-4000-8000-000000000005',
  '53000000-0000-4000-8000-000000000006');
