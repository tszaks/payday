-- PR 2, slice S5: tests for the one-shot migration, the counters, and rollback.
--
-- Same convention as the other four SQL suites: a plain psql script, every
-- assertion lands in a temporary results table, and the last statement raises
-- if any row is false, which makes psql exit non-zero under -v ON_ERROR_STOP=1.
--
-- CI (job E, "Supabase migrations (db reset)"), after `supabase db reset --local`:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/shift_migration_test.sql
--
-- Locally with no Docker: `bash scripts/db-test-local.sh`.
--
-- ONE STRUCTURAL RULE, PAID FOR IN S4 AND BINDING HERE: a mutation and its
-- assertion are NEVER in the same statement. A single SELECT has ONE snapshot,
-- so an inline subquery reading a table that a volatile function mutated
-- EARLIER IN THE SAME STATEMENT still sees the pre-statement value. In S4 that
-- produced a test that PASSED off a stale snapshot while its opposite
-- assertion on the next line failed. So: mutate in one statement, recording
-- the RPC's own return value into `calls`, and assert in the next.
--
-- A SECOND TRAP, MEASURED IN THIS FILE: `select (f()).*` on a
-- composite-returning function evaluates f ONCE PER OUTPUT COLUMN. The first
-- smoke run of the one-shot through `(f()).*` invoked it 25 times; the last
-- invocation had nothing left to do, so every invocation-scoped counter read 0
-- while migrated_at correctly held the FIRST run's instant. Every call below is
-- `select ... from public.migrate_tip_entries_to_shifts(...)`, which evaluates
-- once, and pg_temp.one_shot is the only spelling used.
--
-- HOW A "PRE-DEPLOY" ROW IS MADE. The one-shot exists for rows the trigger
-- never saw, so most fixtures here have to write public.tip_entries with the
-- fold suppressed. `set session_replication_role = replica` is NOT usable:
-- measured on Supabase, the postgres role is not a superuser and it fails with
-- "permission denied to set parameter". So the suppression is
-- `alter table public.tip_entries disable trigger <name>`, which is what
-- rollback itself uses, and every disable in this file is paired with an
-- enable in the next statement.
--
-- WHAT IS NOT IN HERE. The one-shot racing the trigger in both orders needs two
-- concurrent sessions, which a single psql script cannot produce; it lives in
-- scripts/db-test-race.sh alongside S4's five concurrency facts.

\set ON_ERROR_STOP on
\timing off
\pset pager off

create temporary table results (
  seq serial primary key, name text not null, ok boolean not null, detail text not null default '');

-- What a mutating statement returned, recorded by that statement so the
-- assertion in the NEXT statement can read it.
create temporary table calls (name text primary key, n integer, txt text);

create function pg_temp.expect(p_name text, p_ok boolean, p_detail text default '')
returns void language sql as $$
  insert into results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail);
$$;

create function pg_temp.called(p_name text) returns integer language sql as $$
  select n from calls where name = p_name;
$$;

create function pg_temp.called_txt(p_name text) returns text language sql as $$
  select txt from calls where name = p_name;
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

-- --------------------------------------------------------------------------
-- The 1.0-shaped write: the authenticated role, a JWT claim, and the shipped
-- public.upsert_tip_entries. Fires the fold.
-- --------------------------------------------------------------------------
create function pg_temp.device_upsert(p_user uuid, p_rows jsonb)
returns integer language plpgsql as $$
declare n integer;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.upsert_tip_entries(p_rows);
  reset role;
  return n;
end;
$$;

-- The shipped 1.0 soft delete, and the one narrow path by which the NEW build
-- writes tip_entries (the legacy tombstone flush of ShiftCommands.delete).
-- Returns the ids it actually tombstoned, because the rollback compensating
-- action is only safe if its RETURN SET equals the requested set.
create function pg_temp.device_delete(p_user uuid, p_ids uuid[])
returns uuid[] language plpgsql as $$
declare v uuid[];
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select coalesce(array_agg(x order by x), '{}'::uuid[]) into v
    from public.soft_delete_tip_entries(p_ids, now()) x;
  reset role;
  return v;
end;
$$;

-- The one-shot, as the account itself, exactly as the client calls it: no
-- p_user_id, and the budget the caller chose. Returns the audit row as jsonb so
-- one assertion can name several counters and report all of them on failure.
create function pg_temp.one_shot(p_user uuid, p_budget integer default 200,
                                 p_force_conservation boolean default false)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  if p_force_conservation then
    perform set_config('payday.migration_test_conservation', 'fail', true);
  end if;
  set local role authenticated;
  select to_jsonb(s) into v from public.migrate_tip_entries_to_shifts(null, p_budget) s;
  reset role;
  return v;
end;
$$;

-- The companion count, as the account itself, through the authenticated grant.
create function pg_temp.ucount(p_user uuid) returns integer language plpgsql as $$
declare n integer;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select public.payday_unmigrated_tip_row_count() into n;
  reset role;
  return n;
end;
$$;

create function pg_temp.rollback_stamp(p_user uuid) returns timestamptz
language plpgsql as $$
declare t timestamptz;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select public.payday_shift_rollback_at() into t;
  reset role;
  return t;
end;
$$;

create function pg_temp.state(p_user uuid) returns jsonb language sql as $$
  select coalesce((select to_jsonb(st) from public.shift_migration_state st
                    where st.user_id = p_user), 'null'::jsonb);
$$;

create function pg_temp.shift_facts(p_user uuid, p_key uuid) returns jsonb
language sql as $$
  select coalesce(
    (select to_jsonb(x) from (
       select s.work_date, s.cash_tips_cents, s.credit_tips_cents, s.tip_out_cents,
              s.non_wage_earnings_cents, s.source,
              coalesce(array_length(s.legacy_entry_ids, 1), 0) as prov,
              s.legacy_source_max_updated_at is not null as watermarked,
              s.deleted_at is not null as is_deleted, s.deleted_reason,
              s.native_modified_at is not null as is_closed,
              s.unconverted_legacy_cents
       from public.shifts s where s.user_id = p_user and s.id = p_key) x),
    'null'::jsonb);
$$;

-- Live shift count and summed non_wage_earnings_cents, the only two numbers
-- that decide whether money was doubled. Deliberately NOT keyed on any shift
-- id: the stale-claim shapes are about a night existing twice, sometimes on two
-- different dates, so the assertion has to be over the whole account.
create function pg_temp.live_money(p_user uuid) returns text language sql as $$
  select 'shifts=' || count(*) || ' cents=' || coalesce(sum(s.non_wage_earnings_cents), 0)
  from public.shifts s where s.user_id = p_user and s.deleted_at is null;
$$;

create function pg_temp.backlog_keys(p_user uuid) returns uuid[] language sql as $$
  select coalesce(array_agg(group_key order by group_key), '{}'::uuid[])
  from private.shift_fold_backlog where user_id = p_user;
$$;

create function pg_temp.conflicts(p_user uuid) returns text language sql as $$
  select coalesce(string_agg(shift_cents_before || '->' || legacy_cents_after, ' ' order by id), '')
  from public.shift_legacy_conflicts where user_id = p_user;
$$;

-- Every live shift of an account as one comparable blob, for the "rollback then
-- repair converges to the same rows" assertion.
create function pg_temp.shift_digest(p_user uuid) returns text language sql as $$
  select coalesce(string_agg(
    s.id || ':' || s.work_date || ':' || s.cash_tips_cents || '/' || s.credit_tips_cents
      || '/' || coalesce(s.tip_out_cents, -1) || '/' || s.non_wage_earnings_cents
      || ':' || s.source || ':' || coalesce(array_length(s.legacy_entry_ids, 1), 0),
    ' ' order by s.id), '')
  from public.shifts s where s.user_id = p_user and s.deleted_at is null;
$$;

create function pg_temp.trigger_states() returns text language sql as $$
  select coalesce(string_agg(t.tgname || '=' || t.tgenabled::text, ' ' order by t.tgname), 'none')
  from pg_trigger t
  where t.tgrelid = 'public.tip_entries'::regclass and t.tgname like 'tip_entries_fold_%';
$$;

-- N groups, one cash row each, written straight to public.tip_entries as the
-- owner with the fold suppressed: the pre-deploy shape.
create function pg_temp.seed_pre_deploy(p_user uuid, p_groups integer, p_seed integer)
returns integer language plpgsql as $$
declare n integer;
begin
  insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents,
                                  kind, client_updated_at)
  select ('56000000-0000-4000-9000-' || lpad((p_seed * 100000 + g)::text, 12, '0'))::uuid,
         p_user,
         ('56000000-0000-4000-a000-' || lpad((p_seed * 100000 + g)::text, 12, '0'))::uuid,
         date '2020-01-01' + g, 1000 + g, 'cash',
         timestamptz '2020-01-01 00:00:00Z' + (g || ' minutes')::interval
  from generate_series(1, p_groups) g;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Fixture accounts -----------------------------------------------------------

delete from auth.users where id in (
  '56000000-0000-4000-8000-000000000011','56000000-0000-4000-8000-000000000012',
  '56000000-0000-4000-8000-000000000013','56000000-0000-4000-8000-000000000014',
  '56000000-0000-4000-8000-000000000015','56000000-0000-4000-8000-000000000016',
  '56000000-0000-4000-8000-000000000017','56000000-0000-4000-8000-000000000018',
  '56000000-0000-4000-8000-000000000019',
  '56000000-0000-4000-8000-000000000021','56000000-0000-4000-8000-000000000022',
  '56000000-0000-4000-8000-000000000031','56000000-0000-4000-8000-000000000032',
  '56000000-0000-4000-8000-000000000033','56000000-0000-4000-8000-000000000041',
  '56000000-0000-4000-8000-000000000051','56000000-0000-4000-8000-000000000052',
  '56000000-0000-4000-8000-000000000061','56000000-0000-4000-8000-000000000071',
  '56000000-0000-4000-8000-000000000072','56000000-0000-4000-8000-000000000073',
  '56000000-0000-4000-8000-000000000081');
insert into auth.users (id, email) values
  ('56000000-0000-4000-8000-000000000011','payday-s5-arm1@test.invalid'),
  ('56000000-0000-4000-8000-000000000012','payday-s5-arm2@test.invalid'),
  ('56000000-0000-4000-8000-000000000013','payday-s5-arm3@test.invalid'),
  ('56000000-0000-4000-8000-000000000014','payday-s5-arm4@test.invalid'),
  ('56000000-0000-4000-8000-000000000015','payday-s5-arm5@test.invalid'),
  ('56000000-0000-4000-8000-000000000016','payday-s5-clean@test.invalid'),
  ('56000000-0000-4000-8000-000000000017','payday-s5-stale-shiftid@test.invalid'),
  ('56000000-0000-4000-8000-000000000018','payday-s5-stale-workdate@test.invalid'),
  ('56000000-0000-4000-8000-000000000019','payday-s5-stale-bulk@test.invalid'),
  ('56000000-0000-4000-8000-000000000021','payday-s5-dupes@test.invalid'),
  ('56000000-0000-4000-8000-000000000022','payday-s5-forced@test.invalid'),
  ('56000000-0000-4000-8000-000000000031','payday-s5-noflag1@test.invalid'),
  ('56000000-0000-4000-8000-000000000032','payday-s5-noflag2@test.invalid'),
  ('56000000-0000-4000-8000-000000000033','payday-s5-noflag3@test.invalid'),
  ('56000000-0000-4000-8000-000000000041','payday-s5-bulk@test.invalid'),
  ('56000000-0000-4000-8000-000000000051','payday-s5-miss1@test.invalid'),
  ('56000000-0000-4000-8000-000000000052','payday-s5-miss2@test.invalid'),
  ('56000000-0000-4000-8000-000000000061','payday-s5-dupday@test.invalid'),
  ('56000000-0000-4000-8000-000000000071','payday-s5-rb1@test.invalid'),
  ('56000000-0000-4000-8000-000000000072','payday-s5-rb2@test.invalid'),
  ('56000000-0000-4000-8000-000000000073','payday-s5-rb3-nostaterow@test.invalid'),
  ('56000000-0000-4000-8000-000000000081','payday-s5-auth@test.invalid');

-- =============================================================================
-- 1. Shape, single definition, and authority
-- =============================================================================

-- No p_strict, anywhere in PR 2. Conservation records on BOTH paths, and the
-- RPC path is the one where a raise would abort a caller's transaction.
select pg_temp.expect('theOneShotIsDefinerBoundedAndCarriesNoStrictFlag',
  (select p.prosecdef
      and pg_get_function_arguments(p.oid) like '%p_max_groups integer DEFAULT 200%'
      and p.prosrc not like '%p_strict%'
      and p.prosrc like '%pg_advisory_xact_lock%'
   from pg_proc p
   where p.oid = 'public.migrate_tip_entries_to_shifts(uuid, integer)'::regprocedure),
  (select 'definer=' || p.prosecdef || ' args=[' || pg_get_function_arguments(p.oid) || ']'
   from pg_proc p
   where p.oid = 'public.migrate_tip_entries_to_shifts(uuid, integer)'::regprocedure));

-- The one-shot raises nothing of its own except the two authority checks, and
-- in particular nothing on the conservation path.
select pg_temp.expect('theOnlyRaisesInTheOneShotAreTheTwoAuthorityChecks',
  (select count(*) = 2
   from pg_proc p, regexp_split_to_table(p.prosrc, E'\n') as line
   where p.oid = 'public.migrate_tip_entries_to_shifts(uuid, integer)'::regprocedure
     and regexp_replace(line, '--.*$', '') ~* '(^|[^[:alnum:]_])raise([^[:alnum:]_]|$)'),
  (select coalesce(string_agg(trim(regexp_replace(line, '--.*$', '')), ' / '), 'none')
   from pg_proc p, regexp_split_to_table(p.prosrc, E'\n') as line
   where p.oid = 'public.migrate_tip_entries_to_shifts(uuid, integer)'::regprocedure
     and regexp_replace(line, '--.*$', '') ~* '(^|[^[:alnum:]_])raise([^[:alnum:]_]|$)'));

