-- PR A: card_tips_paid_at_close on user_settings, tip_share_in_cents on shifts.
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

-- Calls an RPC as the given account and hands the outcome rows back as jsonb
-- (role `authenticated` cannot write this session's temp tables).
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

delete from auth.users where id = '66666666-6666-4666-8666-666666666666';
insert into auth.users (id, email) values
  ('66666666-6666-4666-8666-666666666666', 'payday-pr-a@test.invalid');

-- ===========================================================================
-- 1. Tip share received on public.shifts
-- ===========================================================================

-- A bartender: no card tips, $180 share in, $40 tipped out.
select pg_temp.rpc_as('66666666-6666-4666-8666-666666666666', $s$
  select * from public.upsert_shifts($j$[
    {"id":"bbbbbbbb-0000-4000-8000-000000000001","work_date":"2026-10-01",
     "tip_share_in_cents":18000,"tip_out_cents":4000},
    {"id":"bbbbbbbb-0000-4000-8000-000000000002","work_date":"2026-10-02",
     "cash_tips_cents":5000,"credit_tips_cents":10000,"tip_out_cents":1000,
     "receipt_metrics":{"earningsSchemaVersion":2,"gratuityFeesCents":2000},
     "tip_share_in_cents":3000}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('aReceivedShareIsStored',
  (select tip_share_in_cents = 18000 from public.shifts
    where id = 'bbbbbbbb-0000-4000-8000-000000000001'),
  (select coalesce(tip_share_in_cents::text, 'NULL') from public.shifts
    where id = 'bbbbbbbb-0000-4000-8000-000000000001'));

select pg_temp.expect('theGeneratedNetAddsTheShareAndSubtractsTheTipOut',
  (select non_wage_earnings_cents = 14000 from public.shifts
    where id = 'bbbbbbbb-0000-4000-8000-000000000001'),
  (select non_wage_earnings_cents::text from public.shifts
    where id = 'bbbbbbbb-0000-4000-8000-000000000001'));

select pg_temp.expect('theGeneratedNetCountsEveryComponentOnce',
  -- 5000 + 10000 + 2000 gratuity + 3000 share - 1000 tip-out
  (select non_wage_earnings_cents = 19000 from public.shifts
    where id = 'bbbbbbbb-0000-4000-8000-000000000002'),
  (select non_wage_earnings_cents::text from public.shifts
    where id = 'bbbbbbbb-0000-4000-8000-000000000002'));

select pg_temp.expect('theFiveArgumentTwinMatchesTheGeneratedColumnOnEveryRow',
  not exists (
    select 1 from public.shifts s
     where s.non_wage_earnings_cents is distinct from private.legacy_non_wage_cents(
       s.cash_tips_cents, s.credit_tips_cents, s.receipt_metrics, s.tip_out_cents,
       s.tip_share_in_cents)),
  'twin and generated column disagree on at least one row');

select pg_temp.expect('theFourArgumentTwinIsTheLegacyNetWithNoShare',
  private.legacy_non_wage_cents(5000, 10000, '{"earningsSchemaVersion":2,"gratuityFeesCents":2000}'::jsonb, 1000) = 16000
  and private.legacy_non_wage_cents(5000, 10000, '{"earningsSchemaVersion":2,"gratuityFeesCents":2000}'::jsonb, 1000, null) = 16000,
  '');

-- A build that predates tip share edits the bartender's shift. It sends no
-- key at all, and must not erase the share.
select pg_temp.rpc_as('66666666-6666-4666-8666-666666666666', $s$
  select * from public.upsert_shifts($j$[
    {"id":"bbbbbbbb-0000-4000-8000-000000000001","work_date":"2026-10-01",
     "tip_out_cents":5000,"note":"edited on an older build"}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('anOlderBuildsWriteKeepsTheStoredShare',
  (select tip_share_in_cents = 18000 and tip_out_cents = 5000
          and non_wage_earnings_cents = 13000
     from public.shifts where id = 'bbbbbbbb-0000-4000-8000-000000000001'),
  (select coalesce(tip_share_in_cents::text, 'NULL') || '/' || non_wage_earnings_cents::text
     from public.shifts where id = 'bbbbbbbb-0000-4000-8000-000000000001'));

-- A current build clearing the field sends an explicit null.
select pg_temp.rpc_as('66666666-6666-4666-8666-666666666666', $s$
  select * from public.upsert_shifts($j$[
    {"id":"bbbbbbbb-0000-4000-8000-000000000001","work_date":"2026-10-01",
     "tip_out_cents":5000,"tip_share_in_cents":null}
  ]$j$::jsonb)
$s$);

select pg_temp.expect('anExplicitNullClearsTheShare',
  (select tip_share_in_cents is null and non_wage_earnings_cents = -5000
     from public.shifts where id = 'bbbbbbbb-0000-4000-8000-000000000001'),
  (select coalesce(tip_share_in_cents::text, 'NULL') from public.shifts
    where id = 'bbbbbbbb-0000-4000-8000-000000000001'));

-- Out-of-range and junk values cost the row, never the batch.
create temporary table outcomes (shift_id uuid, status text);
insert into outcomes
select (r ->> 'shift_id')::uuid, r ->> 'status'
from jsonb_array_elements(pg_temp.rpc_as('66666666-6666-4666-8666-666666666666', $s$
  select * from public.upsert_shifts($j$[
    {"id":"bbbbbbbb-0000-4000-8000-000000000003","work_date":"2026-10-03",
     "tip_share_in_cents":99999999999},
    {"id":"bbbbbbbb-0000-4000-8000-000000000004","work_date":"2026-10-04",
     "tip_share_in_cents":"abc","cash_tips_cents":1000}
  ]$j$::jsonb)
$s$)) as r;

select pg_temp.expect('anOversizedShareMakesTheRowInvalid',
  (select status = 'invalid' from outcomes where shift_id = 'bbbbbbbb-0000-4000-8000-000000000003'),
  coalesce((select status from outcomes where shift_id = 'bbbbbbbb-0000-4000-8000-000000000003'), 'missing'));

select pg_temp.expect('anUnreadableShareIsDroppedAndTheRowStored',
  (select status = 'stored' from outcomes where shift_id = 'bbbbbbbb-0000-4000-8000-000000000004')
  and (select tip_share_in_cents is null from public.shifts
        where id = 'bbbbbbbb-0000-4000-8000-000000000004'),
  coalesce((select status from outcomes where shift_id = 'bbbbbbbb-0000-4000-8000-000000000004'), 'missing'));

do $$
declare v_ok boolean := false;
begin
  begin
    update public.shifts set tip_share_in_cents = -1
     where id = 'bbbbbbbb-0000-4000-8000-000000000002';
  exception when check_violation then v_ok := true;
  end;
  perform pg_temp.expect('aNegativeShareViolatesTheCheck', v_ok, '');
end;
$$;

-- ===========================================================================
-- 2. card_tips_paid_at_close on public.user_settings
-- ===========================================================================

do $$
begin
  perform set_config('request.jwt.claim.sub', '66666666-6666-4666-8666-666666666666', true);
  set local role authenticated;
  perform public.import_user_settings(jsonb_build_object(
    'pay_frequency', 'biweekly',
    'anchor_period_end', '2026-10-04',
    'client_updated_at', '2026-10-01T12:00:00Z'));
end;
$$;

select pg_temp.expect('theSettingDefaultsToOnThePaycheck',
  (select card_tips_paid_at_close = false from public.user_settings
    where user_id = '66666666-6666-4666-8666-666666666666'),
  '');

do $$
begin
  perform set_config('request.jwt.claim.sub', '66666666-6666-4666-8666-666666666666', true);
  set local role authenticated;
  perform public.upsert_user_settings(jsonb_build_object(
    'pay_frequency', 'biweekly',
    'anchor_period_end', '2026-10-04',
    'card_tips_paid_at_close', true,
    'client_updated_at', '2026-10-01T13:00:00Z'));
end;
$$;

select pg_temp.expect('anUpsertStoresAtClose',
  (select card_tips_paid_at_close = true from public.user_settings
    where user_id = '66666666-6666-4666-8666-666666666666'),
  '');

do $$
begin
  perform set_config('request.jwt.claim.sub', '66666666-6666-4666-8666-666666666666', true);
  set local role authenticated;
  -- An older build: no card_tips_paid_at_close key at all.
  perform public.upsert_user_settings(jsonb_build_object(
    'pay_frequency', 'biweekly',
    'anchor_period_end', '2026-10-04',
    'first_weekday', 2,
    'client_updated_at', '2026-10-01T14:00:00Z'));
end;
$$;

select pg_temp.expect('anOlderBuildsUpsertKeepsTheStoredChoice',
  (select card_tips_paid_at_close = true and first_weekday = 2
     from public.user_settings where user_id = '66666666-6666-4666-8666-666666666666'),
  '');

-- ===========================================================================
-- Report
-- ===========================================================================

select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 13,
  'ran ' || (select count(*) from results)::text || ' of 13');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'tip_share_in_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'tip_share_in_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id = '66666666-6666-4666-8666-666666666666';
