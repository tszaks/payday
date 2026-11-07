-- PR B: public.shifts.role_name, a role per shift.
--
-- Same plain-psql convention as the other suites (see shift_schema_test.sql):
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

delete from auth.users where id = '77777777-7777-4777-8777-777777777777';
insert into auth.users (id, email) values
  ('77777777-7777-4777-8777-777777777777', 'payday-pr-b@test.invalid');

-- ===========================================================================
-- 1. The column
-- ===========================================================================

select pg_temp.expect('theColumnExistsAsText',
  exists (select 1 from information_schema.columns
           where table_schema = 'public' and table_name = 'shifts'
             and column_name = 'role_name' and data_type = 'text' and is_nullable = 'YES'),
  '');

select pg_temp.expect('theColumnHasItsLengthCheck',
  exists (select 1 from pg_constraint
           where conrelid = 'public.shifts'::regclass and conname = 'shifts_role_name_length'),
  '');

do $$
declare v_long boolean := false; v_empty boolean := false;
begin
  insert into public.shifts (user_id, id, work_date, client_updated_at)
  values ('77777777-7777-4777-8777-777777777777', 'eeeeeeee-0000-4000-8000-0000000000ff',
          '2026-10-01', now());
  begin
    update public.shifts set role_name = repeat('x', 41)
     where id = 'eeeeeeee-0000-4000-8000-0000000000ff';
  exception when check_violation then v_long := true;
  end;
  begin
    update public.shifts set role_name = ''
     where id = 'eeeeeeee-0000-4000-8000-0000000000ff';
  exception when check_violation then v_empty := true;
  end;
  perform pg_temp.expect('aFortyOneCharacterRoleViolatesTheCheck', v_long, '');
  perform pg_temp.expect('anEmptyRoleViolatesTheCheck', v_empty, '');
  delete from public.shifts where id = 'eeeeeeee-0000-4000-8000-0000000000ff';
end;
$$;

-- ===========================================================================
-- 2. write_shifts stores the role, keeps it when the key is absent
-- ===========================================================================