-- ONE `unmigrated` EXPRESSION. The predicate text lives in exactly one function
-- body in the whole database, and both consumers reference that function by
-- name. This is what makes "the count and the one-shot cannot disagree" a
-- property of construction instead of an assertion.
select pg_temp.expect('theUnmigratedPredicateIsSpelledInExactlyOneFunctionBody',
  (select count(*) = 1 from pg_proc p
    where p.prosrc like '%legacy_source_max_updated_at is null%'
      and p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)),
  (select coalesce(string_agg(p.oid::regprocedure::text, ' ' order by p.oid::regprocedure::text), 'none')
   from pg_proc p
   where p.prosrc like '%legacy_source_max_updated_at is null%'
     and p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)));

select pg_temp.expect('bothConsumersReferenceTheSharedExpressionByName',
  (select bool_and(p.prosrc like '%unmigrated_legacy_rows%')
   from pg_proc p
   where p.oid in ('public.migrate_tip_entries_to_shifts(uuid, integer)'::regprocedure,
                   'public.payday_unmigrated_tip_row_count()'::regprocedure)),
  (select coalesce(string_agg(p.proname || '=' ||
            (p.prosrc like '%unmigrated_legacy_rows%')::text, ' ' order by p.proname), 'none')
   from pg_proc p
   where p.oid in ('public.migrate_tip_entries_to_shifts(uuid, integer)'::regprocedure,
                   'public.payday_unmigrated_tip_row_count()'::regprocedure)));

-- ROLLBACK TAKES NO ARGUMENT, and no overload that takes one exists. `alter
-- table ... disable trigger` is global, so a per-account signature would
-- disable conversion for everybody while stamping rollback_at for one account.
select pg_temp.expect('rollback_shift_migration_takes_no_argument_and_has_no_overload',
  (select count(*) = 1 and bool_and(p.pronargs = 0) from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'rollback_shift_migration'),
  (select coalesce(string_agg(p.oid::regprocedure::text, ' '), 'none') from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'rollback_shift_migration'));

select pg_temp.expect('rollbackDisablesTheTriggersInTheSameTransactionAsTheTombstoning',
  (select p.prosrc like '%disable trigger tip_entries_fold_insert%'
      and p.prosrc like '%disable trigger tip_entries_fold_update%'
      and p.prosrc like '%disable trigger tip_entries_fold_delete%'
      and p.prosrc not like '%commit%'
   from pg_proc p where p.oid = 'public.rollback_shift_migration()'::regprocedure),
  'checked against the shipped body');

select pg_temp.expect('payday_shift_rollback_at_is_stable_and_definer',
  (select p.provolatile = 's' and p.prosecdef
   from pg_proc p where p.oid = 'public.payday_shift_rollback_at()'::regprocedure),
  (select 'volatile=' || p.provolatile::text || ' definer=' || p.prosecdef
   from pg_proc p where p.oid = 'public.payday_shift_rollback_at()'::regprocedure));

-- The client's three functions are reachable; the two operator artifacts are
-- not, service_role included. rollback is a global kill switch that takes
-- ACCESS EXCLUSIVE on the app's only legacy write table.
select pg_temp.expect('theClientsThreeFunctionsAreExecutableByAuthenticated',
  (select bool_and(has_function_privilege('authenticated', f, 'execute'))
   from (values ('public.migrate_tip_entries_to_shifts(uuid, integer)'),
                ('public.payday_unmigrated_tip_row_count()'),
                ('public.payday_shift_rollback_at()')) v(f)),
  'migrate / count / rollback_at');

select pg_temp.expect('theTwoOperatorArtifactsAreExecutableByNobodyButTheOwner',
  (select not bool_or(has_function_privilege(r, f, 'execute'))
   from (values ('public.rollback_shift_migration()'),
                ('public.repair_shift_migration(uuid)')) v(f),
        (values ('anon'), ('authenticated'), ('service_role')) w(r)),
  (select coalesce(string_agg(r || ':' || f || '=' ||
            has_function_privilege(r, f, 'execute')::text, ' '), '')
   from (values ('public.rollback_shift_migration()'),
                ('public.repair_shift_migration(uuid)')) v(f),
        (values ('anon'), ('authenticated'), ('service_role')) w(r)
   where has_function_privilege(r, f, 'execute')));

-- A non-service-role caller may only name ITSELF.
select set_config('request.jwt.claims',
  json_build_object('sub', '56000000-0000-4000-8000-000000000081', 'role', 'authenticated')::text,
  true),
  pg_temp.outcome_of(
    'set local role authenticated;
     select * from public.migrate_tip_entries_to_shifts(
       ''56000000-0000-4000-8000-000000000011''::uuid, 10)') as sqlstate
\gset auth_
select pg_temp.expect('anAuthenticatedCallerMayNotNameAnotherAccount',
  :'auth_sqlstate' = '42501', 'sqlstate=' || :'auth_sqlstate');

-- =============================================================================
-- 2. theCompanionCountIsZeroExactlyWhenTheOneShotHasNothingToDo
--
-- One account per arm of the 5.2 predicate, plus a backlogged group, plus an
-- account with nothing to do at all. For each: the count is POSITIVE before the
-- run and ZERO after, and the run is the thing that made it zero.
--
-- A membership-only predicate would see arm 1 and nothing else, which is why
-- the other three exist: a live row folded by device A then tombstoned by
-- device B stays named and its money lives in the shift forever, and a
-- $50-to-$40 correction of an already-folded row never applies.
-- =============================================================================

-- ARM 1: a live row named by no shift. The pre-deploy shape.
alter table public.tip_entries disable trigger tip_entries_fold_insert;
insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
values ('56000000-0000-0000-0000-000000000111','56000000-0000-4000-8000-000000000011',
        '56000000-0000-0000-0000-000000000110','2026-07-04',5000,'cash','2026-07-04T23:00:00Z');
alter table public.tip_entries enable trigger tip_entries_fold_insert;

-- ARM 2: folded, then tombstoned with the fold suppressed, so the shift is
-- still naming a row that no longer exists on the legacy side.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000012',
  '[{"id":"56000000-0000-0000-0000-000000000121","shift_id":"56000000-0000-0000-0000-000000000120",
     "work_date":"2026-07-05","amount_cents":6000,"kind":"cash",
     "client_updated_at":"2026-07-05T23:00:00Z"}]'::jsonb);
alter table public.tip_entries disable trigger tip_entries_fold_update;
update public.tip_entries set deleted_at = now(), client_updated_at = now()
 where id = '56000000-0000-0000-0000-000000000121';
alter table public.tip_entries enable trigger tip_entries_fold_update;

-- ARM 3: a shift naming a live row with a NULL watermark. This is what a row
-- converted by anything that did not stamp the watermark looks like, and the
-- arm is what stops it being invisible forever.
alter table public.tip_entries disable trigger tip_entries_fold_insert;
insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
values ('56000000-0000-0000-0000-000000000131','56000000-0000-4000-8000-000000000013',
        '56000000-0000-0000-0000-000000000130','2026-07-06',4000,'cash','2026-07-06T23:00:00Z');
alter table public.tip_entries enable trigger tip_entries_fold_insert;
insert into public.shifts (user_id, id, work_date, cash_tips_cents, source,
                            legacy_entry_ids, legacy_source_max_updated_at, client_updated_at)
values ('56000000-0000-4000-8000-000000000013','56000000-0000-0000-0000-000000000130',
        '2026-07-06', 4000, 'migration',
        array['56000000-0000-0000-0000-000000000131'::uuid], null, '2026-07-06T23:00:00Z');

-- ARM 4: a $50-to-$40 correction of an already-folded row, arriving with the
-- fold suppressed. Only the watermark comparison can see it.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000014',
  '[{"id":"56000000-0000-0000-0000-000000000141","shift_id":"56000000-0000-0000-0000-000000000140",
     "work_date":"2026-07-07","amount_cents":5000,"kind":"cash",
     "client_updated_at":"2026-07-07T23:00:00Z"}]'::jsonb);
alter table public.tip_entries disable trigger tip_entries_fold_update;
update public.tip_entries set amount_cents = 4000, client_updated_at = '2026-07-08T09:00:00Z'
 where id = '56000000-0000-0000-0000-000000000141';
alter table public.tip_entries enable trigger tip_entries_fold_update;

-- ARM 5: a group with nothing unmigrated at all, present only in the backlog.
-- This is the try-lock loser's state, and it is why the count carries the
-- backlog term: its money is committed in tip_entries and named by NO shift
-- until the backlog drains.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000015',
  '[{"id":"56000000-0000-0000-0000-000000000151","shift_id":"56000000-0000-0000-0000-000000000150",
     "work_date":"2026-07-09","amount_cents":3000,"kind":"cash",
     "client_updated_at":"2026-07-09T23:00:00Z"}]'::jsonb);
insert into private.shift_fold_backlog (user_id, group_key)
values ('56000000-0000-4000-8000-000000000015','56000000-0000-0000-0000-000000000150');

-- The control: an ordinary converted account with nothing to do.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000016',
  '[{"id":"56000000-0000-0000-0000-000000000161","shift_id":"56000000-0000-0000-0000-000000000160",
     "work_date":"2026-07-10","amount_cents":2500,"kind":"cash",
     "client_updated_at":"2026-07-10T23:00:00Z"}]'::jsonb);

-- Counts BEFORE, all five arms plus the control, in one statement that mutates
-- nothing.
insert into calls (name, n, txt)
select 'counts_before', 0,
       pg_temp.ucount('56000000-0000-4000-8000-000000000011') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000012') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000013') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000014') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000015') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000016');

select pg_temp.expect('theCompanionCountIsPositiveOnEveryPredicateArmAndOnTheBacklog',
  pg_temp.called_txt('counts_before') = '1 1 1 1 1 0',
  'arm1 arm2 arm3 arm4 backlog control = ' || pg_temp.called_txt('counts_before'));

-- One run per account, each recording its own audit row.
insert into calls (name, n, txt)
select 'runs', 0,
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000011') ->> 'conservation_touched_count') || ' ' ||
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000012') ->> 'conservation_touched_count') || ' ' ||
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000013') ->> 'conservation_touched_count') || ' ' ||
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000014') ->> 'conservation_touched_count') || ' ' ||
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000015') ->> 'conservation_touched_count') || ' ' ||
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000016') ->> 'conservation_touched_count');

select pg_temp.expect('everyArmPresentsExactlyOneGroupAndTheControlPresentsNone',
  pg_temp.called_txt('runs') = '1 1 1 1 1 0',
  'touched per account = ' || pg_temp.called_txt('runs'));

insert into calls (name, n, txt)
select 'counts_after', 0,
       pg_temp.ucount('56000000-0000-4000-8000-000000000011') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000012') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000013') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000014') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000015') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000016');

select pg_temp.expect('theCompanionCountIsZeroExactlyWhenTheOneShotHasNothingToDo',
  pg_temp.called_txt('counts_after') = '0 0 0 0 0 0',
  'after one run each = ' || pg_temp.called_txt('counts_after'));

-- And the arms did the right thing, not merely something.
select pg_temp.expect('arm1_a_never_folded_row_is_converted',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000011',
                       '56000000-0000-0000-0000-000000000110') ->> 'cash_tips_cents') = '5000',
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000011','56000000-0000-0000-0000-000000000110')::text);

-- The measured miss sequence: without arm 2 the $60 would live in the shift
-- forever. Its last live row is gone, so the group empties, which tombstones
-- the artifact and releases its provenance.
select pg_temp.expect('arm2_a_tombstoned_row_stops_living_in_the_shift',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000012',
                       '56000000-0000-0000-0000-000000000120') ->> 'cash_tips_cents') = '0'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000012',
                           '56000000-0000-0000-0000-000000000120') ->> 'prov') = '0'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000012',
                           '56000000-0000-0000-0000-000000000120') ->> 'deleted_reason') = 'converted',
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000012','56000000-0000-0000-0000-000000000120')::text);

select pg_temp.expect('arm3_a_null_watermark_is_stamped',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000013',
                       '56000000-0000-0000-0000-000000000130') ->> 'watermarked') = 'true',
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000013','56000000-0000-0000-0000-000000000130')::text);

select pg_temp.expect('arm4_a_fifty_to_forty_correction_lands',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000014',
                       '56000000-0000-0000-0000-000000000140') ->> 'cash_tips_cents') = '4000',
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000014','56000000-0000-0000-0000-000000000140')::text);

select pg_temp.expect('arm5_the_backlogged_group_is_drained_in_the_same_transaction',
  pg_temp.backlog_keys('56000000-0000-4000-8000-000000000015') = '{}'::uuid[],
  'backlog=' || pg_temp.backlog_keys('56000000-0000-4000-8000-000000000015')::text);

-- =============================================================================
-- 2b. THE STALE CLAIM ARM, AND THE PHANTOM MONEY IT CLOSES.
--
-- Arms 1 to 4 all return a row's CURRENT group key. Every provenance-release
-- arm in the deriver is gated on `s.id = any(v_keys)`, so when a legacy row's
-- group key CHANGES while the fold is not firing -- a bulk legacy rewrite with
-- the triggers off, a replica-mode load, the disabled-trigger window rollback
-- itself opens -- the OLD claiming shift was never handed to the deriver. It
-- kept its money, kept its claim, and stayed LIVE. That is exactly the
-- trigger-blind population this whole file exists for, and it was the one case
-- the one-shot could not repair.
--
-- MEASURED before the arm existed, on the three shapes below: seven live
-- shifts and 70000 cents for five real nights and 50000 cents; two live shifts
-- at $60 each on ONE date for one $60 row; two live shifts at $40 each on TWO
-- DIFFERENT dates for one $40 row. Three passes of the one-shot and a
-- repair_shift_migration each reported remaining=2 dupes=2 and changed
-- nothing, and duplicate_work_date_count read 0 throughout, because its
-- detector needs one provenance row AND one native row on the date while here
-- both carry provenance. So no shipped function could clear it and no shipped
-- counter could see it.
--
-- EVERY STALE CLAIMER HERE IS THE REAL THING: open, source='migration', with
-- provenance and the money. The decoy in section 4 is deliberately harmless;
-- this is the shape that double-counts.
--
-- THE CONTROL IS THE SAME MOVE WITH THE TRIGGERS ON, which always converged,
-- because the fold unions OLD and NEW keys on UPDATE. It is
-- theSameMoveWithTheTriggersOnAlwaysConverged, in section 7's account.
-- =============================================================================

