-- PR 2, slice S2: schema tests for the shift representation.
--
-- There is no pgTAP in this repo and no prior SQL test convention, so this is
-- a plain psql script: every assertion lands in a temporary results table and
-- the last statement raises if any row is false, which makes psql exit
-- non-zero under -v ON_ERROR_STOP=1.
--
-- CI (job E, "Supabase migrations (db reset)"), after `supabase db reset --local`:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/shift_schema_test.sql
--
-- Locally with no Docker, against a throwaway Homebrew postgresql@17 cluster
-- bootstrapped with the Supabase primitives (auth.users, auth.uid(), the
-- anon / authenticated / service_role roles, and Supabase's DEFAULT
-- PRIVILEGES on schema public), the same invocation applies.
--
-- Locally, `bash scripts/db-test-local.sh` does both halves in one command.
--
-- The script is re-runnable: it deletes its three fixture accounts first,
-- which cascades every row it wrote last time.
--
-- Deliberately NOT pgTAP, so `supabase test db` (pg_prove, which expects TAP
-- output) is not the runner: pgTAP is not installed in this project and the
-- gate is job E, which already has a live database in front of it.

\set ON_ERROR_STOP on
\timing off
\pset pager off

create temporary table results (
  seq serial primary key, name text not null, ok boolean not null, detail text not null default '');

-- Runs one statement and reports what it raised: '00000' when it succeeded,
-- otherwise 'SQLSTATE' or 'SQLSTATE/constraint_name'.
create function pg_temp.outcome_of(p_sql text) returns text language plpgsql as $$
declare v_constraint text;
begin
  execute p_sql;
  return '00000';
exception when others then
  get stacked diagnostics v_constraint = constraint_name;
  return sqlstate || coalesce('/' || nullif(v_constraint, ''), '');
end;
$$;

create function pg_temp.expect(p_name text, p_ok boolean, p_detail text default '')
returns void language sql as $$
  insert into results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail);
$$;

-- Fixture accounts -----------------------------------------------------------

delete from auth.users where id in (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333');
insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'payday-s2-a@test.invalid'),
  ('22222222-2222-4222-8222-222222222222', 'payday-s2-b@test.invalid'),
  ('33333333-3333-4333-8333-333333333333', 'payday-s2-c@test.invalid');

-- 1. Identity ----------------------------------------------------------------

select pg_temp.expect(
  'theIdentityVectorFor20260305',
  md5('payday:legacy-shift:2026-03-05') = '137014afcdd8a5b71018bd7636d09d87'
    and public.payday_legacy_shift_id('2026-03-05') = '5aac5d01-cdd8-a5b7-1018-bd7636d09d87'::uuid,
  'md5=' || md5('payday:legacy-shift:2026-03-05')
    || ' uuid=' || public.payday_legacy_shift_id('2026-03-05')::text);

select pg_temp.expect(
  'theIdentityVectorFor20260701',
  md5('payday:legacy-shift:2026-07-01') = '237b5c54e5506ca92f6ed35d43bfc83f'
    and public.payday_legacy_shift_id('2026-07-01') = '5aac5d01-e550-6ca9-2f6e-d35d43bfc83f'::uuid,
  'md5=' || md5('payday:legacy-shift:2026-07-01')
    || ' uuid=' || public.payday_legacy_shift_id('2026-07-01')::text);

select pg_temp.expect(
  'legacyGroupKeyPrefersTheStoredShiftID',
  private.legacy_group_key('44444444-4444-4444-4444-444444444444', '2026-03-05')
    = '44444444-4444-4444-4444-444444444444'::uuid);

select pg_temp.expect(
  'legacyGroupKeyFallsBackToTheDerivedID',
  private.legacy_group_key(null, '2026-03-05') = public.payday_legacy_shift_id('2026-03-05'));

-- The derived id takes no account input, so every account that worked
-- 2026-03-05 mints the same uuid. That is fine, and the composite primary key
-- is what makes it fine.
insert into public.shifts (id, user_id, work_date, cash_tips_cents, source, client_updated_at)
values (public.payday_legacy_shift_id('2026-03-05'), '11111111-1111-4111-8111-111111111111',
        '2026-03-05', 5000, 'migration', now());