select pg_temp.rpc_as('77777777-7777-4777-8777-777777777777', $s$
  select * from public.upsert_shifts($j$[
    {"id":"eeeeeeee-0000-4000-8000-000000000001","work_date":"2026-10-05",
     "cash_tips_cents":10000,"hours_worked":6,"role_name":"  Bar  "},
    {"id":"eeeeeeee-0000-4000-8000-000000000002","work_date":"2026-10-05",
     "cash_tips_cents":20000,"hours_worked":6,"role_name":"Floor"},
    {"id":"eeeeeeee-0000-4000-8000-000000000003","work_date":"2026-10-06",
     "cash_tips_cents":10000,"role_name":"   "},
    {"id":"eeeeeeee-0000-4000-8000-000000000004","work_date":"2026-10-06",
     "cash_tips_cents":10000,"role_name":12}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('aRoleIsStoredTrimmed',
  (select role_name = 'Bar' from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000001'),
  (select coalesce(role_name, 'NULL') from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000001'));

select pg_temp.expect('aBlankRoleIsStoredAsNull',
  (select role_name is null from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000003'),
  '');

select pg_temp.expect('aNonTextRoleIsDroppedAndTheRowStored',
  (select role_name is null and cash_tips_cents = 10000
     from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000004'),
  '');

select pg_temp.expect('theRoleIsNotMoney',
  (select non_wage_earnings_cents = 20000 from public.shifts
    where id = 'eeeeeeee-0000-4000-8000-000000000002'),
  '');

-- A 41-character role through the writer costs its tail, never the batch.
create temporary table outcomes (shift_id uuid, status text);
insert into outcomes
select (r ->> 'shift_id')::uuid, r ->> 'status'
from jsonb_array_elements(pg_temp.rpc_as('77777777-7777-4777-8777-777777777777', format($s$
  select * from public.upsert_shifts('[{"id":"eeeeeeee-0000-4000-8000-000000000005",
     "work_date":"2026-10-07","cash_tips_cents":1000,"role_name":"%s"}]'::jsonb)
$s$, repeat('y', 41)))) as r;

select pg_temp.expect('aLongRoleThroughTheWriterIsCutToForty',
  (select status = 'stored' from outcomes where shift_id = 'eeeeeeee-0000-4000-8000-000000000005')
  and (select role_name = repeat('y', 40) from public.shifts
        where id = 'eeeeeeee-0000-4000-8000-000000000005'),
  coalesce((select status from outcomes where shift_id = 'eeeeeeee-0000-4000-8000-000000000005'), 'missing'));

-- An older build edits the bar shift: no role_name key at all.
select pg_temp.rpc_as('77777777-7777-4777-8777-777777777777', $s$
  select * from public.upsert_shifts($j$[
    {"id":"eeeeeeee-0000-4000-8000-000000000001","work_date":"2026-10-05",
     "cash_tips_cents":12000,"hours_worked":6,"note":"edited on an older build"}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('anOlderBuildsWriteKeepsTheStoredRole',
  (select role_name = 'Bar' and cash_tips_cents = 12000
     from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000001'),
  (select coalesce(role_name, 'NULL') from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000001'));

-- A current build clearing the role sends an explicit null.
select pg_temp.rpc_as('77777777-7777-4777-8777-777777777777', $s$
  select * from public.upsert_shifts($j$[
    {"id":"eeeeeeee-0000-4000-8000-000000000002","work_date":"2026-10-05",
     "cash_tips_cents":20000,"hours_worked":6,"role_name":null}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('anExplicitNullClearsTheRole',
  (select role_name is null from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000002'),
  '');

-- ===========================================================================
-- 3. The legacy fold leaves a stored role untouched
-- ===========================================================================

-- A night first logged on an old build: one legacy cash row of $50, folded.
insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
values ('ffffffff-0000-4000-8000-000000000001', '77777777-7777-4777-8777-777777777777',
        'eeeeeeee-0000-4000-8000-000000000010', '2026-10-10', 5000, 'cash',
        '2026-10-10 23:00:00+00');
select private.derive_shifts('77777777-7777-4777-8777-777777777777',
  array['eeeeeeee-0000-4000-8000-000000000010'::uuid]);

select pg_temp.expect('aFoldedShiftHasNoRole',
  (select role_name is null and cash_tips_cents = 5000
     from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000010'),
  '');

-- The new build sets a role on that night (and so closes it to the fold).
select pg_temp.rpc_as('77777777-7777-4777-8777-777777777777', $s$
  select * from public.upsert_shifts($j$[
    {"id":"eeeeeeee-0000-4000-8000-000000000010","work_date":"2026-10-10",
     "cash_tips_cents":5000,"role_name":"Bar"}
  ]$j$::jsonb)
$s$);

-- An old build touches the legacy row: the fold runs again.
update public.tip_entries set note = 'edited on an old build', amount_cents = 6000,
       client_updated_at = '2026-10-11 00:00:00+00'
 where id = 'ffffffff-0000-4000-8000-000000000001';
select private.derive_shifts('77777777-7777-4777-8777-777777777777',
  array['eeeeeeee-0000-4000-8000-000000000010'::uuid]);

select pg_temp.expect('theFoldLeavesAStoredRoleUntouched',
  (select role_name = 'Bar' from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000010'),
  (select coalesce(role_name, 'NULL') from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000010'));

-- A shift still OPEN to the fold (never written by a device) with a role set
-- directly: the fold's update arm rewrites money columns, never the role.
insert into public.tip_entries (id, user_id, shift_id, work_date, amount_cents, kind, client_updated_at)
values ('ffffffff-0000-4000-8000-000000000002', '77777777-7777-4777-8777-777777777777',
        'eeeeeeee-0000-4000-8000-000000000020', '2026-10-12', 4000, 'cash',
        '2026-10-12 23:00:00+00');
select private.derive_shifts('77777777-7777-4777-8777-777777777777',
  array['eeeeeeee-0000-4000-8000-000000000020'::uuid]);
update public.shifts set role_name = 'Floor'
 where id = 'eeeeeeee-0000-4000-8000-000000000020';
update public.tip_entries set amount_cents = 4500,
       client_updated_at = '2026-10-13 00:00:00+00'
 where id = 'ffffffff-0000-4000-8000-000000000002';
select private.derive_shifts('77777777-7777-4777-8777-777777777777',
  array['eeeeeeee-0000-4000-8000-000000000020'::uuid]);

select pg_temp.expect('theFoldsUpdateArmDoesNotClearTheRole',
  (select role_name = 'Floor' and cash_tips_cents = 4500 and native_modified_at is null
     from public.shifts where id = 'eeeeeeee-0000-4000-8000-000000000020'),
  (select coalesce(role_name, 'NULL') || '/' || cash_tips_cents::text from public.shifts
    where id = 'eeeeeeee-0000-4000-8000-000000000020'));

-- ===========================================================================
-- Report
-- ===========================================================================

select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 14,
  'ran ' || (select count(*) from results)::text || ' of 14');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'roles_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'roles_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id = '77777777-7777-4777-8777-777777777777';