-- A shift_id move: one $60 row on one date acquires a real shift_id, so its
-- group key changes while the date does not. Folded live FIRST, so the stale
-- claimer is a genuine artifact holding genuine money.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000017',
  '[{"id":"56000000-0000-0000-0000-000000000171",
     "work_date":"2026-08-01","amount_cents":6000,"kind":"cash",
     "client_updated_at":"2026-08-01T23:00:00Z"}]'::jsonb);
insert into calls (name, n, txt)
select 'stale_17_truth', 0, pg_temp.live_money('56000000-0000-4000-8000-000000000017');
alter table public.tip_entries disable trigger tip_entries_fold_update;
update public.tip_entries set shift_id = '56000000-0000-0000-0000-0000000001a7',
                              client_updated_at = '2026-08-02T09:00:00Z'
 where id = '56000000-0000-0000-0000-000000000171';
alter table public.tip_entries enable trigger tip_entries_fold_update;

-- A work_date move: the same row, the same money, an adjacent civil day. This
-- is what a relocated 1.0 device re-pushing its own row looks like, and it is
-- the shape whose duplicate lands on TWO DIFFERENT DATES and is therefore
-- invisible to a work_date-grouped duplicate detector.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000018',
  '[{"id":"56000000-0000-0000-0000-000000000181",
     "work_date":"2026-08-03","amount_cents":4000,"kind":"cash",
     "client_updated_at":"2026-08-03T23:00:00Z"}]'::jsonb);
insert into calls (name, n, txt)
select 'stale_18_truth', 0, pg_temp.live_money('56000000-0000-4000-8000-000000000018');
alter table public.tip_entries disable trigger tip_entries_fold_update;
update public.tip_entries set work_date = '2026-08-04',
                              client_updated_at = '2026-08-05T09:00:00Z'
 where id = '56000000-0000-0000-0000-000000000181';
alter table public.tip_entries enable trigger tip_entries_fold_update;

-- The headline: five nights at $100 folded live, then a bulk legacy rewrite
-- re-keys two of them with the triggers off. shift_migration_state carries
-- bulk_legacy_rewrite_at precisely because this is a contemplated operation,
-- and rollback_shift_migration disables all three triggers globally.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000019', (
  select jsonb_agg(jsonb_build_object(
    'id', ('56000000-0000-0000-0000-00000000019' || g)::uuid,
    'work_date', (date '2026-08-10' + g)::text,
    'amount_cents', 10000, 'kind', 'cash',
    'client_updated_at', (timestamptz '2026-08-10 23:00:00Z' + (g || ' days')::interval)))
  from generate_series(1, 5) g));
insert into calls (name, n, txt)
select 'stale_19_truth', 0, pg_temp.live_money('56000000-0000-4000-8000-000000000019');
alter table public.tip_entries disable trigger tip_entries_fold_update;
update public.tip_entries
   set shift_id = ('56000000-0000-0000-0000-0000000001b' ||
                   right(id::text, 1))::uuid,
       client_updated_at = '2026-08-20T09:00:00Z'
 where id in ('56000000-0000-0000-0000-000000000192',
              '56000000-0000-0000-0000-000000000194');
alter table public.tip_entries enable trigger tip_entries_fold_update;

-- The truths, pinned as literals as well as captured, so a fixture that
-- silently stopped folding could not make the convergence assertions vacuous.
select pg_temp.expect('theStaleClaimFixturesFoldedTheirTruthBeforeTheKeyMoved',
  pg_temp.called_txt('stale_17_truth') = 'shifts=1 cents=6000'
  and pg_temp.called_txt('stale_18_truth') = 'shifts=1 cents=4000'
  and pg_temp.called_txt('stale_19_truth') = 'shifts=5 cents=50000',
  '17=' || coalesce(pg_temp.called_txt('stale_17_truth'),'null')
    || ' 18=' || coalesce(pg_temp.called_txt('stale_18_truth'),'null')
    || ' 19=' || coalesce(pg_temp.called_txt('stale_19_truth'),'null'));

-- The arm returns one row per (entry, key that needs work), so a stale-claimed
-- row contributes TWO: its current key, which builds the right artifact, and
-- the stale claimer's id, which releases the wrong one. That is accurate, not
-- inflated -- there really are two group keys to derive.
insert into calls (name, n, txt)
select 'stale_counts_before', 0,
       pg_temp.ucount('56000000-0000-4000-8000-000000000017') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000018') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000019');

select pg_temp.expect('theStaleClaimArmPresentsBothTheNewKeyAndTheStaleClaimer',
  pg_temp.called_txt('stale_counts_before') = '2 2 4',
  '17 18 19 = ' || coalesce(pg_temp.called_txt('stale_counts_before'),'null'));

-- One pass each.
insert into calls (name, n, txt)
select 'stale_runs', 0,
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000017') ->> 'conservation_duplicate_claim_count') || ' ' ||
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000018') ->> 'conservation_duplicate_claim_count') || ' ' ||
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000019') ->> 'conservation_duplicate_claim_count');

-- THE MONEY ASSERTION. Live shift count and summed non_wage_earnings_cents
-- equal the pre-move truth, on all three shapes. Before the arm these read
-- 'shifts=2 cents=12000', 'shifts=2 cents=8000' and 'shifts=7 cents=70000'.
select pg_temp.expect('aStaleClaimerIsReleasedRatherThanDoublingTheMoney',
  pg_temp.live_money('56000000-0000-4000-8000-000000000017') = pg_temp.called_txt('stale_17_truth')
  and pg_temp.live_money('56000000-0000-4000-8000-000000000018') = pg_temp.called_txt('stale_18_truth')
  and pg_temp.live_money('56000000-0000-4000-8000-000000000019') = pg_temp.called_txt('stale_19_truth'),
  '17=' || pg_temp.live_money('56000000-0000-4000-8000-000000000017')
    || ' (truth ' || coalesce(pg_temp.called_txt('stale_17_truth'),'null') || ')'
    || ' 18=' || pg_temp.live_money('56000000-0000-4000-8000-000000000018')
    || ' (truth ' || coalesce(pg_temp.called_txt('stale_18_truth'),'null') || ')'
    || ' 19=' || pg_temp.live_money('56000000-0000-4000-8000-000000000019')
    || ' (truth ' || coalesce(pg_temp.called_txt('stale_19_truth'),'null') || ')');

-- The night MOVED, it was not merely deduplicated: the work_date shape's one
-- live shift sits on the NEW date, and the old artifact is a 'converted'
-- tombstone with no provenance left.
select pg_temp.expect('theSurvivingShiftIsTheNewKeyAndTheOldArtifactIsATombstoneWithNoClaim',
  (select work_date::text = '2026-08-04' and non_wage_earnings_cents = 4000
     from public.shifts where user_id = '56000000-0000-4000-8000-000000000018'
       and deleted_at is null)
  and (select deleted_reason = 'converted' and coalesce(array_length(legacy_entry_ids,1),0) = 0
         from public.shifts
        where user_id = '56000000-0000-4000-8000-000000000018'
          and id = public.payday_legacy_shift_id('2026-08-03')),
  'live=' || (select coalesce(string_agg(work_date || '=' || non_wage_earnings_cents, ' '), 'none')
                from public.shifts where user_id = '56000000-0000-4000-8000-000000000018'
                  and deleted_at is null)
    || ' old=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000018',
                                      public.payday_legacy_shift_id('2026-08-03'))::text);

-- ...and the count reaches ZERO, so the client stops re-invoking. Before the
-- arm it read 2 forever on the single-row shapes and 2 forever on the bulk one,
-- with conservation_duplicate_claim_count stuck at 1 and 2 respectively.
insert into calls (name, n, txt)
select 'stale_counts_after', 0,
       pg_temp.ucount('56000000-0000-4000-8000-000000000017') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000018') || ' ' ||
       pg_temp.ucount('56000000-0000-4000-8000-000000000019');

select pg_temp.expect('theStaleClaimArmTerminatesAndTheDuplicateIsGone',
  pg_temp.called_txt('stale_counts_after') = '0 0 0'
  and pg_temp.called_txt('stale_runs') = '0 0 0',
  'counts after = ' || coalesce(pg_temp.called_txt('stale_counts_after'),'null')
    || ' dupes during = ' || coalesce(pg_temp.called_txt('stale_runs'),'null'));

-- And a further pass is a no-op rather than a re-derive, which is what makes
-- the arm safe to leave in the predicate forever.
insert into calls (name, n, txt)
select 'stale_19_second_pass', 0,
  (pg_temp.one_shot('56000000-0000-4000-8000-000000000019') ->> 'conservation_touched_count');

select pg_temp.expect('aSecondPassOverAConvergedStaleClaimAccountTouchesNothing',
  pg_temp.called_txt('stale_19_second_pass') = '0'
  and pg_temp.live_money('56000000-0000-4000-8000-000000000019') = pg_temp.called_txt('stale_19_truth'),
  'touched=' || coalesce(pg_temp.called_txt('stale_19_second_pass'),'null')
    || ' ' || pg_temp.live_money('56000000-0000-4000-8000-000000000019'));

-- =============================================================================
-- 3. two_consecutive_no_op_invocations_leave_migrated_at_byte_identical
--
-- MEASURED on the first draft: a second call with nothing unmigrated moved
-- migrated_at from 15:38:00.45385 to 15:38:00.491464. Not rare -- the client
-- re-invokes whenever the count is positive, and a reinstalled device meeting
-- an already-converted server lands here exactly.
-- =============================================================================

-- The account under test is arm 1's, because the ONE-SHOT is what converted it.
-- MEASURED, and it is the reason this test does not use the control account:
-- migrated_at is written only when a run's wrote_count is positive, so an
-- account the TRIGGER converted end to end never gets a migrated_at at all,
-- and asserting "byte identical" over two nulls is a test that cannot fail.
-- That vacuity is pinned below rather than papered over.
insert into calls (name, n, txt)
select 'noop_migrated_at', 0,
       (pg_temp.state('56000000-0000-4000-8000-000000000011') ->> 'migrated_at');

select pg_temp.expect('theMigratedAtUnderTestIsActuallySetSoTheNextAssertionIsNotVacuous',
  pg_temp.called_txt('noop_migrated_at') is not null,
  'migrated_at=' || coalesce(pg_temp.called_txt('noop_migrated_at'), 'NULL'));

insert into calls (name, n, txt)
select 'noop_second', 0,
       (pg_temp.one_shot('56000000-0000-4000-8000-000000000011') ->> 'migrated_at');

select pg_temp.expect('two_consecutive_no_op_invocations_leave_migrated_at_byte_identical',
  pg_temp.called_txt('noop_migrated_at') is not distinct from
    (pg_temp.state('56000000-0000-4000-8000-000000000011') ->> 'migrated_at')
  and pg_temp.called_txt('noop_second') is not distinct from
    pg_temp.called_txt('noop_migrated_at'),
  'before=[' || coalesce(pg_temp.called_txt('noop_migrated_at'), 'null')
    || '] returned=[' || coalesce(pg_temp.called_txt('noop_second'), 'null')
    || '] after=[' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000011') ->> 'migrated_at', 'null') || ']');

-- last_run_at DOES move on a no-op, so "when did this account last try?" stays
-- answerable. If both were frozen there would be no way to tell a converged
-- account from one whose client stopped calling.
select pg_temp.expect('last_run_at_moves_on_a_no_op_even_though_migrated_at_does_not',
  (pg_temp.state('56000000-0000-4000-8000-000000000011') ->> 'last_run_at')::timestamptz
    > (pg_temp.state('56000000-0000-4000-8000-000000000011') ->> 'migrated_at')::timestamptz,
  'last_run_at=' || (pg_temp.state('56000000-0000-4000-8000-000000000011') ->> 'last_run_at')
    || ' migrated_at=' || (pg_temp.state('56000000-0000-4000-8000-000000000011') ->> 'migrated_at'));

-- REVERSED 2026-09-19. The original comment is kept verbatim below because it
-- recorded a real intent that turned out to CONTRADICT THE CLIENT:
--
--   "An account the on-arrival trigger converted end to end has NO
--    migrated_at, because the one-shot never had anything to write. That is
--    correct ... the client's readiness fact is remaining_group_count
--    reaching zero, and the 'is any old build still writing' fact is
--    last_legacy_write_at, which the fold stamps."
--
-- The client does not do that. `ShiftReadAuthority.isAuthoritative` opens with
-- `guard state.migratedAt != nil` and only then checks the remainder. So the
-- server treated such an account as ready and the client treated it as
-- un-converted, permanently. TWO DEFINITIONS OF ONE FACT, which is the thing
-- this project exists to end. Measured consequence: an account with no legacy
-- rows, or one the trigger converted end to end, never flipped, and all
-- eleven flip-gated call sites took the legacy branch -- writers included, so
-- it logged tip_entries forever and the records engine never activated.
--
-- The client's guard is the correct half and stays. With no state row at all
-- `remaining_group_count` is null and `(nil ?? 0) == 0` is TRUE, so without a
-- stamp "never checked" and "finished" are the same value -- the
-- empty-versus-refused confusion in a different column.
--
-- The stamp now records COMPLETION rather than work done, so this assertion
-- inverts: the trigger-converted account HAS a migrated_at once the one-shot
-- has run for it. remaining_group_count and last_legacy_write_at are
-- unchanged and still asserted.
select pg_temp.expect('anAccountTheTriggerConvertedEndToEndIsStampedOnceTheOneShotRuns',
  (pg_temp.state('56000000-0000-4000-8000-000000000016') ->> 'migrated_at') is not null
  and (pg_temp.state('56000000-0000-4000-8000-000000000016') ->> 'remaining_group_count') = '0'
  and (pg_temp.state('56000000-0000-4000-8000-000000000016') ->> 'last_legacy_write_at') is not null,
  'migrated_at=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000016') ->> 'migrated_at','null')
    || ' remaining=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000016') ->> 'remaining_group_count','null')
    || ' last_legacy_write_at=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000016') ->> 'last_legacy_write_at','null'));