select pg_temp.expect(
  'theDerivedIDIsIdenticalAcrossUsersAndThatIsFine',
  -- The function takes exactly one argument, a date, so no account can
  -- influence the value: the id user A now holds for 2026-03-05 is bit for bit
  -- the id user B will derive for the same night.
  (select pronargs from pg_proc where oid = 'public.payday_legacy_shift_id(date)'::regprocedure) = 1
  and (select count(*) from public.shifts
        where user_id = '11111111-1111-4111-8111-111111111111'
          and id = public.payday_legacy_shift_id('2026-03-05')) = 1,
  'pronargs=' || (select pronargs from pg_proc
                   where oid = 'public.payday_legacy_shift_id(date)'::regprocedure)::text
    || ' id=' || public.payday_legacy_shift_id('2026-03-05')::text);

-- 2. The cross-account upsert -------------------------------------------------

do $$
declare v_rows integer;
begin
  with up as (
    insert into public.shifts (id, user_id, work_date, cash_tips_cents, source, client_updated_at)
    values (public.payday_legacy_shift_id('2026-03-05'), '22222222-2222-4222-8222-222222222222',
            '2026-03-05', 7000, 'migration', now())
    on conflict (user_id, id) do update set cash_tips_cents = excluded.cash_tips_cents
    returning user_id
  )
  select count(*) into v_rows from up;
  perform pg_temp.expect('aCrossAccountUpsertReturnsOneRowAndBothRowsExist',
    v_rows = 1, 'returned ' || v_rows::text || ' row(s)');
end;
$$;

select pg_temp.expect(
  'bothAccountsHoldTheirOwnRowUnderTheSharedID',
  (select count(*) from public.shifts where id = public.payday_legacy_shift_id('2026-03-05')) = 2
  and (select cash_tips_cents from public.shifts
        where id = public.payday_legacy_shift_id('2026-03-05')
          and user_id = '11111111-1111-4111-8111-111111111111') = 5000
  and (select cash_tips_cents from public.shifts
        where id = public.payday_legacy_shift_id('2026-03-05')
          and user_id = '22222222-2222-4222-8222-222222222222') = 7000,
  'A=' || coalesce((select cash_tips_cents::text from public.shifts
                     where id = public.payday_legacy_shift_id('2026-03-05')
                       and user_id = '11111111-1111-4111-8111-111111111111'), 'missing')
    || ' B=' || coalesce((select cash_tips_cents::text from public.shifts
                     where id = public.payday_legacy_shift_id('2026-03-05')
                       and user_id = '22222222-2222-4222-8222-222222222222'), 'missing'));

select pg_temp.expect(
  'thereIsNoUniqueConstraintOnShiftsIDAlone',
  not exists (
    select 1 from pg_index i
    join pg_class c on c.oid = i.indrelid
    where c.relname = 'shifts' and c.relnamespace = 'public'::regnamespace
      and i.indisunique and i.indnatts = 1
      and (select attname from pg_attribute
            where attrelid = i.indrelid and attnum = i.indkey[0]) = 'id'));

-- 3. The two receipt CHECKs ---------------------------------------------------

select pg_temp.expect('shifts_receipt_is_v2_rejects_an_absent_key', o like '23514%', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000101', '11111111-1111-4111-8111-111111111111',
          '2026-03-06', '{}'::jsonb, now())$sql$) as o;

select pg_temp.expect('shifts_receipt_is_v2_rejects_json_null', o like '23514%', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000102', '11111111-1111-4111-8111-111111111111',
          '2026-03-06', '{"earningsSchemaVersion": null}'::jsonb, now())$sql$) as o;

select pg_temp.expect('shifts_receipt_is_v2_rejects_the_string_1', o like '23514%', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000103', '11111111-1111-4111-8111-111111111111',
          '2026-03-06', '{"earningsSchemaVersion": "1"}'::jsonb, now())$sql$) as o;

-- true is the case that matters: an unguarded ::numeric cast inside the CHECK
-- raises 22P02, a statement abort no constraint-name handler can catch, and
-- that abort would land inside a shipped 1.0 build's transaction.
select pg_temp.expect('shifts_receipt_is_v2_rejects_true_as_23514_never_22P02', o like '23514%', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000104', '11111111-1111-4111-8111-111111111111',
          '2026-03-06', '{"earningsSchemaVersion": true}'::jsonb, now())$sql$) as o;

select pg_temp.expect('shifts_receipt_is_v2_accepts_2', o = '00000', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000105', '11111111-1111-4111-8111-111111111111',
          '2026-03-06', '{"earningsSchemaVersion": 2}'::jsonb, now())$sql$) as o;

