-- PR E1: public.shifts.job_name and public.paycheck_records.job_name, a job
-- tag per shift and per paycheck (NULL = the primary job).
--
-- Same plain-psql convention as the other suites (see roles_test.sql):
-- assertions land in a temporary `results` table and the last statement
-- raises, so psql exits non-zero under ON_ERROR_STOP=1. All figures are
-- synthetic round numbers.

\set ON_ERROR_STOP on
\timing off
\pset pager off

create temporary table results (
  seq serial primary key, name text not null, ok boolean not null, detail text not null default '');

create function pg_temp.expect(p_name text, p_ok boolean, p_detail text default '')
returns void language sql as $$
  insert into results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail);
$$;

create function pg_temp.rpc_as(p_uid uuid, p_sql text)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  set local role authenticated;
  execute 'select jsonb_agg(to_jsonb(t)) from (' || p_sql || ') t' into v;
  reset role;
  return coalesce(v, '[]'::jsonb);
end;
$$;

delete from auth.users where id = '88888888-8888-4888-8888-888888888888';
insert into auth.users (id, email) values
  ('88888888-8888-4888-8888-888888888888', 'payday-pr-e1@test.invalid');

-- ===========================================================================
-- 1. The columns
-- ===========================================================================

select pg_temp.expect('theShiftColumnExistsAsText',
  exists (select 1 from information_schema.columns
           where table_schema = 'public' and table_name = 'shifts'
             and column_name = 'job_name' and data_type = 'text' and is_nullable = 'YES'),
  '');

select pg_temp.expect('thePaycheckColumnExistsAsText',
  exists (select 1 from information_schema.columns
           where table_schema = 'public' and table_name = 'paycheck_records'
             and column_name = 'job_name' and data_type = 'text' and is_nullable = 'YES'),
  '');

do $$
declare v_shift_long boolean := false; v_shift_empty boolean := false;
        v_check_long boolean := false; v_check_empty boolean := false;
begin
  insert into public.shifts (user_id, id, work_date, client_updated_at)
  values ('88888888-8888-4888-8888-888888888888', '0b0b0b0b-0000-4000-8000-0000000000ff',
          '2026-10-01', now());
  begin
    update public.shifts set job_name = repeat('x', 41)
     where id = '0b0b0b0b-0000-4000-8000-0000000000ff';
  exception when check_violation then v_shift_long := true;
  end;
  begin
    update public.shifts set job_name = ''
     where id = '0b0b0b0b-0000-4000-8000-0000000000ff';
  exception when check_violation then v_shift_empty := true;
  end;
  insert into public.paycheck_records (id, user_id, period_start, period_end, paid_tips_cents, client_updated_at)
  values ('0c0c0c0c-0000-4000-8000-0000000000ff', '88888888-8888-4888-8888-888888888888',
          '2026-10-01', '2026-10-14', 0, now());
  begin
    update public.paycheck_records set job_name = repeat('x', 41)
     where id = '0c0c0c0c-0000-4000-8000-0000000000ff';
  exception when check_violation then v_check_long := true;
  end;
  begin
    update public.paycheck_records set job_name = ''
     where id = '0c0c0c0c-0000-4000-8000-0000000000ff';
  exception when check_violation then v_check_empty := true;
  end;
  perform pg_temp.expect('aFortyOneCharacterShiftJobViolatesTheCheck', v_shift_long, '');
  perform pg_temp.expect('anEmptyShiftJobViolatesTheCheck', v_shift_empty, '');
  perform pg_temp.expect('aFortyOneCharacterPaycheckJobViolatesTheCheck', v_check_long, '');
  perform pg_temp.expect('anEmptyPaycheckJobViolatesTheCheck', v_check_empty, '');
  delete from public.shifts where id = '0b0b0b0b-0000-4000-8000-0000000000ff';
  delete from public.paycheck_records where id = '0c0c0c0c-0000-4000-8000-0000000000ff';
end;
$$;

-- ===========================================================================
-- 2. write_shifts stores the job, keeps it when the key is absent
-- ===========================================================================