-- =============================================================================
-- 4. The conservation check: recorded, scoped, never raised
-- =============================================================================

-- the_dupes_count_is_never_null, on the ordinary path. MEASURED on the earlier
-- form (count(*) from a subquery with GROUP BY ... HAVING count(*) > 1): it
-- returns one arbitrary group's OCCURRENCE count and NULL when there are no
-- duplicates, which is why every real raise printed dupes=<NULL> and read as
-- "the check did not run". It silently disabled half the check for a whole
-- review round.
select pg_temp.expect('the_dupes_count_is_never_null',
  (select bool_and((pg_temp.state(u) ->> 'conservation_duplicate_claim_count') = '0')
   from (values ('56000000-0000-4000-8000-000000000011'::uuid),
                ('56000000-0000-4000-8000-000000000012'::uuid),
                ('56000000-0000-4000-8000-000000000013'::uuid),
                ('56000000-0000-4000-8000-000000000014'::uuid),
                ('56000000-0000-4000-8000-000000000015'::uuid),
                ('56000000-0000-4000-8000-000000000016'::uuid)) v(u)),
  (select coalesce(string_agg(coalesce(pg_temp.state(u) ->> 'conservation_duplicate_claim_count', 'NULL'), ' '), '')
   from (values ('56000000-0000-4000-8000-000000000011'::uuid),
                ('56000000-0000-4000-8000-000000000012'::uuid),
                ('56000000-0000-4000-8000-000000000013'::uuid),
                ('56000000-0000-4000-8000-000000000014'::uuid),
                ('56000000-0000-4000-8000-000000000015'::uuid),
                ('56000000-0000-4000-8000-000000000016'::uuid)) v(u)));

-- a_wrong_partition_is_still_recorded.
--
-- The state is REACHABLE, not fabricated: a decoy shift claims a legacy row
-- that a group the one-shot is about to derive also owns. The predicate the
-- check asserts is a PARTITION, never a count bijection -- every captured
-- source row is claimed by exactly one shift, live or deleted -- because
-- public.update_tip_entry accepts shift_id, so an agent may already have moved
-- a row, and an account with zero legacy rows must pass trivially.
alter table public.tip_entries disable trigger tip_entries_fold_insert;
insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
values ('56000000-0000-0000-0000-000000000211','56000000-0000-4000-8000-000000000021',
        '56000000-0000-0000-0000-000000000210','2026-07-11',7000,'cash','2026-07-11T23:00:00Z');
alter table public.tip_entries enable trigger tip_entries_fold_insert;
-- The decoy. Its own id is NOT a group key, so the one-shot never touches it
-- and never releases its claim; it just claims somebody else's row. It is
-- CLOSED, which is what a row an agent moved onto a natively edited shift looks
-- like.
--
-- ITS BUDGET IS 1, AND THAT IS NOT DECORATION EITHER. Once the predicate grew
-- its stale-claim arm (section 2b) the decoy's own id IS presented as a group
-- key, so at the default budget the deriver releases the rogue claim in the
-- same invocation that creates the real artifact and there is no duplicate left
-- to record. That is the correct repair, and it is what section 2b asserts. The
-- duplicate is therefore pinned in the state that is still genuinely
-- reachable: a budget that affords the NEW key but not the stale claimer, which
-- is every partially converged multi-year account mid-convergence. The two keys
-- tie on min(client_updated_at) and break on group_key, and ...0210 sorts
-- before ...02ff, so pass 1 deterministically spends its one group on the real
-- key and leaves the rogue claim standing.
--
-- ITS WATERMARK IS NULL, AND THAT IS NOT DECORATION. MEASURED: with the
-- watermark set to the row's own client_updated_at, the decoy's claim satisfied
-- the predicate's "named, current" reading and the row looked MIGRATED -- arm 1
-- false because it is named, arms 2 and 3 false, arm 4 false because it is not
-- above the watermark -- so the one-shot had nothing to do, no second claim was
-- ever created, and the duplicate test passed vacuously with dupes=0 and no
-- converted shift. A rogue claim can therefore HIDE a legacy row from the
-- predicate, which is exactly the class of drift the duplicate half of the
-- conservation check exists to report. Arm 3 (named with a null watermark) is
-- what finds it here.
insert into public.shifts (user_id, id, work_date, cash_tips_cents, source,
                            legacy_entry_ids, legacy_source_max_updated_at, client_updated_at,
                            native_modified_at)
values ('56000000-0000-4000-8000-000000000021','56000000-0000-0000-0000-0000000002ff',
        '2026-07-11', 0, 'device',
        array['56000000-0000-0000-0000-000000000211'::uuid], null,
        '2026-07-11T23:00:00Z', '2026-07-11T23:00:00Z');

insert into calls (name, n, txt)
select 'dupes_run', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000021', 1)::text;

select pg_temp.expect('a_wrong_partition_is_still_recorded',
  (pg_temp.state('56000000-0000-4000-8000-000000000021') ->> 'conservation_duplicate_claim_count') = '1'
  and (pg_temp.state('56000000-0000-4000-8000-000000000021') ->> 'conservation_failed_at') is not null,
  'dupes=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000021') ->> 'conservation_duplicate_claim_count','NULL')
    || ' flagged=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000021') ->> 'conservation_failed_at','NULL'));

-- ...and it COMMITTED. The audit row exists, the conversion happened, and the
-- caller got a row back rather than an exception. A raise here would abort the
-- caller's transaction, which S4 already paid for: anything that can abort is
-- an app that goes dark for a shipped 1.0 build.
select pg_temp.expect('a_wrong_partition_commits_rather_than_raising',
  pg_temp.called_txt('dupes_run') is not null
  and pg_temp.called_txt('dupes_run') <> 'null'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000021',
                           '56000000-0000-0000-0000-000000000210') ->> 'cash_tips_cents') = '7000',
  'returned=' || left(coalesce(pg_temp.called_txt('dupes_run'), 'NULL'), 40)
    || ' converted=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000021',
                                            '56000000-0000-0000-0000-000000000210')::text);

-- ...AND THE NEXT PASS CLEARS IT, which is the half no shipped function could
-- do before the stale-claim arm existed. The duplicate is a real, reported,
-- SELF-HEALING state rather than a permanent one: the next pass spends budget
-- on the rogue claimer's own id, the deriver's arm 2a empties its
-- legacy_entry_ids, and the predicate reaches 0.
--
-- THE CLEARING PASS TAKES THE DEFAULT BUDGET, WHICH IS WHAT THE CLIENT PASSES,
-- AND THE REASON IS MEASURED. A second budget-1 pass changes nothing: the two
-- keys tie on min(client_updated_at) -- they are the same entry's timestamp --
-- so the ordering breaks on group_key and picks ...0210 again, while the
-- rogue claim's NULL watermark keeps arm 3 regenerating that same key. So a
-- stale-claim PAIR needs a budget of 2 to converge, and at a budget of exactly
-- 1 it makes no forward progress. That is an operator-only shape: the client
-- passes the 200 default, repair_shift_migration passes 1,000,000, and
-- remaining_group_count stays FLAT rather than rising, so the client's
-- strictly-decreasing follow-up rule stops calling instead of hot-looping.
-- Written down rather than papered over, because the alternative -- ordering
-- the release key ahead of its partner -- would make
-- conservation_duplicate_claim_count unreachable and silently retire half of
-- the conservation check.
insert into calls (name, n, txt)
select 'dupes_second_pass', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000021')::text;

select pg_temp.expect('theRogueClaimIsReleasedByTheNextPassAndTheDuplicateClears',
  (pg_temp.state('56000000-0000-4000-8000-000000000021') ->> 'conservation_duplicate_claim_count') = '0'
  and pg_temp.ucount('56000000-0000-4000-8000-000000000021') = 0
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000021',
                           '56000000-0000-0000-0000-0000000002ff') ->> 'prov') = '0'
  and pg_temp.live_money('56000000-0000-4000-8000-000000000021') = 'shifts=2 cents=7000',
  'dupes=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000021') ->> 'conservation_duplicate_claim_count','NULL')
    || ' count=' || pg_temp.ucount('56000000-0000-4000-8000-000000000021')
    || ' decoy=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000021','56000000-0000-0000-0000-0000000002ff')::text
    || ' ' || pg_temp.live_money('56000000-0000-4000-8000-000000000021'));

-- conservation_failed_at is a HISTORY and is never cleared, so the flag the
-- duplicate pass raised is still there after the repair. That is deliberate:
-- Data health renders it.
select pg_temp.expect('theConservationFlagSurvivesTheRepairBecauseItIsAHistory',
  (pg_temp.state('56000000-0000-4000-8000-000000000021') ->> 'conservation_failed_at') is not null,
  'flagged=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000021') ->> 'conservation_failed_at','NULL'));

-- a_wrong_money_split_is_still_recorded.
--
-- WHY THIS ONE IS FORCED, WRITTEN DOWN BECAUSE IT IS A FINDING AND NOT A
-- SHORTCUT. With the closed-shift exclusion in place the two money halves
-- CANNOT be unequal after a correct derive on this path: arm 1 rewrites every
-- OPEN shift's money from the very grouped row the "in" side is summed from,
-- and every shift either side excludes -- closed, deleted, future-dated,
-- provenance-free -- is excluded by BOTH. The design's own measured inequality
-- (in=8200 out=9200 after one legal edit) was taken with provenance-only
-- scoping, and the closed-shift exclusion is exactly what removed it. So the
-- reachable states are covered by the three no-flag tests below, and the
-- RECORDING path is proven here through payday.migration_test_conservation,
-- the same hook shape as the fold's payday.fold_test_abort. It sets the flag
-- and touches no money.
insert into calls (name, n, txt)
select 'forced_run', 0,
       pg_temp.one_shot('56000000-0000-4000-8000-000000000022', 200, true)::text;

select pg_temp.expect('a_wrong_money_split_is_still_recorded',
  (pg_temp.state('56000000-0000-4000-8000-000000000022') ->> 'conservation_failed_at') is not null,
  'flagged=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000022') ->> 'conservation_failed_at','NULL'));

select pg_temp.expect('a_wrong_money_split_commits_rather_than_raising',
  pg_temp.called_txt('forced_run') is not null and pg_temp.called_txt('forced_run') <> 'null',
  'returned=' || left(coalesce(pg_temp.called_txt('forced_run'), 'NULL'), 60));

-- The flag is a HISTORY: a later clean run never clears it, because Data health
-- renders "this account was flagged" and silently un-flagging would erase the
-- one signal that says look here.
insert into calls (name, n, txt)
select 'forced_rerun', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000022')::text;

select pg_temp.expect('a_clean_later_run_never_clears_conservation_failed_at',
  (pg_temp.state('56000000-0000-4000-8000-000000000022') ->> 'conservation_failed_at') is not null,
  'still flagged=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000022') ->> 'conservation_failed_at','NULL'));

-- The orphan half is zero BY CONSTRUCTION, and that is worth pinning: arm 1
-- writes provenance unconditionally with no WHERE on its ON CONFLICT, so every
-- captured live row is claimed. A non-zero value means an upsert was silently
-- skipped, which is the exact failure the ON CONFLICT lint exists to prevent.
select pg_temp.expect('the_orphan_count_is_zero_and_never_null_on_every_account_run_so_far',
  (select bool_and((pg_temp.state(u) ->> 'conservation_orphan_count') = '0')
   from (values ('56000000-0000-4000-8000-000000000011'::uuid),
                ('56000000-0000-4000-8000-000000000012'::uuid),
                ('56000000-0000-4000-8000-000000000013'::uuid),
                ('56000000-0000-4000-8000-000000000014'::uuid),
                ('56000000-0000-4000-8000-000000000015'::uuid),
                ('56000000-0000-4000-8000-000000000016'::uuid),
                ('56000000-0000-4000-8000-000000000021'::uuid)) v(u)),
  (select coalesce(string_agg(coalesce(pg_temp.state(u) ->> 'conservation_orphan_count','NULL'), ' '), '')
   from (values ('56000000-0000-4000-8000-000000000011'::uuid),
                ('56000000-0000-4000-8000-000000000012'::uuid),
                ('56000000-0000-4000-8000-000000000013'::uuid),
                ('56000000-0000-4000-8000-000000000014'::uuid),
                ('56000000-0000-4000-8000-000000000015'::uuid),
                ('56000000-0000-4000-8000-000000000016'::uuid),
                ('56000000-0000-4000-8000-000000000021'::uuid)) v(u)));

-- =============================================================================
-- 5. The three states that must NOT record anything
-- =============================================================================

-- aNativelyEditedShiftWhoseLegacyRowsWereDeletedDoesNotFlagConservation.
--
-- The most ordinary sequence there is, and the one the first draft's p_strict
-- raised on for run 1, run 2 and run 3: an old build logs $50, the user
-- corrects the night on the new build, then the old phone deletes the tip. The
-- user's edit wins, the disagreement is recorded as a conflict, and
--conservation says nothing, because both sides exclude a closed shift.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000031',
  '[{"id":"56000000-0000-0000-0000-000000000311","shift_id":"56000000-0000-0000-0000-000000000310",
     "work_date":"2026-07-12","amount_cents":5000,"kind":"cash",
     "client_updated_at":"2026-07-12T23:00:00Z"}]'::jsonb);