-- An array satisfies neither CHECK (`-> 'earningsSchemaVersion'` on an array
-- is NULL, so is_v2's CASE falls to its else), and which of the two Postgres
-- names is not contracted, so the name is recorded rather than asserted.
select pg_temp.expect(
  'shifts_receipt_is_object_rejects_an_array',
  o in ('23514/shifts_receipt_is_object', '23514/shifts_receipt_is_v2'), o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000106', '11111111-1111-4111-8111-111111111111',
          '2026-03-06', '[1,2]'::jsonb, now())$sql$) as o;

select pg_temp.expect(
  'bothReceiptCHECKsAreInTheCatalogAsWritten',
  (select pg_get_constraintdef(oid) from pg_constraint
    where conname = 'shifts_receipt_is_object' and conrelid = 'public.shifts'::regclass)
    = 'CHECK (((receipt_metrics IS NULL) OR (jsonb_typeof(receipt_metrics) = ''object''::text)))'
  and (select pg_get_constraintdef(oid) from pg_constraint
    where conname = 'shifts_receipt_is_v2' and conrelid = 'public.shifts'::regclass)
      like '%CASE jsonb_typeof%earningsSchemaVersion%',
  coalesce((select pg_get_constraintdef(oid) from pg_constraint
    where conname = 'shifts_receipt_is_v2' and conrelid = 'public.shifts'::regclass), 'missing'));

-- 4. The money columns: rounding and the numeric-space clamps -----------------

select pg_temp.expect('aFractionalGratuityInsertsWithNo22003', o = '00000', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, credit_tips_cents, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000201', '11111111-1111-4111-8111-111111111111',
          '2026-03-07', 5000, '{"earningsSchemaVersion":2,"gratuityFeesCents":1234.6}'::jsonb, now())$sql$) as o;

select pg_temp.expect('gratuityOf1234point6RoundsTo1235',
  gratuity_fees_cents = 1235 and non_wage_earnings_cents = 6235,
  'gratuity=' || gratuity_fees_cents::text || ' nonwage=' || non_wage_earnings_cents::text)
from public.shifts where id = '00000000-0000-4000-8000-000000000201';

select pg_temp.expect('aGratuityOf99999999999InsertsWithNo22003', o = '00000', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, cash_tips_cents, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000202', '11111111-1111-4111-8111-111111111111',
          '2026-03-08', 5000, '{"earningsSchemaVersion":2,"gratuityFeesCents":99999999999}'::jsonb, now())$sql$) as o;

select pg_temp.expect('gratuityOf99999999999ClampsToInt4Max',
  gratuity_fees_cents = 2147483647 and non_wage_earnings_cents = 2147483647,
  'gratuity=' || gratuity_fees_cents::text || ' nonwage=' || non_wage_earnings_cents::text)
from public.shifts where id = '00000000-0000-4000-8000-000000000202';

select pg_temp.expect('aGratuityOf1e30InsertsWithNo22003', o = '00000', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000203', '11111111-1111-4111-8111-111111111111',
          '2026-03-09', '{"earningsSchemaVersion":2,"gratuityFeesCents":1e30}'::jsonb, now())$sql$) as o;

select pg_temp.expect('gratuityOf1e30ClampsToInt4Max',
  gratuity_fees_cents = 2147483647 and non_wage_earnings_cents = 2147483647,
  'gratuity=' || gratuity_fees_cents::text || ' nonwage=' || non_wage_earnings_cents::text)
from public.shifts where id = '00000000-0000-4000-8000-000000000203';

select pg_temp.expect('aNegativeGratuityInsertsWithNo22003', o = '00000', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, cash_tips_cents, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000204', '11111111-1111-4111-8111-111111111111',
          '2026-03-10', 1000, '{"earningsSchemaVersion":2,"gratuityFeesCents":-500}'::jsonb, now())$sql$) as o;

select pg_temp.expect('aNegativeGratuityClampsToZero',
  gratuity_fees_cents = 0 and non_wage_earnings_cents = 1000,
  'gratuity=' || gratuity_fees_cents::text || ' nonwage=' || non_wage_earnings_cents::text)
from public.shifts where id = '00000000-0000-4000-8000-000000000204';

-- Clamping gratuity alone is not enough: this sum overflows int4 even though
-- every input is in range.
select pg_temp.expect('cash2147483000PlusGratuity2000000InsertsWithNo22003', o = '00000', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, cash_tips_cents, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000205', '11111111-1111-4111-8111-111111111111',
          '2026-03-11', 2147483000, '{"earningsSchemaVersion":2,"gratuityFeesCents":2000000}'::jsonb, now())$sql$) as o;