select pg_temp.rpc_as('88888888-8888-4888-8888-888888888888', $s$
  select * from public.upsert_shifts($j$[
    {"id":"0b0b0b0b-0000-4000-8000-000000000001","work_date":"2026-10-05",
     "cash_tips_cents":10000,"hours_worked":6,"job_name":"  Cafe  ","role_name":"Bar"},
    {"id":"0b0b0b0b-0000-4000-8000-000000000002","work_date":"2026-10-05",
     "cash_tips_cents":20000,"hours_worked":6,"job_name":"   "},
    {"id":"0b0b0b0b-0000-4000-8000-000000000003","work_date":"2026-10-06",
     "cash_tips_cents":10000,"job_name":12}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('aShiftJobIsStoredTrimmed',
  (select job_name = 'Cafe' and role_name = 'Bar' from public.shifts
    where id = '0b0b0b0b-0000-4000-8000-000000000001'),
  (select coalesce(job_name, 'NULL') from public.shifts where id = '0b0b0b0b-0000-4000-8000-000000000001'));

select pg_temp.expect('aBlankShiftJobIsStoredAsNull',
  (select job_name is null from public.shifts where id = '0b0b0b0b-0000-4000-8000-000000000002'),
  '');

select pg_temp.expect('aNonTextShiftJobIsDroppedAndTheRowStored',
  (select job_name is null and cash_tips_cents = 10000
     from public.shifts where id = '0b0b0b0b-0000-4000-8000-000000000003'),
  '');

select pg_temp.expect('theJobIsNotMoney',
  (select non_wage_earnings_cents = 10000 from public.shifts
    where id = '0b0b0b0b-0000-4000-8000-000000000001'),
  '');

create temporary table outcomes (shift_id uuid, status text);
insert into outcomes
select (r ->> 'shift_id')::uuid, r ->> 'status'
from jsonb_array_elements(pg_temp.rpc_as('88888888-8888-4888-8888-888888888888', format($s$
  select * from public.upsert_shifts('[{"id":"0b0b0b0b-0000-4000-8000-000000000004",
     "work_date":"2026-10-07","cash_tips_cents":1000,"job_name":"%s"}]'::jsonb)
$s$, repeat('y', 41)))) as r;

select pg_temp.expect('aLongShiftJobThroughTheWriterIsCutToForty',
  (select status = 'stored' from outcomes where shift_id = '0b0b0b0b-0000-4000-8000-000000000004')
  and (select job_name = repeat('y', 40) from public.shifts
        where id = '0b0b0b0b-0000-4000-8000-000000000004'),
  coalesce((select status from outcomes where shift_id = '0b0b0b0b-0000-4000-8000-000000000004'), 'missing'));

-- An older build edits the cafe shift: no job_name key (and no role_name).
select pg_temp.rpc_as('88888888-8888-4888-8888-888888888888', $s$
  select * from public.upsert_shifts($j$[
    {"id":"0b0b0b0b-0000-4000-8000-000000000001","work_date":"2026-10-05",
     "cash_tips_cents":12000,"hours_worked":6,"note":"edited on an older build"}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('anOlderBuildsShiftWriteKeepsTheStoredJob',
  (select job_name = 'Cafe' and role_name = 'Bar' and cash_tips_cents = 12000
     from public.shifts where id = '0b0b0b0b-0000-4000-8000-000000000001'),
  (select coalesce(job_name, 'NULL') from public.shifts where id = '0b0b0b0b-0000-4000-8000-000000000001'));

select pg_temp.rpc_as('88888888-8888-4888-8888-888888888888', $s$
  select * from public.upsert_shifts($j$[
    {"id":"0b0b0b0b-0000-4000-8000-000000000001","work_date":"2026-10-05",
     "cash_tips_cents":12000,"hours_worked":6,"job_name":null,"role_name":"Bar"}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('anExplicitNullMovesTheShiftToThePrimaryJob',
  (select job_name is null from public.shifts where id = '0b0b0b0b-0000-4000-8000-000000000001'),
  '');

-- ===========================================================================
-- 3. The legacy fold leaves a stored job untouched
-- ===========================================================================

insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
values ('0f0f0f0f-0000-4000-8000-000000000001', '88888888-8888-4888-8888-888888888888',
        '0b0b0b0b-0000-4000-8000-000000000020', '2026-10-12', 4000, 'cash',
        '2026-10-12 23:00:00+00');
select private.derive_shifts('88888888-8888-4888-8888-888888888888',
  array['0b0b0b0b-0000-4000-8000-000000000020'::uuid]);
update public.shifts set job_name = 'Cafe'
 where id = '0b0b0b0b-0000-4000-8000-000000000020';
update public.tip_entries set amount_cents = 4500,
       client_updated_at = '2026-10-13 00:00:00+00'
 where id = '0f0f0f0f-0000-4000-8000-000000000001';
select private.derive_shifts('88888888-8888-4888-8888-888888888888',
  array['0b0b0b0b-0000-4000-8000-000000000020'::uuid]);

select pg_temp.expect('theFoldsUpdateArmDoesNotClearTheJob',
  (select job_name = 'Cafe' and cash_tips_cents = 4500
     from public.shifts where id = '0b0b0b0b-0000-4000-8000-000000000020'),
  (select coalesce(job_name, 'NULL') || '/' || cash_tips_cents::text from public.shifts
    where id = '0b0b0b0b-0000-4000-8000-000000000020'));

-- ===========================================================================
-- 4. Paychecks: import and upsert carry the job
-- ===========================================================================

select pg_temp.rpc_as('88888888-8888-4888-8888-888888888888', $s$
  select * from public.import_paycheck_records($j$[
    {"id":"0c0c0c0c-0000-4000-8000-000000000001","period_start":"2026-10-01",
     "period_end":"2026-10-14","paid_tips_cents":10000,"job_name":"  Cafe ",
     "client_updated_at":"2026-10-15T00:00:00Z"},
    {"id":"0c0c0c0c-0000-4000-8000-000000000002","period_start":"2026-10-01",
     "period_end":"2026-10-14","paid_tips_cents":10000,
     "client_updated_at":"2026-10-15T00:00:00Z"}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('importStoresAPaycheckJobTrimmed',
  (select job_name = 'Cafe' from public.paycheck_records where id = '0c0c0c0c-0000-4000-8000-000000000001'),
  (select coalesce(job_name, 'NULL') from public.paycheck_records where id = '0c0c0c0c-0000-4000-8000-000000000001'));

select pg_temp.expect('importWithoutTheKeyStoresThePrimaryJob',
  (select job_name is null and paid_tips_cents = 10000
     from public.paycheck_records where id = '0c0c0c0c-0000-4000-8000-000000000002'),
  '');

-- An older build re-uploads the cafe check with no job_name key.
select pg_temp.rpc_as('88888888-8888-4888-8888-888888888888', $s$
  select * from public.upsert_paycheck_records($j$[
    {"id":"0c0c0c0c-0000-4000-8000-000000000001","period_start":"2026-10-01",
     "period_end":"2026-10-14","paid_tips_cents":11000,
     "client_updated_at":"2026-10-16T00:00:00Z"}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('anOlderBuildsPaycheckWriteKeepsTheStoredJob',
  (select job_name = 'Cafe' and paid_tips_cents = 11000
     from public.paycheck_records where id = '0c0c0c0c-0000-4000-8000-000000000001'),
  (select coalesce(job_name, 'NULL') from public.paycheck_records where id = '0c0c0c0c-0000-4000-8000-000000000001'));

select pg_temp.rpc_as('88888888-8888-4888-8888-888888888888', format($s$
  select * from public.upsert_paycheck_records('[
    {"id":"0c0c0c0c-0000-4000-8000-000000000002","period_start":"2026-10-01",
     "period_end":"2026-10-14","paid_tips_cents":10000,"job_name":"%s",
     "client_updated_at":"2026-10-16T00:00:00Z"}
  ]'::jsonb)
$s$, repeat('z', 41)));

select pg_temp.expect('upsertCutsALongPaycheckJobToForty',
  (select job_name = repeat('z', 40) from public.paycheck_records
    where id = '0c0c0c0c-0000-4000-8000-000000000002'),
  '');

select pg_temp.rpc_as('88888888-8888-4888-8888-888888888888', $s$
  select * from public.upsert_paycheck_records($j$[
    {"id":"0c0c0c0c-0000-4000-8000-000000000001","period_start":"2026-10-01",
     "period_end":"2026-10-14","paid_tips_cents":11000,"job_name":null,
     "client_updated_at":"2026-10-17T00:00:00Z"}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('anExplicitNullMovesThePaycheckToThePrimaryJob',
  (select job_name is null from public.paycheck_records where id = '0c0c0c0c-0000-4000-8000-000000000001'),
  '');

-- ---------------------------------------------------------------------------
-- The paycheck upsert queues writers for one user (an advisory lock, as
-- private.write_shifts does): its missing-key fallback reads the STORED job,
-- and without the lock a newer phone's upload could commit between that read
-- and the conflict update. Two concurrent sessions cannot be produced here,
-- so the lock itself is pinned.
-- ---------------------------------------------------------------------------

select pg_temp.expect('upsertPaycheckRecordsSerialisesPerUser',
  pg_get_functiondef('public.upsert_paycheck_records(jsonb)'::regprocedure) like '%pg_advisory_xact_lock%',
  '');

-- ===========================================================================
-- 6. upsert_user_settings keeps the stored job list from an older build (E2a)
-- ===========================================================================

-- One settings write as the test user. `p_policies` NULL sends no
-- compensation_policies key at all (the shipped 1.0 key set).
create function pg_temp.settings_as(p_policies jsonb, p_at text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '88888888-8888-4888-8888-888888888888', true);
  set local role authenticated;
  perform public.upsert_user_settings(jsonb_strip_nulls(jsonb_build_object(
    'first_name', 'Sam',
    'pay_frequency', 'biweekly',
    'anchor_period_end', '2026-10-04',
    'compensation_policies', p_policies,
    'client_updated_at', p_at)));
  reset role;
end;
$$;

create function pg_temp.policies(p_rate integer, p_jobs jsonb default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'version', 1,
    'rates', jsonb_build_array(jsonb_build_object(
      'id', '0e0e0e0e-0000-4000-8000-000000000001', 'effectiveFrom', '2026-01-01',
      'hourlyRateCents', p_rate, 'provenance', 'confirmed')),
    'calendars', '[]'::jsonb,
    'jobs', p_jobs));
$$;

create function pg_temp.stored_job_names() returns text language sql as $$
  select coalesce((select string_agg(j ->> 'name', ',' order by ord)
    from public.user_settings us,
         jsonb_array_elements(us.compensation_policies -> 'jobs') with ordinality as t(j, ord)
    where us.user_id = '88888888-8888-4888-8888-888888888888'), '');
$$;

create function pg_temp.stored_rate() returns text language sql as $$
  select compensation_policies -> 'rates' -> 0 ->> 'hourlyRateCents'
  from public.user_settings where user_id = '88888888-8888-4888-8888-888888888888';
$$;

select pg_temp.settings_as(pg_temp.policies(1000, $j$[
  {"id":"0e0e0e0e-0000-4000-8000-000000000010","name":"Main job","isPrimary":true}]$j$::jsonb),
  '2026-11-01T10:00:00Z');
select pg_temp.settings_as(pg_temp.policies(1000, $j$[
  {"id":"0e0e0e0e-0000-4000-8000-000000000010","name":"Main job","isPrimary":true},
  {"id":"0e0e0e0e-0000-4000-8000-000000000011","name":"Cafe","isPrimary":false}]$j$::jsonb),
  '2026-11-01T11:00:00Z');

select pg_temp.expect('aNewBuildWithJobsReplacesTheJobList',
  pg_temp.stored_job_names() = 'Main job,Cafe', pg_temp.stored_job_names());

-- An older build edits the wage: policies with no `jobs` key.
select pg_temp.settings_as(pg_temp.policies(1100), '2026-11-01T12:00:00Z');

select pg_temp.expect('anOldBuildWithoutTheJobsKeyKeepsTheStoredJobs',
  pg_temp.stored_job_names() = 'Main job,Cafe', pg_temp.stored_job_names());

select pg_temp.expect('anOldBuildWithoutTheJobsKeyStillUpdatesTheRates',
  pg_temp.stored_rate() = '1100', coalesce(pg_temp.stored_rate(), 'NULL'));

-- The 1.0 key set: no compensation_policies at all keeps the whole row.
select pg_temp.settings_as(null, '2026-11-01T13:00:00Z');

select pg_temp.expect('aNullPoliciesPayloadStillKeepsTheStoredRow',
  pg_temp.stored_job_names() = 'Main job,Cafe' and pg_temp.stored_rate() = '1100',
  pg_temp.stored_job_names() || ' / ' || coalesce(pg_temp.stored_rate(), 'NULL'));

-- A build that knows jobs and has none sends `jobs: []`.
select pg_temp.settings_as(pg_temp.policies(1100, '[]'::jsonb), '2026-11-01T14:00:00Z');

select pg_temp.expect('aNewBuildWithAnEmptyJobListClearsTheJobs',
  (select compensation_policies -> 'jobs' = '[]'::jsonb from public.user_settings
    where user_id = '88888888-8888-4888-8888-888888888888'),
  pg_temp.stored_job_names());

-- ===========================================================================
-- Report
-- ===========================================================================

select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 25,
  'ran ' || (select count(*) from results)::text || ' of 25');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'jobs_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'jobs_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id = '88888888-8888-4888-8888-888888888888';