-- The native edit S6 will make: money changed, native_modified_at stamped.
update public.shifts set cash_tips_cents = 6000, native_modified_at = now(),
                         client_updated_at = now()
 where user_id = '56000000-0000-4000-8000-000000000031'
   and id = '56000000-0000-0000-0000-000000000310';
-- The old phone's deletion, arriving in a window the trigger did not see, so
-- the ONE-SHOT is the thing that has to handle it.
alter table public.tip_entries disable trigger tip_entries_fold_update;
update public.tip_entries set deleted_at = now(), client_updated_at = now()
 where id = '56000000-0000-0000-0000-000000000311';
alter table public.tip_entries enable trigger tip_entries_fold_update;

insert into calls (name, n, txt)
select 'noflag1', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000031')::text;

select pg_temp.expect('aNativelyEditedShiftWhoseLegacyRowsWereDeletedDoesNotFlagConservation',
  (pg_temp.state('56000000-0000-4000-8000-000000000031') ->> 'conservation_failed_at') is null
  and (pg_temp.called_txt('noflag1')::jsonb ->> 'conservation_touched_count') = '1',
  'flagged=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000031') ->> 'conservation_failed_at','null')
    || ' touched=' || coalesce(pg_temp.called_txt('noflag1')::jsonb ->> 'conservation_touched_count','null')
    || ' in=' || coalesce(pg_temp.called_txt('noflag1')::jsonb ->> 'source_non_wage_cents','null')
    || ' out=' || coalesce(pg_temp.called_txt('noflag1')::jsonb ->> 'shift_non_wage_cents','null'));

-- The user's edit survived, the provenance claim was released, and the
-- disagreement was SURFACED rather than silently retained.
select pg_temp.expect('theEditedShiftKeepsItsMoneyReleasesItsClaimAndRecordsAConflict',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000031',
                       '56000000-0000-0000-0000-000000000310') ->> 'cash_tips_cents') = '6000'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000031',
                           '56000000-0000-0000-0000-000000000310') ->> 'prov') = '0'
  and pg_temp.conflicts('56000000-0000-4000-8000-000000000031') = '6000->0',
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000031','56000000-0000-0000-0000-000000000310')::text
    || ' conflicts=[' || pg_temp.conflicts('56000000-0000-4000-8000-000000000031') || ']');

-- aClosedGroupInTheBacklogDrainsWithoutFlagging. The try-lock loser queued a
-- group whose shift the user has since edited. The drain must not flag, must
-- not rewrite the user's money, and must still empty the backlog.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000032',
  '[{"id":"56000000-0000-0000-0000-000000000321","shift_id":"56000000-0000-0000-0000-000000000320",
     "work_date":"2026-07-13","amount_cents":4500,"kind":"cash",
     "client_updated_at":"2026-07-13T23:00:00Z"}]'::jsonb);
update public.shifts set cash_tips_cents = 8000, native_modified_at = now(),
                         client_updated_at = now()
 where user_id = '56000000-0000-4000-8000-000000000032'
   and id = '56000000-0000-0000-0000-000000000320';
insert into private.shift_fold_backlog (user_id, group_key)
values ('56000000-0000-4000-8000-000000000032','56000000-0000-0000-0000-000000000320');

insert into calls (name, n, txt)
select 'noflag2', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000032')::text;

select pg_temp.expect('aClosedGroupInTheBacklogDrainsWithoutFlagging',
  (pg_temp.state('56000000-0000-4000-8000-000000000032') ->> 'conservation_failed_at') is null
  and pg_temp.backlog_keys('56000000-0000-4000-8000-000000000032') = '{}'::uuid[]
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000032',
                           '56000000-0000-0000-0000-000000000320') ->> 'cash_tips_cents') = '8000',
  'flagged=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000032') ->> 'conservation_failed_at','null')
    || ' backlog=' || pg_temp.backlog_keys('56000000-0000-4000-8000-000000000032')::text
    || ' ' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000032','56000000-0000-0000-0000-000000000320')::text);

-- aLegalEditFollowedByThreeReInvocationsNeverFlags. The group is re-presented
-- through the backlog before each of the three runs, so all three genuinely
-- re-derive a closed, edited shift instead of finding nothing to do.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000033',
  '[{"id":"56000000-0000-0000-0000-000000000331","shift_id":"56000000-0000-0000-0000-000000000330",
     "work_date":"2026-07-14","amount_cents":5000,"kind":"cash",
     "client_updated_at":"2026-07-14T23:00:00Z"},
    {"id":"56000000-0000-0000-0000-000000000332","shift_id":"56000000-0000-0000-0000-000000000330",
     "work_date":"2026-07-14","amount_cents":2000,"kind":"credit",
     "client_updated_at":"2026-07-14T23:05:00Z"}]'::jsonb);
update public.shifts set cash_tips_cents = 6000, native_modified_at = now(),
                         client_updated_at = now()
 where user_id = '56000000-0000-4000-8000-000000000033'
   and id = '56000000-0000-0000-0000-000000000330';

insert into private.shift_fold_backlog (user_id, group_key)
values ('56000000-0000-4000-8000-000000000033','56000000-0000-0000-0000-000000000330')
on conflict do nothing;
select pg_temp.one_shot('56000000-0000-4000-8000-000000000033');
insert into private.shift_fold_backlog (user_id, group_key)
values ('56000000-0000-4000-8000-000000000033','56000000-0000-0000-0000-000000000330')
on conflict do nothing;
select pg_temp.one_shot('56000000-0000-4000-8000-000000000033');
insert into private.shift_fold_backlog (user_id, group_key)
values ('56000000-0000-4000-8000-000000000033','56000000-0000-0000-0000-000000000330')
on conflict do nothing;
insert into calls (name, n, txt)
select 'noflag3_last', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000033')::text;

select pg_temp.expect('aLegalEditFollowedByThreeReInvocationsNeverFlags',
  (pg_temp.state('56000000-0000-4000-8000-000000000033') ->> 'conservation_failed_at') is null
  and (pg_temp.called_txt('noflag3_last')::jsonb ->> 'conservation_touched_count') = '1'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000033',
                           '56000000-0000-0000-0000-000000000330') ->> 'cash_tips_cents') = '6000'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000033',
                           '56000000-0000-0000-0000-000000000330') ->> 'prov') = '2',
  'flagged=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000033') ->> 'conservation_failed_at','null')
    || ' third_run_touched=' || coalesce(pg_temp.called_txt('noflag3_last')::jsonb ->> 'conservation_touched_count','null')
    || ' ' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000033','56000000-0000-0000-0000-000000000330')::text);

-- The invocation-scoped money halves agree on every non-forced account this
-- suite ran. This is the positive form of the claim the forced test above
-- explains: after a correct derive they cannot differ.
select pg_temp.expect('theScopedMoneyHalvesAgreeOnEveryNonForcedAccount',
  (select bool_and((pg_temp.state(u) ->> 'source_non_wage_cents')
                 = (pg_temp.state(u) ->> 'shift_non_wage_cents'))
   from (values ('56000000-0000-4000-8000-000000000011'::uuid),
                ('56000000-0000-4000-8000-000000000012'::uuid),
                ('56000000-0000-4000-8000-000000000013'::uuid),
                ('56000000-0000-4000-8000-000000000014'::uuid),
                ('56000000-0000-4000-8000-000000000015'::uuid),
                ('56000000-0000-4000-8000-000000000016'::uuid),
                ('56000000-0000-4000-8000-000000000021'::uuid),
                ('56000000-0000-4000-8000-000000000031'::uuid),
                ('56000000-0000-4000-8000-000000000032'::uuid),
                ('56000000-0000-4000-8000-000000000033'::uuid)) v(u)),
  (select coalesce(string_agg((pg_temp.state(u) ->> 'source_non_wage_cents') || '/' ||
                              (pg_temp.state(u) ->> 'shift_non_wage_cents'), ' '), '')
   from (values ('56000000-0000-4000-8000-000000000011'::uuid),
                ('56000000-0000-4000-8000-000000000012'::uuid),
                ('56000000-0000-4000-8000-000000000013'::uuid),
                ('56000000-0000-4000-8000-000000000014'::uuid),
                ('56000000-0000-4000-8000-000000000015'::uuid),
                ('56000000-0000-4000-8000-000000000016'::uuid),
                ('56000000-0000-4000-8000-000000000021'::uuid),
                ('56000000-0000-4000-8000-000000000031'::uuid),
                ('56000000-0000-4000-8000-000000000032'::uuid),
                ('56000000-0000-4000-8000-000000000033'::uuid)) v(u)));

-- =============================================================================
-- 6. The budget: a large account converges with partial forward progress
--
-- The first draft had no budget, no batching and no partial commit: its touched
-- set was every unmigrated group union the whole backlog, in one transaction,
-- under a 60 second timeout. A multi-year account -- the normal Payday shape --
-- got one all-or-nothing attempt, and if it ever exceeded 60 s the whole RPC
-- rolled back, the count was unchanged, and the client repeated it identically
-- forever with no state in which the account advanced.
-- =============================================================================

alter table public.tip_entries disable trigger tip_entries_fold_insert;
insert into calls (name, n, txt)
select 'bulk_seed', pg_temp.seed_pre_deploy('56000000-0000-4000-8000-000000000041', 2000, 4), '';
alter table public.tip_entries enable trigger tip_entries_fold_insert;

select pg_temp.expect('theBulkFixtureIsTwoThousandUnmigratedGroups',
  pg_temp.called('bulk_seed') = 2000
  and pg_temp.ucount('56000000-0000-4000-8000-000000000041') = 2000,
  'seeded=' || pg_temp.called('bulk_seed')
    || ' count=' || pg_temp.ucount('56000000-0000-4000-8000-000000000041'));

-- Ten passes of 200, each pass recording its own touched count and the
-- remaining_group_count the audit row was left holding, so the whole
-- convergence is one comparable string.
--
-- THE LOOP IS PLPGSQL AND NOT A `generate_series` SCAN, AND THAT WAS MEASURED.
-- The first version of this test read remaining_group_count with an inline
-- subquery in the SAME statement that invoked the one-shot: one SELECT has one
-- snapshot, so every pass read the PRE-STATEMENT value, the first pass read
-- NULL (no audit row existed yet), the concatenation collapsed to NULL and
-- string_agg returned NULL for the whole run. This is the S4 rule with a
-- second receipt: mutate in one statement, assert in the next -- which inside
-- plpgsql means two statements per iteration.
create function pg_temp.bulk_passes(p_user uuid, p_budget integer, p_passes integer)
returns text language plpgsql as $$
declare i integer; v_touched text; v_remaining integer; v_out text := '';
begin
  for i in 1..p_passes loop
    v_touched := (pg_temp.one_shot(p_user, p_budget) ->> 'conservation_touched_count');
    select st.remaining_group_count into v_remaining
      from public.shift_migration_state st where st.user_id = p_user;
    v_out := v_out || case when v_out = '' then '' else ' ' end
                   || v_touched || '/' || coalesce(v_remaining::text, 'NULL');
  end loop;
  return v_out;
end;
$$;

insert into calls (name, n, txt)
select 'bulk_passes', 0,
       pg_temp.bulk_passes('56000000-0000-4000-8000-000000000041', 200, 10);

select pg_temp.expect('aTwoThousandGroupHistoryConvergesInCeilingOfTwoThousandOverTwoHundredPasses',
  pg_temp.called_txt('bulk_passes') =
    '200/1800 200/1600 200/1400 200/1200 200/1000 200/800 200/600 200/400 200/200 200/0',
  'touched/remaining per pass = ' || pg_temp.called_txt('bulk_passes'));

select pg_temp.expect('andNeverRollsBack_everyGroupIsConvertedAndNothingIsOrphaned',
  (select count(*) = 2000 from public.shifts
    where user_id = '56000000-0000-4000-8000-000000000041' and deleted_at is null
      and source = 'migration' and array_length(legacy_entry_ids, 1) = 1)
  and pg_temp.ucount('56000000-0000-4000-8000-000000000041') = 0
  and (pg_temp.state('56000000-0000-4000-8000-000000000041') ->> 'conservation_failed_at') is null,
  'shifts=' || (select count(*) from public.shifts
                 where user_id = '56000000-0000-4000-8000-000000000041' and deleted_at is null)
    || ' count=' || pg_temp.ucount('56000000-0000-4000-8000-000000000041')
    || ' flagged=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000041') ->> 'conservation_failed_at','null'));

-- The eleventh pass does nothing and moves nothing, so the client's
-- strictly-decreasing follow-up rule terminates.
insert into calls (name, n, txt)
select 'bulk_eleventh', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000041', 200)::text;

select pg_temp.expect('theEleventhPassIsANoOpAndTheAccountIsConverged',
  (pg_temp.called_txt('bulk_eleventh')::jsonb ->> 'conservation_touched_count') = '0'
  and (pg_temp.called_txt('bulk_eleventh')::jsonb ->> 'remaining_group_count') = '0',
  'touched=' || coalesce(pg_temp.called_txt('bulk_eleventh')::jsonb ->> 'conservation_touched_count','null')
    || ' remaining=' || coalesce(pg_temp.called_txt('bulk_eleventh')::jsonb ->> 'remaining_group_count','null'));

-- A budget of zero or below would report "nothing changed" forever and stall
-- the account permanently under the strictly-decreasing rule, so it is clamped
-- to one group of real progress.
alter table public.tip_entries disable trigger tip_entries_fold_insert;
insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
values ('56000000-0000-0000-0000-000000000419','56000000-0000-4000-8000-000000000041',
        '56000000-0000-0000-0000-000000000418','2026-09-01',100,'cash','2026-09-01T23:00:00Z');
alter table public.tip_entries enable trigger tip_entries_fold_insert;
insert into calls (name, n, txt)
select 'zero_budget', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000041', 0)::text;