select pg_temp.expect('anInRangeSumThatOverflowsIsClampedNotAborted',
  gratuity_fees_cents = 2000000 and non_wage_earnings_cents = 2147483647,
  'gratuity=' || gratuity_fees_cents::text || ' nonwage=' || non_wage_earnings_cents::text)
from public.shifts where id = '00000000-0000-4000-8000-000000000205';

select pg_temp.expect('aNonNumberGratuityIsZeroNot22P02', o = '00000', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, cash_tips_cents, receipt_metrics, client_updated_at)
  values ('00000000-0000-4000-8000-000000000206', '11111111-1111-4111-8111-111111111111',
          '2026-03-12', 2500, '{"earningsSchemaVersion":2,"gratuityFeesCents":"hi"}'::jsonb, now())$sql$) as o;

select pg_temp.expect('aStringGratuityContributesZero',
  gratuity_fees_cents = 0 and non_wage_earnings_cents = 2500,
  'gratuity=' || gratuity_fees_cents::text || ' nonwage=' || non_wage_earnings_cents::text)
from public.shifts where id = '00000000-0000-4000-8000-000000000206';

select pg_temp.expect('non_wage_earnings_cents_may_go_legally_negative', o = '00000', o)
from pg_temp.outcome_of($sql$
  insert into public.shifts (id, user_id, work_date, cash_tips_cents, tip_out_cents, client_updated_at)
  values ('00000000-0000-4000-8000-000000000207', '11111111-1111-4111-8111-111111111111',
          '2026-03-13', 1000, 5000, now())$sql$) as o;

select pg_temp.expect('aTipOutLargerThanTheNightIsMinusFourThousand',
  non_wage_earnings_cents = -4000, 'nonwage=' || non_wage_earnings_cents::text)
from public.shifts where id = '00000000-0000-4000-8000-000000000207';

-- 5. The version trigger ------------------------------------------------------

do $$
declare v_version bigint; v_derived bigint; v_updated timestamptz;
begin
  update public.shifts set note = 'a native edit'
   where id = '00000000-0000-4000-8000-000000000207';
  select version, derived_version into v_version, v_derived
    from public.shifts where id = '00000000-0000-4000-8000-000000000207';
  perform pg_temp.expect('anOrdinaryUpdateBumpsVersionAndNotDerivedVersion',
    v_version = 2 and v_derived = 0,
    'version=' || v_version::text || ' derived_version=' || v_derived::text);

  perform set_config('payday.folding', 'on', true);
  update public.shifts set note = 'a derivation'
   where id = '00000000-0000-4000-8000-000000000207';
  select version, derived_version, updated_at into v_version, v_derived, v_updated
    from public.shifts where id = '00000000-0000-4000-8000-000000000207';
  perform pg_temp.expect('aFoldFreezesVersionBumpsDerivedVersionAndStillAdvancesUpdatedAt',
    v_version = 2 and v_derived = 1 and v_updated is not null,
    'version=' || v_version::text || ' derived_version=' || v_derived::text);
  perform set_config('payday.folding', 'off', true);
end;
$$;

-- 6. RLS and the select-only grant -------------------------------------------