select pg_temp.expect('aBudgetOfZeroStillMakesOneGroupOfForwardProgress',
  (pg_temp.called_txt('zero_budget')::jsonb ->> 'conservation_touched_count') = '1'
  and (pg_temp.called_txt('zero_budget')::jsonb ->> 'remaining_group_count') = '0',
  'touched=' || coalesce(pg_temp.called_txt('zero_budget')::jsonb ->> 'conservation_touched_count','null')
    || ' remaining=' || coalesce(pg_temp.called_txt('zero_budget')::jsonb ->> 'remaining_group_count','null'));

-- =============================================================================
-- 7. The 5.2 miss sequences, in the shape they were measured
-- =============================================================================

-- "a live row folded by device A then tombstoned by device B stays named and
-- its $60 lives in the shift forever". Two rows, so the group survives and the
-- money moves rather than the whole shift disappearing.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000051',
  '[{"id":"56000000-0000-0000-0000-000000000511","shift_id":"56000000-0000-0000-0000-000000000510",
     "work_date":"2026-07-15","amount_cents":6000,"kind":"cash",
     "client_updated_at":"2026-07-15T23:00:00Z"},
    {"id":"56000000-0000-0000-0000-000000000512","shift_id":"56000000-0000-0000-0000-000000000510",
     "work_date":"2026-07-15","amount_cents":2000,"kind":"credit",
     "client_updated_at":"2026-07-15T23:05:00Z"}]'::jsonb);
alter table public.tip_entries disable trigger tip_entries_fold_update;
update public.tip_entries set deleted_at = now(), client_updated_at = now()
 where id = '56000000-0000-0000-0000-000000000511';
alter table public.tip_entries enable trigger tip_entries_fold_update;
insert into calls (name, n, txt)
select 'miss1_before', 0, pg_temp.shift_facts('56000000-0000-4000-8000-000000000051',
                                              '56000000-0000-0000-0000-000000000510')::text;
select pg_temp.one_shot('56000000-0000-4000-8000-000000000051');

select pg_temp.expect('aFoldedRowTombstonedByAnotherDeviceStopsLivingInTheShift',
  (pg_temp.called_txt('miss1_before')::jsonb ->> 'cash_tips_cents') = '6000'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000051',
                           '56000000-0000-0000-0000-000000000510') ->> 'cash_tips_cents') = '0'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000051',
                           '56000000-0000-0000-0000-000000000510') ->> 'credit_tips_cents') = '2000'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000051',
                           '56000000-0000-0000-0000-000000000510') ->> 'prov') = '1',
  'before=' || pg_temp.called_txt('miss1_before')
    || ' after=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000051',
                                        '56000000-0000-0000-0000-000000000510')::text);

-- "a $50 to $40 correction of an already-folded row never applies", here with
-- a second live row so the correction is visible as a money change rather than
-- as the group emptying.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000052',
  '[{"id":"56000000-0000-0000-0000-000000000521","shift_id":"56000000-0000-0000-0000-000000000520",
     "work_date":"2026-07-16","amount_cents":5000,"kind":"cash",
     "client_updated_at":"2026-07-16T23:00:00Z"},
    {"id":"56000000-0000-0000-0000-000000000522","shift_id":"56000000-0000-0000-0000-000000000520",
     "work_date":"2026-07-16","amount_cents":1000,"kind":"credit",
     "client_updated_at":"2026-07-16T23:05:00Z"}]'::jsonb);
alter table public.tip_entries disable trigger tip_entries_fold_update;
update public.tip_entries set amount_cents = 4000, client_updated_at = '2026-07-17T09:00:00Z'
 where id = '56000000-0000-0000-0000-000000000521';
alter table public.tip_entries enable trigger tip_entries_fold_update;
insert into calls (name, n, txt)
select 'miss2_count', pg_temp.ucount('56000000-0000-4000-8000-000000000052'), '';
select pg_temp.one_shot('56000000-0000-4000-8000-000000000052');

select pg_temp.expect('aCorrectionOfAnAlreadyFoldedRowIsFoundAndApplied',
  pg_temp.called('miss2_count') = 1
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000052',
                           '56000000-0000-0000-0000-000000000520') ->> 'cash_tips_cents') = '4000'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000052',
                           '56000000-0000-0000-0000-000000000520') ->> 'non_wage_earnings_cents') = '5000',
  'count_before=' || pg_temp.called('miss2_count')
    || ' after=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000052',
                                        '56000000-0000-0000-0000-000000000520')::text);

-- =============================================================================
-- 8. a_late_legacy_row_for_a_day_that_already_has_a_native_shift_is_reported
--    _not_silently_doubled
--
-- A post-conversion native shift is keyed by a random uuid because the product
-- supports lunch and dinner on one date, while a folded legacy group keys on
-- payday_legacy_shift_id(work_date). The ids differ, both rows are legal under
-- the composite key, and the night is counted twice. An old build can produce
-- that any week for years, and refusing to commit would wedge the fold.
-- =============================================================================

insert into public.shifts (user_id, id, work_date, cash_tips_cents, source,
                            client_updated_at, native_modified_at)
values ('56000000-0000-4000-8000-000000000061','56000000-0000-0000-0000-0000000006aa',
        '2026-08-01', 3000, 'device', now(), now());
alter table public.tip_entries disable trigger tip_entries_fold_insert;
insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
values ('56000000-0000-0000-0000-000000000611','56000000-0000-4000-8000-000000000061',
        null,'2026-08-01',2000,'cash','2026-08-01T23:00:00Z');
alter table public.tip_entries enable trigger tip_entries_fold_insert;

insert into calls (name, n, txt)
select 'dupday', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000061')::text;

select pg_temp.expect('a_late_legacy_row_for_a_day_that_already_has_a_native_shift_is_reported_not_silently_doubled',
  (pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'duplicate_work_date_count') = '1'
  and (pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'duplicate_work_dates') = '["2026-08-01"]'
  and (select count(*) = 2 from public.shifts
        where user_id = '56000000-0000-4000-8000-000000000061'
          and work_date = '2026-08-01' and deleted_at is null),
  'dup_count=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'duplicate_work_date_count','null')
    || ' dates=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'duplicate_work_dates','null')
    || ' shifts=' || (select count(*) from public.shifts
                       where user_id = '56000000-0000-4000-8000-000000000061'
                         and work_date = '2026-08-01' and deleted_at is null));

-- Reported, and NOT prevented: the RPC committed and the legacy money is
-- converted. Refusing would wedge the fold for years.
select pg_temp.expect('theDuplicateDayStillCommittedAndTheLegacyMoneyIsConverted',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000061',
                       public.payday_legacy_shift_id('2026-08-01')) ->> 'cash_tips_cents') = '2000',
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000061',
                      public.payday_legacy_shift_id('2026-08-01'))::text);

-- The account-wide informational counters are recorded every run and are
-- EXPECTED to disagree with each other: the native shift's $30 is in no source
-- sum at all, and every trigger conversion is another legal reason, forever.
select pg_temp.expect('theAccountWideInformationalCountersAreRecorded',
  (pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'source_row_count') = '1'
  and (pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'shift_count') = '2'
  and (pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'native_shift_count') = '1'
  and (pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'edited_since_conversion_count') = '1',
  'rows=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'source_row_count','null')
    || ' shifts=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'shift_count','null')
    || ' native=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'native_shift_count','null')
    || ' edited=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000061') ->> 'edited_since_conversion_count','null'));

-- rows_in_closed_shifts and the unconverted total, on the account that has both
-- a closed shift and a legacy arrival it declined.
select pg_temp.expect('rows_in_closed_shifts_and_the_unconverted_total_are_recorded',
  (pg_temp.state('56000000-0000-4000-8000-000000000032') ->> 'rows_in_closed_shifts') = '1'
  and (pg_temp.state('56000000-0000-4000-8000-000000000032') ->> 'unconverted_legacy_cents')::bigint = 3500,
  'in_closed=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000032') ->> 'rows_in_closed_shifts','null')
    || ' unconverted=' || coalesce(pg_temp.state('56000000-0000-4000-8000-000000000032') ->> 'unconverted_legacy_cents','null'));

-- =============================================================================
-- 9. an_edit_made_between_two_invocations_is_still_found_by_the_rollback_QUERY
--
-- Two predicates matter to rollback and they are NOT interchangeable.
--
--   * The artifact query, `source = 'migration' and array_length(legacy_entry_ids,1) > 0`,
--     is what rollback tombstones. A natively EDITED conversion artifact keeps
--     both, so an edit between two invocations never hides the shift from it.
--   * The edit dump is `native_modified_at is not null`, NOT
--     `converted_at < client_updated_at`. The deriver writes converted_at
--     unconditionally while client_updated_at sits inside the open-to-fold CASE
--     and is PRESERVED on a closed shift, so the moment the headline case
--     occurs -- the user edits Jul 4, then an old phone pushes one unsynced $20
--     cash tip for Jul 4 -- converted_at jumps ABOVE client_updated_at and the
--     edited shift drops out of the dump, and out of
--     edited_since_conversion_count, which is pinned with the same comparison.
-- =============================================================================

select pg_temp.device_upsert('56000000-0000-4000-8000-000000000071',
  '[{"id":"56000000-0000-0000-0000-000000000711","shift_id":"56000000-0000-0000-0000-000000000710",
     "work_date":"2026-07-04","amount_cents":5000,"kind":"cash",
     "client_updated_at":"2026-07-04T23:00:00Z"},
    {"id":"56000000-0000-0000-0000-000000000721","shift_id":"56000000-0000-0000-0000-000000000720",
     "work_date":"2026-07-20","amount_cents":9000,"kind":"cash",
     "client_updated_at":"2026-07-20T23:00:00Z"}]'::jsonb);
-- The user corrects Jul 4 on the new build.
update public.shifts set cash_tips_cents = 6000, native_modified_at = now(),
                         client_updated_at = now()
 where user_id = '56000000-0000-4000-8000-000000000071'
   and id = '56000000-0000-0000-0000-000000000710';
insert into calls (name, n, txt)
select 'edit_dump_before', 0,
       (select (native_modified_at is not null)::text || '/' ||
               (converted_at < client_updated_at)::text
          from public.shifts where user_id = '56000000-0000-4000-8000-000000000071'
            and id = '56000000-0000-0000-0000-000000000710');

select pg_temp.expect('a_post_conversion_edit_appears_in_the_dump',
  pg_temp.called_txt('edit_dump_before') = 'true/true',
  'native_modified_at/converted_at<client_updated_at = ' || pg_temp.called_txt('edit_dump_before'));

-- Now the old phone pushes one unsynced $20 cash tip for the same night. This
-- is the headline case, and it is what flips the wrong predicate.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000071',
  '[{"id":"56000000-0000-0000-0000-000000000712","shift_id":"56000000-0000-0000-0000-000000000710",
     "work_date":"2026-07-04","amount_cents":2000,"kind":"cash",
     "client_updated_at":"2026-07-04T23:30:00Z"}]'::jsonb);
insert into calls (name, n, txt)
select 'edit_dump_after', 0,
       (select (native_modified_at is not null)::text || '/' ||
               (converted_at < client_updated_at)::text
          from public.shifts where user_id = '56000000-0000-4000-8000-000000000071'
            and id = '56000000-0000-0000-0000-000000000710');

select pg_temp.expect('an_edited_shift_that_later_received_a_legacy_write_is_still_in_the_dump',
  pg_temp.called_txt('edit_dump_after') = 'true/false',
  'native_modified_at/converted_at<client_updated_at = ' || pg_temp.called_txt('edit_dump_after')
    || ' (the second term is the measured trap: false means the converted_at '
    || 'comparison would have silently omitted this shift)');

-- The artifact query still finds it, so rollback cannot leave it half handled.
insert into calls (name, n, txt)
select 'rb_query', 0, pg_temp.one_shot('56000000-0000-4000-8000-000000000071')::text;

select pg_temp.expect('an_edit_made_between_two_invocations_is_still_found_by_the_rollback_query',
  (select count(*) = 1 from public.shifts
    where user_id = '56000000-0000-4000-8000-000000000071'
      and id = '56000000-0000-0000-0000-000000000710'
      and source = 'migration' and array_length(legacy_entry_ids, 1) > 0),
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000071','56000000-0000-0000-0000-000000000710')::text);

-- =============================================================================
-- 10. ROLLBACK. This section disables the fold triggers GLOBALLY, which is the
--     whole point of the no-argument signature, so it runs last and re-enables
--     them before the suite ends. The trigger state is asserted at both ends.
-- =============================================================================

-- A second account with its own state row, so "EVERY row is stamped" is a real
-- assertion rather than a tautology over one account.
select pg_temp.device_upsert('56000000-0000-4000-8000-000000000072',
  '[{"id":"56000000-0000-0000-0000-000000000731","shift_id":"56000000-0000-0000-0000-000000000730",
     "work_date":"2026-07-21","amount_cents":1500,"kind":"cash",
     "client_updated_at":"2026-07-21T23:00:00Z"}]'::jsonb);
select pg_temp.one_shot('56000000-0000-4000-8000-000000000072');

-- AN ACCOUNT WITH LEGACY ROWS AND NO shift_migration_state ROW AT ALL. This is
-- the population the kill switch used to be INVISIBLE to, and it is the
-- majority population at the moment a rollback would actually be ordered: a row
-- exists only once private.note_legacy_write has fired (a legacy write after S4
-- deployed) or the one-shot has run, so an account whose 1.0 device has not
-- written since deploy and whose client has not synced has none. Its rows are
-- written with the fold suppressed for exactly that reason.
alter table public.tip_entries disable trigger tip_entries_fold_insert;
insert into public.tip_entries (id, user_id, work_date, amount_cents, kind, client_updated_at) values
 ('56000000-0000-0000-0000-000000000751','56000000-0000-4000-8000-000000000073','2026-07-26',5000,'cash','2026-07-26T23:00:00Z'),
 ('56000000-0000-0000-0000-000000000752','56000000-0000-4000-8000-000000000073','2026-07-27',5500,'cash','2026-07-27T23:00:00Z');