do $$
declare v_state text; v_seen integer;
begin
  begin
    perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
    set local role authenticated;
    insert into public.shifts (id, user_id, work_date, cash_tips_cents, client_updated_at)
    values ('00000000-0000-4000-8000-000000000301', '11111111-1111-4111-8111-111111111111',
            '2026-03-14', 100, now());
    v_state := '00000';
  exception when others then
    v_state := sqlstate;
  end;
  reset role;
  perform pg_temp.expect('an_authenticated_direct_insert_into_shifts_is_denied',
    v_state = '42501', 'sqlstate=' || v_state);

  begin
    perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
    set local role authenticated;
    select count(*) into v_seen from public.shifts;
    v_state := '00000';
  exception when others then
    v_state := sqlstate; v_seen := -1;
  end;
  reset role;
  perform pg_temp.expect('anAuthenticatedSelectSeesOnlyItsOwnShifts',
    v_state = '00000' and v_seen = (select count(*) from public.shifts
                                     where user_id = '11111111-1111-4111-8111-111111111111'),
    'sqlstate=' || v_state || ' seen=' || v_seen::text
      || ' own=' || (select count(*) from public.shifts
                      where user_id = '11111111-1111-4111-8111-111111111111')::text);

  -- Both generated columns call private.receipt_gratuity_cents, and schema
  -- private has no usage grant. A stored generated column is read as stored
  -- data, not recomputed, so this must not need EXECUTE -- if it did, every
  -- device read of a shift would 42501.
  begin
    perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
    set local role authenticated;
    select count(*) into v_seen from public.shifts
      where gratuity_fees_cents >= 0 and non_wage_earnings_cents is not null;
    v_state := '00000';
  exception when others then
    v_state := sqlstate; v_seen := -1;
  end;
  reset role;
  perform pg_temp.expect('anAuthenticatedReadOfTheGeneratedColumnsNeedsNoPrivateUsage',
    v_state = '00000' and v_seen > 0, 'sqlstate=' || v_state || ' rows=' || v_seen::text);

  begin
    perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
    set local role authenticated;
    insert into public.shift_legacy_conflicts (user_id, shift_id, shift_cents_before, legacy_cents_after)
    values ('22222222-2222-4222-8222-222222222222', public.payday_legacy_shift_id('2026-03-05'), 1, 2);
    v_state := '00000';
  exception when others then
    v_state := sqlstate;
  end;
  reset role;
  perform pg_temp.expect('an_authenticated_direct_insert_into_conflicts_is_denied',
    v_state = '42501', 'sqlstate=' || v_state);

  begin
    perform set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
    set local role authenticated;
    select count(*) into v_seen from private.shift_fold_backlog;
    v_state := '00000';
  exception when others then
    v_state := sqlstate; v_seen := -1;
  end;
  reset role;
  perform pg_temp.expect('theFoldsPrivateTablesAreUnreachableByAuthenticated',
    v_state = '42501', 'sqlstate=' || v_state);
end;
$$;

-- The table revoke above does not reach the table's identity sequence: they
-- are two separate objects and `alter default privileges in schema public
-- grant all on sequences` covers the sequence as well. USAGE/SELECT there is
-- a global cross-tenant conflict count via last_value; UPDATE there is the
-- setval primitive, and a hostile setval makes arm 4's insert raise 23505
-- forever, which 4.6 swallows into a permanent never-converted backlog.
-- PUBLIC is checked too because the revoke names it.
select pg_temp.expect('theConflictsIdentitySequenceIsUnreachableByAnonAndAuthenticated',
  not exists (select 1 from pg_class c, aclexplode(c.relacl) a
              where c.relkind = 'S' and c.relname = 'shift_legacy_conflicts_id_seq'
                and (a.grantee = 0
                     or a.grantee::regrole::text in ('anon', 'authenticated'))),
  coalesce((select array_to_string(relacl, ',') from pg_class
             where relkind = 'S' and relname = 'shift_legacy_conflicts_id_seq'),
           'no acl (owner only)'));

-- 7. Indexes ------------------------------------------------------------------

select pg_temp.expect('theThreeShiftsIndexesAndTheLegacyGroupIndexExist',
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind = 'i' and n.nspname in ('public', 'private')
      and c.relname in ('shifts_user_work_date_idx', 'shifts_user_updated_idx',
                        'shifts_legacy_entry_ids_idx', 'tip_entries_user_group_all_idx',
                        'shift_legacy_conflicts_user_idx', 'shift_fold_backlog_queued_idx')) = 6,
  (select string_agg(c.relname, ' ' order by c.relname) from pg_class c
    where c.relkind = 'i' and c.relname in ('shifts_user_work_date_idx', 'shifts_user_updated_idx',
      'shifts_legacy_entry_ids_idx', 'tip_entries_user_group_all_idx',
      'shift_legacy_conflicts_user_idx', 'shift_fold_backlog_queued_idx')));

select pg_temp.expect('theLegacyGroupIndexIsNotPartial',
  (select indpred is null from pg_index i join pg_class c on c.oid = i.indexrelid
    where c.relname = 'tip_entries_user_group_all_idx'));

-- 8. Account deletion ---------------------------------------------------------

select pg_temp.expect('allFiveNewTablesCascadeFromAuthUsers',
  (select count(*) from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    where con.contype = 'f' and con.confdeltype = 'c'
      and con.confrelid = 'auth.users'::regclass
      and (n.nspname || '.' || c.relname) in (
        'public.shifts', 'public.shift_legacy_conflicts', 'public.shift_migration_state',
        'private.shift_fold_backlog', 'private.shift_fold_failures')) = 5,
  (select coalesce(string_agg(n.nspname || '.' || c.relname, ' ' order by c.relname), 'none')
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    where con.contype = 'f' and con.confdeltype = 'c' and con.confrelid = 'auth.users'::regclass
      and (n.nspname || '.' || c.relname) in (
        'public.shifts', 'public.shift_legacy_conflicts', 'public.shift_migration_state',
        'private.shift_fold_backlog', 'private.shift_fold_failures')));

insert into public.shifts (id, user_id, work_date, cash_tips_cents, source, client_updated_at)
values ('00000000-0000-4000-8000-000000000401', '33333333-3333-4333-8333-333333333333',
        '2026-07-01', 4200, 'migration', now());
insert into public.shift_legacy_conflicts (user_id, shift_id, shift_cents_before, legacy_cents_after)
values ('33333333-3333-4333-8333-333333333333', '00000000-0000-4000-8000-000000000401', 5000, 7000);
-- `on conflict do update` rather than a bare insert: account creation now
-- stamps a state row (20260920030000), so this user already has one by the
-- time the cascade fixture runs. The test is about the FOREIGN KEY cascade,
-- not about who wrote the row, so it sets the values it needs either way.
insert into public.shift_migration_state (user_id, migrated_at, remaining_group_count, last_run_at)
values ('33333333-3333-4333-8333-333333333333', now(), 3, now())
on conflict (user_id) do update
  set migrated_at = excluded.migrated_at,
      remaining_group_count = excluded.remaining_group_count,
      last_run_at = excluded.last_run_at;
insert into private.shift_fold_backlog (user_id, group_key)
values ('33333333-3333-4333-8333-333333333333', public.payday_legacy_shift_id('2026-07-01'));
insert into private.shift_fold_failures (user_id, group_keys, sqlstate, message)
values ('33333333-3333-4333-8333-333333333333',
        array[public.payday_legacy_shift_id('2026-07-01')], '57014', 'canceling statement due to statement timeout');

select pg_temp.expect('allFiveNewTablesHoldRowsBeforeTheDeletion',
  (select count(*) from public.shifts where user_id = '33333333-3333-4333-8333-333333333333')
  + (select count(*) from public.shift_legacy_conflicts where user_id = '33333333-3333-4333-8333-333333333333')
  + (select count(*) from public.shift_migration_state where user_id = '33333333-3333-4333-8333-333333333333')
  + (select count(*) from private.shift_fold_backlog where user_id = '33333333-3333-4333-8333-333333333333')
  + (select count(*) from private.shift_fold_failures where user_id = '33333333-3333-4333-8333-333333333333') = 5);

do $$
declare v_state text;
begin
  begin
    perform set_config('request.jwt.claim.sub', '33333333-3333-4333-8333-333333333333', true);
    set local role authenticated;
    perform public.delete_my_account();
    v_state := '00000';
  exception when others then
    v_state := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  perform pg_temp.expect('delete_my_account_succeeds_with_shift_rows_present',
    v_state = '00000', v_state);
end;
$$;

select pg_temp.expect('delete_my_account_leaves_zero_rows_in_all_five_new_tables',
  (select count(*) from public.shifts where user_id = '33333333-3333-4333-8333-333333333333') = 0
  and (select count(*) from public.shift_legacy_conflicts where user_id = '33333333-3333-4333-8333-333333333333') = 0
  and (select count(*) from public.shift_migration_state where user_id = '33333333-3333-4333-8333-333333333333') = 0
  and (select count(*) from private.shift_fold_backlog where user_id = '33333333-3333-4333-8333-333333333333') = 0
  and (select count(*) from private.shift_fold_failures where user_id = '33333333-3333-4333-8333-333333333333') = 0,
  'shifts=' || (select count(*) from public.shifts where user_id = '33333333-3333-4333-8333-333333333333')::text
  || ' conflicts=' || (select count(*) from public.shift_legacy_conflicts where user_id = '33333333-3333-4333-8333-333333333333')::text
  || ' state=' || (select count(*) from public.shift_migration_state where user_id = '33333333-3333-4333-8333-333333333333')::text
  || ' backlog=' || (select count(*) from private.shift_fold_backlog where user_id = '33333333-3333-4333-8333-333333333333')::text
  || ' failures=' || (select count(*) from private.shift_fold_failures where user_id = '33333333-3333-4333-8333-333333333333')::text);

-- Report ----------------------------------------------------------------------

-- An assertion whose driving SELECT returns no row never calls pg_temp.expect
-- and would vanish from the report instead of failing, so the count of the
-- assertions ahead of this line is pinned.
select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 43,
  'ran ' || (select count(*) from results)::text || ' of 43');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed
from results;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'shift_schema_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'shift_schema_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id in (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333');