alter table public.tip_entries enable trigger tip_entries_fold_insert;

insert into calls (name, n, txt)
select 'no_state_row_before', 0,
  'rows=' || (select count(*) from public.shift_migration_state
               where user_id = '56000000-0000-4000-8000-000000000073')
  || ' stamp=' || coalesce(pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000073')::text, 'NULL');

select pg_temp.expect('theNoStateRowFixtureReallyHasNoStateRow',
  pg_temp.called_txt('no_state_row_before') = 'rows=0 stamp=NULL',
  coalesce(pg_temp.called_txt('no_state_row_before'),'null'));

-- A natively authored shift: no legacy representation at all, so rollback HIDES
-- it from a legacy reader rather than destroying it.
insert into public.shifts (user_id, id, work_date, cash_tips_cents, source,
                            client_updated_at, native_modified_at)
values ('56000000-0000-4000-8000-000000000071','56000000-0000-0000-0000-0000000007bb',
        '2026-07-25', 4000, 'device', now(), now());

-- A post-conversion DELETION whose legacy tombstone flush never happened. This
-- is the variant where the device's flush failed the staleness guard: the shift
-- is tombstoned with deleted_reason 'user' while its legacy rows are still
-- LIVE, so a naive rollback resurrects a night the user deleted.
update public.shifts set deleted_at = now(), deleted_reason = 'user',
                         native_modified_at = now(), client_updated_at = now()
 where user_id = '56000000-0000-4000-8000-000000000071'
   and id = '56000000-0000-0000-0000-000000000720';

insert into calls (name, n, txt)
select 'pre_rollback_072', 0,
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000072',
                      '56000000-0000-0000-0000-000000000730')::text;

insert into calls (name, n, txt)
select 'pre_rollback', 0,
  'digest=[' || pg_temp.shift_digest('56000000-0000-4000-8000-000000000071') || ']'
  || ' live_legacy_of_deleted=' ||
  (select count(*) from public.tip_entries e
    where e.user_id = '56000000-0000-4000-8000-000000000071'
      and e.id = '56000000-0000-0000-0000-000000000721' and e.deleted_at is null)
  || ' triggers=[' || pg_temp.trigger_states() || ']';

select pg_temp.expect('beforeRollbackTheDeletedShiftsLegacyRowsAreStillLive',
  pg_temp.called_txt('pre_rollback') like '%live_legacy_of_deleted=1%'
  and pg_temp.called_txt('pre_rollback') like
    '%triggers=[tip_entries_fold_delete=O tip_entries_fold_insert=O tip_entries_fold_update=O]%',
  pg_temp.called_txt('pre_rollback'));

-- THE COMPENSATING ACTION, and it is not optional. Rollback does not do this
-- for you, because doing it silently would be a destructive write to the one
-- table that IS the reversibility artifact. The RETURN SET must equal the
-- requested set, or the rollback would resurrect whatever it missed.
insert into calls (name, n, txt)
select 'compensate', 0,
  (select (pg_temp.device_delete('56000000-0000-4000-8000-000000000071',
             (select coalesce(array_agg(x), '{}'::uuid[])
                from public.shifts s, unnest(s.legacy_entry_ids) x
               where s.user_id = '56000000-0000-4000-8000-000000000071'
                 and s.deleted_reason = 'user'))
          = (select coalesce(array_agg(x order by x), '{}'::uuid[])
               from public.shifts s, unnest(s.legacy_entry_ids) x
              where s.user_id = '56000000-0000-4000-8000-000000000071'
                and s.deleted_reason = 'user'))::text);

select pg_temp.expect('theCompensatingActionsReturnSetEqualsTheRequestedSet',
  pg_temp.called_txt('compensate') = 'true',
  'return set matched request set: ' || coalesce(pg_temp.called_txt('compensate'),'null'));

-- THE MANDATORY PRE-ROLLBACK DUMP, taken here rather than described, because
-- step 5 of the re-enable runbook CONSUMES it. `native_modified_at is not
-- null`, never `converted_at < client_updated_at`: the deriver writes
-- converted_at unconditionally, so that comparison silently omits exactly the
-- shifts most likely to need recovery.
create temporary table edit_dump as
  select user_id, id, non_wage_earnings_cents, deleted_reason from public.shifts
   where native_modified_at is not null;

select pg_temp.expect('thePreRollbackEditDumpIsNotEmptySoTheRunbookStepIsNotVacuous',
  (select count(*) > 0 from edit_dump
    where user_id = '56000000-0000-4000-8000-000000000071'
      and id = '56000000-0000-0000-0000-000000000710'),
  'dump rows=' || (select count(*) from edit_dump)
    || ' edited_artifact_in_dump=' || (select count(*) from edit_dump
         where id = '56000000-0000-0000-0000-000000000710'));

-- ROLLBACK.
insert into calls (name, n, txt)
select 'rollback', public.rollback_shift_migration(), '';

select pg_temp.expect('rollbackTombstonesEveryConversionArtifactAndReportsHowMany',
  pg_temp.called('rollback') >= 2000
  and (select count(*) = 0 from public.shifts
        where source = 'migration' and array_length(legacy_entry_ids, 1) > 0
          and deleted_at is null),
  'tombstoned=' || pg_temp.called('rollback')
    || ' live_artifacts_left=' || (select count(*) from public.shifts
         where source = 'migration' and array_length(legacy_entry_ids, 1) > 0
           and deleted_at is null));

select pg_temp.expect('rollback_disables_all_three_fold_triggers',
  pg_temp.trigger_states() =
    'tip_entries_fold_delete=D tip_entries_fold_insert=D tip_entries_fold_update=D',
  pg_temp.trigger_states());

select pg_temp.expect('rollback_stamps_every_shift_migration_state_row',
  (select count(*) = 0 from public.shift_migration_state where rollback_at is null)
  and pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000071') is not null
  and pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000072') is not null,
  'unstamped=' || (select count(*) from public.shift_migration_state where rollback_at is null)
    || ' rb1=' || coalesce(pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000071')::text,'null')
    || ' rb2=' || coalesce(pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000072')::text,'null'));

-- THE STRONGER FORM OF THE SAME CLAIM, and the one that failed. "Every row is
-- stamped" was true and useless: the guarantee the client depends on is that
-- every ACCOUNT reads a non-null stamp, and an account with no row read NULL
-- straight through the rollback. MEASURED before the stamp became an INSERT
-- over auth.users: rollback_shift_migration() returned 1 and this account's
-- payday_shift_rollback_at() was NULL both before and after.
select pg_temp.expect('rollbackStampsAnAccountThatHasNoStateRowYet',
  pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000073') is not null
  and (select count(*) = 0 from auth.users u
        where not exists (select 1 from public.shift_migration_state st
                           where st.user_id = u.id and st.rollback_at is not null)),
  'stamp=' || coalesce(pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000073')::text,'NULL')
    || ' unstamped_accounts=' || (select count(*) from auth.users u
         where not exists (select 1 from public.shift_migration_state st
                            where st.user_id = u.id and st.rollback_at is not null)));

-- ...AND THE ONE-SHOT WILL NOT CONVERT IT. Being told is half of it; the other
-- half is that the client calling the one-shot anyway -- which the shipped
-- contract permits whenever the count is positive -- creates nothing. MEASURED
-- before the guard: this account's next sync (count 2, one call to the
-- one-shot) converted its whole history into two LIVE artifacts fleet-wide
-- AFTER the kill switch, with remaining_group_count 0 and rollback_at still
-- NULL, which is the state in which the client's own first-switch rule points
-- shiftsAreAuthoritativeAt at the new leg DURING a global rollback.
--
-- ON READING THE REFUSAL, MEASURED RATHER THAN ASSUMED: `return
-- null::public.shift_migration_state` from a composite-returning function
-- called in FROM position does NOT give SQL NULL, it gives ONE ROW OF ALL
-- NULLS, so to_jsonb of it is an object of nulls and not 'null'. That is the
-- same shape the deleted-account no-op already returns, so the refusal is
-- read the same way both are: user_id is null.
insert into calls (name, n, txt)
select 'no_state_row_sync', pg_temp.ucount('56000000-0000-4000-8000-000000000073'),
  coalesce(pg_temp.one_shot('56000000-0000-4000-8000-000000000073') ->> 'user_id', 'NO USER_ID');

select pg_temp.expect('anAccountWithNoStateRowIsNotConvertedByItsNextSyncDuringARollback',
  pg_temp.called('no_state_row_sync') = 2
  and pg_temp.called_txt('no_state_row_sync') = 'NO USER_ID'
  and pg_temp.live_money('56000000-0000-4000-8000-000000000073') = 'shifts=0 cents=0'
  and (select count(*) = 0 from public.shifts s
        where s.user_id = '56000000-0000-4000-8000-000000000073'),
  'count=' || coalesce(pg_temp.called('no_state_row_sync')::text,'null')
    || ' one_shot_user_id=' || coalesce(pg_temp.called_txt('no_state_row_sync'),'MISSING')
    || ' ' || pg_temp.live_money('56000000-0000-4000-8000-000000000073')
    || ' rows_in_shifts=' || (select count(*) from public.shifts s
         where s.user_id = '56000000-0000-4000-8000-000000000073'));

select pg_temp.expect('rollback_empties_the_backlog',
  (select count(*) = 0 from private.shift_fold_backlog),
  'backlog rows=' || (select count(*) from private.shift_fold_backlog));

-- A NATIVELY AUTHORED SHIFT IS HIDDEN, NOT DESTROYED. It has no legacy
-- representation by design, so a legacy reader cannot see it, but the row is
-- untouched and the documented dump recovers it.
select pg_temp.expect('a_natively_authored_shift_is_hidden_from_a_legacy_reader_not_destroyed',
  (select deleted_at is null and cash_tips_cents = 4000 from public.shifts
    where user_id = '56000000-0000-4000-8000-000000000071'
      and id = '56000000-0000-0000-0000-0000000007bb')
  and (select count(*) = 1 from public.shifts
        where user_id = '56000000-0000-4000-8000-000000000071'
          and array_length(legacy_entry_ids, 1) is null and deleted_at is null),
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000071','56000000-0000-0000-0000-0000000007bb')::text);

-- A POST-CONVERSION EDIT IS RECOVERABLE FROM THE TOMBSTONED ROW. Nothing is
-- hard-deleted, so the dump can still be taken after the fact.
select pg_temp.expect('a_post_conversion_edit_is_recoverable_after_rollback',
  (select cash_tips_cents = 6000 and native_modified_at is not null
     from public.shifts where user_id = '56000000-0000-4000-8000-000000000071'
       and id = '56000000-0000-0000-0000-000000000710'),
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000071','56000000-0000-0000-0000-000000000710')::text);

select pg_temp.expect('a_post_conversion_deletion_is_not_resurrected_by_rollback',
  (select count(*) = 0 from public.tip_entries e
    where e.user_id = '56000000-0000-4000-8000-000000000071'
      and e.id = '56000000-0000-0000-0000-000000000721' and e.deleted_at is null),
  'live rows of the deleted shift = ' ||
  (select count(*) from public.tip_entries e
    where e.user_id = '56000000-0000-4000-8000-000000000071'
      and e.id = '56000000-0000-0000-0000-000000000721' and e.deleted_at is null));

-- A 1.0 device keeps writing, and with the triggers off its write lands in
-- tip_entries and is read by its own screens, exactly as before PR 2. Nothing
-- is converted and no re-converter partially un-rolls the rollback.
insert into calls (name, n, txt)
select 'post_rb_write', pg_temp.device_upsert('56000000-0000-4000-8000-000000000072',
  '[{"id":"56000000-0000-0000-0000-000000000741","shift_id":"56000000-0000-0000-0000-000000000740",
     "work_date":"2026-07-22","amount_cents":800,"kind":"cash",
     "client_updated_at":"2026-07-22T23:00:00Z"}]'::jsonb), '';

select pg_temp.expect('a_legacy_write_after_rollback_is_accepted_and_converts_nothing',
  pg_temp.called('post_rb_write') = 1
  and (select count(*) = 1 from public.tip_entries
        where id = '56000000-0000-0000-0000-000000000741' and deleted_at is null)
  and (select count(*) = 0 from public.shifts
        where user_id = '56000000-0000-4000-8000-000000000072'
          and id = '56000000-0000-0000-0000-000000000740')
  and (select count(*) = 0 from private.shift_fold_backlog),
  'accepted=' || pg_temp.called('post_rb_write')
    || ' shifts_for_that_group=' || (select count(*) from public.shifts
         where user_id = '56000000-0000-4000-8000-000000000072'
           and id = '56000000-0000-0000-0000-000000000740')
    || ' backlog=' || (select count(*) from private.shift_fold_backlog));

-- rollback_at is never overwritten, including by a second rollback.
insert into calls (name, n, txt)
select 'rb_twice', 0,
  (select rollback_at::text from public.shift_migration_state
    where user_id = '56000000-0000-4000-8000-000000000072');
select public.rollback_shift_migration();

select pg_temp.expect('rollback_at_is_never_overwritten_by_a_second_rollback',
  pg_temp.called_txt('rb_twice') =
    (select rollback_at::text from public.shift_migration_state
      where user_id = '56000000-0000-4000-8000-000000000072'),
  'first=[' || coalesce(pg_temp.called_txt('rb_twice'),'null') || '] second=['
    || coalesce((select rollback_at::text from public.shift_migration_state
                  where user_id = '56000000-0000-4000-8000-000000000072'),'null') || ']');

-- A PLAIN ONE-SHOT RUN AFTER ROLLBACK CONVERTS NOTHING AT ALL, AND THIS
-- ASSERTION IS THE INVERSE OF THE ONE IT REPLACES.
--
-- Two separate reasons now stop it, and only one of them existed before.
--
--   * For the ROLLED-BACK ARTIFACT's own rows the predicate is simply false.
--     MEASURED: rollback leaves legacy_entry_ids and the watermark intact, so
--     the rows are live, named, and at or below their watermark, and the
--     one-shot has genuinely nothing to catch up on. Re-converting a
--     rolled-back account is RE-DERIVING, not catching up.
--   * For the row that ARRIVED WHILE THE TRIGGERS WERE OFF the predicate is
--     TRUE, and the earlier version of this test asserted that the one-shot
--     converted it. IT DID, AND THAT WAS THE DEFECT. MEASURED: with
--     rollback_at set, a 1.0 device wrote one new night ($33.00), the trigger
--     correctly folded nothing, and the client's own documented loop -- count
--     RPC positive, then one call to the one-shot -- produced a LIVE
--     source='migration' artifact with rollback_at still set. That is "an
--     account half rolled back with no record of which half", the exact harm
--     rule 1 of the migration says the same-transaction trigger disable
--     prevents, arriving through the second re-converter nobody had disabled.
--     The one-shot now refuses a JWT-bearing caller whose rollback_at is set
--     and returns a null row rather than raising.
--
-- So: nothing converts, and the returned row is null. The group written while
-- the triggers were off is converted by the REPAIR step below, which is an
-- operator action, and theWriteTakenWhileTheTriggersWereOffIsConvertedByTheRepair
-- is where that is asserted.
insert into calls (name, n, txt)
select 'plain_after_rb', 0,
  coalesce(pg_temp.one_shot('56000000-0000-4000-8000-000000000072') ->> 'user_id', 'NO USER_ID');

select pg_temp.expect('a_plain_one_shot_run_after_rollback_does_not_re_convert_the_artifacts',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000072',
                       '56000000-0000-0000-0000-000000000730') ->> 'is_deleted') = 'true'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000072',
                           '56000000-0000-0000-0000-000000000730') ->> 'deleted_reason') = 'converted'
  and pg_temp.shift_facts('56000000-0000-4000-8000-000000000072',
                          '56000000-0000-0000-0000-000000000740') = 'null'::jsonb,
  'rolled_back_group=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000072','56000000-0000-0000-0000-000000000730')::text
    || ' group_written_while_off=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000072','56000000-0000-0000-0000-000000000740')::text);

-- The refusal is a NULL ROW, not a raise. Rule 2 of the migration is that
-- nothing on the RPC path raises: a raise aborts the caller's transaction, and
-- S4 already paid for that lesson.
select pg_temp.expect('theRollbackGuardReturnsANullRowRatherThanRaising',
  pg_temp.called_txt('plain_after_rb') = 'NO USER_ID'
  and pg_temp.outcome_of(
        'select pg_temp.one_shot(''56000000-0000-4000-8000-000000000072''::uuid)') = '00000',
  'user_id=' || coalesce(pg_temp.called_txt('plain_after_rb'),'MISSING')
    || ' sqlstate=' || pg_temp.outcome_of(
         'select pg_temp.one_shot(''56000000-0000-4000-8000-000000000072''::uuid)'));

-- And no live conversion artifact exists ANYWHERE in the fleet after the kill
-- switch, which is the fleet-wide form of the guarantee. MEASURED before the
-- two fixes: three.
select pg_temp.expect('noLiveConversionArtifactExistsFleetWideAfterTheKillSwitch',
  (select count(*) = 0 from public.shifts
    where source = 'migration' and array_length(legacy_entry_ids, 1) > 0
      and deleted_at is null),
  'live_artifacts=' || (select count(*) from public.shifts
    where source = 'migration' and array_length(legacy_entry_ids, 1) > 0
      and deleted_at is null));

-- THE FORWARD HALF: re-enable the triggers, then repair per account. Convergence
-- is asserted against the digest taken before the rollback.
alter table public.tip_entries enable trigger tip_entries_fold_insert;
alter table public.tip_entries enable trigger tip_entries_fold_update;
alter table public.tip_entries enable trigger tip_entries_fold_delete;

select pg_temp.expect('theThreeTriggersAreBackToOriginAfterTheOperatorReEnable',
  pg_temp.trigger_states() =
    'tip_entries_fold_delete=O tip_entries_fold_insert=O tip_entries_fold_update=O',
  pg_temp.trigger_states());

insert into calls (name, n, txt)
select 'repair', 0, (select count(*)::text from (
  select public.repair_shift_migration(u.id) from auth.users u
   where u.id in ('56000000-0000-4000-8000-000000000071',
                  '56000000-0000-4000-8000-000000000072')) x);

-- CONVERGENCE, over the population where it is achievable: an artifact NOBODY
-- TOUCHED. Rollback tombstoned it as 'converted', repair re-presents its group
-- key, and the deriver's un-delete arm reopens it to byte-identical money and
-- provenance.
select pg_temp.expect('rollback_then_re_enable_then_repair_converges_to_the_same_rows',
  pg_temp.called_txt('pre_rollback_072') =
    pg_temp.shift_facts('56000000-0000-4000-8000-000000000072',
                        '56000000-0000-0000-0000-000000000730')::text,
  'before=' || coalesce(pg_temp.called_txt('pre_rollback_072'),'null')
    || ' after=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000072',
                                        '56000000-0000-0000-0000-000000000730')::text);

-- AND THE ONE ARTIFACT REPAIR CANNOT REOPEN, NAMED RATHER THAN DISCOVERED
-- LATER. MEASURED on the first run of this suite: a conversion artifact the
-- user had EDITED stays tombstoned after rollback and repair, because the
-- deriver's un-delete arm deliberately reopens only a 'converted' tombstone on
-- a shift NO human has touched, and a natively edited shift is closed forever.
-- So a rollback hides every edited shift, and repair does not bring it back:
-- the money is still in the row, the edit is still in the row, and the
-- documented `native_modified_at is not null` dump is the ONLY recovery. That
-- is precisely why that dump is a mandatory pre-rollback step and not advice.
select pg_temp.expect('anEditedArtifactStaysTombstonedAfterRepairAndOnlyTheDumpRecoversIt',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000071',
                       '56000000-0000-0000-0000-000000000710') ->> 'is_deleted') = 'true'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000071',
                           '56000000-0000-0000-0000-000000000710') ->> 'cash_tips_cents') = '6000'
  and (select count(*) = 1 from public.shifts
        where user_id = '56000000-0000-4000-8000-000000000071'
          and native_modified_at is not null and cash_tips_cents = 6000),
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000071','56000000-0000-0000-0000-000000000710')::text);

-- The account that took a legacy write while the triggers were off now has it,
-- which is the reason the repair step exists at all.
select pg_temp.expect('theWriteTakenWhileTheTriggersWereOffIsConvertedByTheRepair',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000072',
                       '56000000-0000-0000-0000-000000000740') ->> 'cash_tips_cents') = '800'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000072',
                           '56000000-0000-0000-0000-000000000730') ->> 'cash_tips_cents') = '1500',
  'jul22=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000072','56000000-0000-0000-0000-000000000740')::text
    || ' jul21=' || pg_temp.shift_facts('56000000-0000-4000-8000-000000000072','56000000-0000-0000-0000-000000000730')::text);

-- And repair does NOT clear rollback_at. While it is set every client keeps
-- clearing its shift state on every sync, so a re-converted account would be
-- re-derived on the server and read by nobody. Clearing it is the operator's
-- last step and is written out in the migration comment.
select pg_temp.expect('repair_does_not_clear_rollback_at_so_the_operator_step_stays_visible',
  pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000072') is not null,
  'rollback_at=' || coalesce(pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000072')::text,'null'));

-- RUNBOOK STEP 5: reopen the edited nights from the pre-rollback dump. This is
-- the statement the runbook used not to have, and its absence LOST MONEY ON
-- THE FORWARD PATH, not merely in the old build's display.
--
-- MEASURED on the full round trip with the five-statement runbook: an account
-- with one legacy night ($60) and one the user had natively corrected to $90
-- came back as the $60 night only. New-build visible money went 15000 to 9300
-- and the nights went '2026-06-01=6000 2026-06-02=9000' to
-- '2026-06-01=6000 2026-06-10=3300'. The $90 night was gone from the app on
-- BOTH legs: the legacy leg shows the pre-edit $70 while rolled back, and after
-- the last statement the client is back on public.shifts where the row is a
-- tombstone. The mechanism is honest and documented -- the deriver's un-delete
-- arm reopens a 'converted' tombstone only on a shift with native_modified_at
-- null, and an edited shift is closed forever -- but the runbook took the dump
-- and then never used it.
--
-- deleted_reason = 'converted' is the guard that matters: it is what keeps this
-- statement from resurrecting a night the USER deleted (deleted_reason 'user'),
-- which is in the same dump because a post-conversion deletion also stamps
-- native_modified_at.
update public.shifts s
   set deleted_at = null, deleted_reason = null
 where (s.user_id, s.id) in (select d.user_id, d.id from edit_dump d)
   and s.deleted_reason = 'converted';

select pg_temp.expect('theSixthRunbookStatementRestoresTheEditedNightsMoneyToTheNewBuild',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000071',
                       '56000000-0000-0000-0000-000000000710') ->> 'is_deleted') = 'false'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000071',
                           '56000000-0000-0000-0000-000000000710') ->> 'cash_tips_cents') = '6000',
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000071','56000000-0000-0000-0000-000000000710')::text);

-- ...and it did NOT resurrect the night the user deleted, which is the whole
-- reason the statement filters on deleted_reason rather than on the dump alone.
select pg_temp.expect('theReopenStepLeavesAUserDeletedNightDeleted',
  (pg_temp.shift_facts('56000000-0000-4000-8000-000000000071',
                       '56000000-0000-0000-0000-000000000720') ->> 'is_deleted') = 'true'
  and (pg_temp.shift_facts('56000000-0000-4000-8000-000000000071',
                           '56000000-0000-0000-0000-000000000720') ->> 'deleted_reason') = 'user',
  pg_temp.shift_facts('56000000-0000-4000-8000-000000000071','56000000-0000-0000-0000-000000000720')::text);

-- RUNBOOK STEP 6, LAST: let the clients back onto the new leg. Ordered after
-- step 5 so no client ever reads a history with the edited nights missing.
update public.shift_migration_state set rollback_at = null;

select pg_temp.expect('afterTheFullSixStatementRunbookTheClientIsBackAndNothingIsMissing',
  pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000071') is null
  and pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000072') is null
  and pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000073') is null
  and (select count(*) = 0 from edit_dump d
        join public.shifts s on s.user_id = d.user_id and s.id = d.id
       where s.deleted_reason = 'converted')
  and (select count(*) = 0 from edit_dump d
        join public.shifts s on s.user_id = d.user_id and s.id = d.id
       where d.deleted_reason is distinct from 'user'
         and (s.deleted_at is not null
              or s.non_wage_earnings_cents <> d.non_wage_earnings_cents)),
  'stamps=' || coalesce(pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000071')::text,'null')
    || '/' || coalesce(pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000072')::text,'null')
    || '/' || coalesce(pg_temp.rollback_stamp('56000000-0000-4000-8000-000000000073')::text,'null')
    || ' still_converted_from_dump=' || (select count(*) from edit_dump d
         join public.shifts s on s.user_id = d.user_id and s.id = d.id
        where s.deleted_reason = 'converted')
    || ' dumped_not_user_deleted=' || (select count(*) from edit_dump
         where deleted_reason is distinct from 'user')
    || ' of_those_still_hidden_or_changed=' || (select count(*) from edit_dump d
         join public.shifts s on s.user_id = d.user_id and s.id = d.id
        where d.deleted_reason is distinct from 'user'
          and (s.deleted_at is not null
               or s.non_wage_earnings_cents <> d.non_wage_earnings_cents)));

-- And the one-shot works again for a JWT-bearing caller, so the guard is a
-- window and not a one-way door.
insert into calls (name, n, txt)
select 'after_clear', 0, coalesce(pg_temp.one_shot('56000000-0000-4000-8000-000000000072')::text, 'null');

select pg_temp.expect('theRollbackGuardLiftsWhenTheOperatorClearsRollbackAt',
  pg_temp.called_txt('after_clear') <> 'null'
  and (pg_temp.called_txt('after_clear')::jsonb ->> 'rollback_at') is null,
  'returned=' || left(coalesce(pg_temp.called_txt('after_clear'),'MISSING'), 60));

-- =============================================================================
-- Report
-- =============================================================================

-- An assertion whose driving SELECT returns no row never calls pg_temp.expect
-- and would vanish from the report instead of failing, so the count is pinned.
select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 83,
  'ran ' || (select count(*) from results)::text || ' of 83');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed
from results;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'shift_migration_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'shift_migration_test: all % assertions passed', (select count(*) from results);
end;
$$;

-- The triggers MUST be back on for the suites that run after this one in the
-- same cluster, whatever happened above.
alter table public.tip_entries enable trigger tip_entries_fold_insert;
alter table public.tip_entries enable trigger tip_entries_fold_update;
alter table public.tip_entries enable trigger tip_entries_fold_delete;

delete from auth.users where id in (
  '56000000-0000-4000-8000-000000000011','56000000-0000-4000-8000-000000000012',
  '56000000-0000-4000-8000-000000000013','56000000-0000-4000-8000-000000000014',
  '56000000-0000-4000-8000-000000000015','56000000-0000-4000-8000-000000000016',
  '56000000-0000-4000-8000-000000000017','56000000-0000-4000-8000-000000000018',
  '56000000-0000-4000-8000-000000000019',
  '56000000-0000-4000-8000-000000000021','56000000-0000-4000-8000-000000000022',
  '56000000-0000-4000-8000-000000000031','56000000-0000-4000-8000-000000000032',
  '56000000-0000-4000-8000-000000000033','56000000-0000-4000-8000-000000000041',
  '56000000-0000-4000-8000-000000000051','56000000-0000-4000-8000-000000000052',
  '56000000-0000-4000-8000-000000000061','56000000-0000-4000-8000-000000000071',
  '56000000-0000-4000-8000-000000000072','56000000-0000-4000-8000-000000000073',
  '56000000-0000-4000-8000-000000000081');
