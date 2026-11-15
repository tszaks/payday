-- PR 2, slice S11: the agent API's read functions.
--
-- Same plain-psql convention as the other suites. Run by CI job E and by
-- `bash scripts/db-test-local.sh`.
--
-- These replace a TypeScript `groupShifts` that was a third implementation of
-- the grouping and net rules and disagreed with both other implementations on
-- the work date, the detail rank and the receipt owner. The point of reading
-- `public.shifts` is that the deriver already answered; these tests are about
-- the READ being faithful and paginating without losing a row.

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

delete from auth.users where id in (
  '61000000-0000-4000-8000-000000000001',
  '61000000-0000-4000-8000-000000000002',
  '61000000-0000-4000-8000-000000000003',
  '61000000-0000-4000-8000-000000000004');
insert into auth.users (id, email) values
  ('61000000-0000-4000-8000-000000000001', 'payday-s11-a@test.invalid'),
  ('61000000-0000-4000-8000-000000000002', 'payday-s11-b@test.invalid'),
  ('61000000-0000-4000-8000-000000000003', 'payday-s11-c@test.invalid'),
  ('61000000-0000-4000-8000-000000000004', 'payday-s11-d@test.invalid');

-- Seeded directly rather than through the write RPC, because these are READ
-- functions and the fixture needs a NULL recorded_at, which the write path
-- would not normally produce but a conversion legitimately can: a legacy
-- group whose rows never carried one.
insert into public.shifts
  (id, user_id, work_date, cash_tips_cents, credit_tips_cents, tip_out_cents,
   recorded_at, receipt_metrics, source, legacy_entry_ids, client_updated_at)
values
  -- Newest first by (work_date desc, recorded_at desc nulls last, id desc).
  ('aaaaaaaa-0000-4000-8000-000000000003', '61000000-0000-4000-8000-000000000001',
   '2026-09-03', 3000, 0, null, '2026-09-03 23:00:00+00', null, 'device', '{}', now()),
  ('aaaaaaaa-0000-4000-8000-000000000002', '61000000-0000-4000-8000-000000000001',
   '2026-09-02', 5000, 2000, 1000,
   '2026-09-02 23:00:00+00',
   '{"earningsSchemaVersion": 2, "gratuityFeesCents": 500}'::jsonb,
   'migration', array['bbbbbbbb-0000-4000-8000-0000000000b1'::uuid,
                      'bbbbbbbb-0000-4000-8000-0000000000b2'::uuid], now()),
  -- NO recorded_at. The pagination trap: treated as the newest instead of the
  -- oldest and this shift becomes unreachable past page one.
  ('aaaaaaaa-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000001',
   '2026-09-02', 1000, 0, null, null, null, 'device', '{}', now()),
  -- Tombstoned, must never appear.
  ('aaaaaaaa-0000-4000-8000-00000000000d', '61000000-0000-4000-8000-000000000001',
   '2026-09-04', 9999, 0, null, '2026-09-04 23:00:00+00', null, 'device', '{}', now()),
  -- Another account's.
  ('cccccccc-0000-4000-8000-0000000000bb', '61000000-0000-4000-8000-000000000002',
   '2026-09-03', 7777, 0, null, '2026-09-03 23:00:00+00', null, 'device', '{}', now());

update public.shifts set deleted_at = now(), deleted_reason = 'user'
 where id = 'aaaaaaaa-0000-4000-8000-00000000000d';

-- ===========================================================================
-- The listing
-- ===========================================================================

select pg_temp.expect('theListingReturnsOwnLiveShiftsNewestFirst',
  (select array_agg(id order by ord) from (
     select id, row_number() over () as ord
     from public.payday_agent_recent_shifts('61000000-0000-4000-8000-000000000001')
   ) q)
  = array['aaaaaaaa-0000-4000-8000-000000000003'::uuid,
          'aaaaaaaa-0000-4000-8000-000000000002'::uuid,
          'aaaaaaaa-0000-4000-8000-000000000001'::uuid],
  (select string_agg(id::text, ' ') from public.payday_agent_recent_shifts('61000000-0000-4000-8000-000000000001')));

select pg_temp.expect('aTombstonedShiftIsNeverListed',
  not exists (
    select 1 from public.payday_agent_recent_shifts('61000000-0000-4000-8000-000000000001')
     where id = 'aaaaaaaa-0000-4000-8000-00000000000d'));

select pg_temp.expect('anotherAccountsShiftIsNeverListed',
  not exists (
    select 1 from public.payday_agent_recent_shifts('61000000-0000-4000-8000-000000000001')
     where id = 'cccccccc-0000-4000-8000-0000000000bb'));

select pg_temp.expect('theDateWindowFilters',
  (select count(*) from public.payday_agent_recent_shifts(
     '61000000-0000-4000-8000-000000000001', '2026-09-03', '2026-09-03')) = 1);

select pg_temp.expect('theLimitIsHonouredAndCapped',
  (select count(*) from public.payday_agent_recent_shifts(
     '61000000-0000-4000-8000-000000000001', null, null, 2)) = 2
  and (select count(*) from public.payday_agent_recent_shifts(
     '61000000-0000-4000-8000-000000000001', null, null, 100000)) = 3);

-- THE PAGINATION TRAP. Page 2 continues after the second shift, and the third
-- shift has a NULL recorded_at. Treat null as the newest value and it is
-- skipped forever; the function coalesces it to -infinity on both sides of
-- every comparison for exactly this reason.
select pg_temp.expect('aShiftWithNoRecordedAtIsStillReachableOnPageTwo',
  (select array_agg(id order by ord) from (
     select id, row_number() over () as ord
     from public.payday_agent_recent_shifts(
       '61000000-0000-4000-8000-000000000001', null, null, 101,
       '2026-09-02'::date, '2026-09-02 23:00:00+00'::timestamptz,
       'aaaaaaaa-0000-4000-8000-000000000002'::uuid)
   ) q)
  = array['aaaaaaaa-0000-4000-8000-000000000001'::uuid],
  (select coalesce(string_agg(id::text, ' '), '(none)')
     from public.payday_agent_recent_shifts(
       '61000000-0000-4000-8000-000000000001', null, null, 101,
       '2026-09-02'::date, '2026-09-02 23:00:00+00'::timestamptz,
       'aaaaaaaa-0000-4000-8000-000000000002'::uuid)));

select pg_temp.expect('pagingPastTheOldestShiftReturnsNothing',
  (select count(*) from public.payday_agent_recent_shifts(
     '61000000-0000-4000-8000-000000000001', null, null, 101,
     '2026-09-02'::date, null::timestamptz,
     'aaaaaaaa-0000-4000-8000-000000000001'::uuid)) = 0);

-- The derived money comes from the table, not from a recomputation. The v2
-- receipt's gratuity is counted once and the tip-out subtracted once.
select pg_temp.expect('theDerivedMoneyIsReadNotRecomputed',
  (select 'cash=' || cash_tips_cents || ' credit=' || credit_tips_cents
       || ' gratuity=' || gratuity_fees_cents || ' nonwage=' || non_wage_earnings_cents
     from public.payday_agent_recent_shifts('61000000-0000-4000-8000-000000000001')
    where id = 'aaaaaaaa-0000-4000-8000-000000000002')
  = 'cash=5000 credit=2000 gratuity=500 nonwage=6500',
  (select 'cash=' || cash_tips_cents || ' credit=' || credit_tips_cents
       || ' gratuity=' || gratuity_fees_cents || ' nonwage=' || non_wage_earnings_cents
     from public.shifts where id = 'aaaaaaaa-0000-4000-8000-000000000002'));

-- ===========================================================================
-- One shift by id, including the pre-conversion case
-- ===========================================================================

select pg_temp.expect('aShiftIsFoundByItsOwnId',
  (select count(*) from public.payday_agent_shift_by_id(
     '61000000-0000-4000-8000-000000000001',
     'aaaaaaaa-0000-4000-8000-000000000002')) = 1);

-- THE STEP-2 LOOKUP. An agent that listed shifts BEFORE the conversion holds
-- a legacy row's id, because for a group whose rows had no shift_id the API
-- used the row's own id as the shift id. Without this arm the caller 404s on
-- a shift its own earlier response showed it.
select pg_temp.expect('aPreConversionLegacyIdStillResolvesViaProvenance',
  (select id from public.payday_agent_shift_by_id(
     '61000000-0000-4000-8000-000000000001',
     'bbbbbbbb-0000-4000-8000-0000000000b1'))
  = 'aaaaaaaa-0000-4000-8000-000000000002');

select pg_temp.expect('eitherLegacyIdOfTheGroupResolves',
  (select id from public.payday_agent_shift_by_id(
     '61000000-0000-4000-8000-000000000001',
     'bbbbbbbb-0000-4000-8000-0000000000b2'))
  = 'aaaaaaaa-0000-4000-8000-000000000002');

select pg_temp.expect('anUnknownIdResolvesToNothing',
  (select count(*) from public.payday_agent_shift_by_id(
     '61000000-0000-4000-8000-000000000001',
     'dddddddd-0000-4000-8000-00000000dead')) = 0);

select pg_temp.expect('aTombstonedShiftIsNotFoundById',
  (select count(*) from public.payday_agent_shift_by_id(
     '61000000-0000-4000-8000-000000000001',
     'aaaaaaaa-0000-4000-8000-00000000000d')) = 0);

select pg_temp.expect('anotherAccountsShiftIsNotFoundById',
  (select count(*) from public.payday_agent_shift_by_id(
     '61000000-0000-4000-8000-000000000001',
     'cccccccc-0000-4000-8000-0000000000bb')) = 0);

-- Never more than one row, or the API's single-object response shape breaks.
select pg_temp.expect('theLookupNeverReturnsMoreThanOneRow',
  (select count(*) from public.payday_agent_shift_by_id(
     '61000000-0000-4000-8000-000000000001',
     'aaaaaaaa-0000-4000-8000-000000000002')) <= 1);

-- ===========================================================================
-- The summary's shift totals, over the same rows the listing returns
-- ===========================================================================

-- Account C logs its nights the way the current app does: through
-- upsert_shifts, which writes public.shifts and never public.tip_entries.
select pg_temp.rpc_as('61000000-0000-4000-8000-000000000003', $s$
  select * from public.upsert_shifts($j$[
    {"id":"dddddddd-0000-4000-8000-0000000000c1","work_date":"2026-10-01",
     "cash_tips_cents":2000,"credit_tips_cents":6000,"tip_out_cents":1500,
     "tip_share_in_cents":3000,"sales_cents":40000,"hours_worked":5.5,
     "receipt_metrics":{"earningsSchemaVersion":2,"gratuityFeesCents":400}},
    {"id":"dddddddd-0000-4000-8000-0000000000c2","work_date":"2026-10-03",
     "cash_tips_cents":1000,"hours_worked":4},
    {"id":"dddddddd-0000-4000-8000-0000000000c3","work_date":"2026-10-05",
     "cash_tips_cents":9000},
    {"id":"dddddddd-0000-4000-8000-0000000000c4","work_date":"2026-09-30",
     "cash_tips_cents":500},
    {"id":"dddddddd-0000-4000-8000-0000000000c5","work_date":"2026-10-06",
     "credit_tips_cents":700}
  ]$j$::jsonb)
$s$);

select pg_temp.rpc_as('61000000-0000-4000-8000-000000000003', $s$
  select * from public.soft_delete_shifts($j$[
    {"id":"dddddddd-0000-4000-8000-0000000000c3","deleted_at":"2026-10-06T00:00:00Z"}
  ]$j$::jsonb)
$s$);

-- Another account's night inside C's range.
select pg_temp.rpc_as('61000000-0000-4000-8000-000000000002', $s$
  select * from public.upsert_shifts($j$[
    {"id":"dddddddd-0000-4000-8000-0000000000b1","work_date":"2026-10-02",
     "cash_tips_cents":7777}
  ]$j$::jsonb)
$s$);

-- Paychecks: one ending in the range, one after it, one tombstoned.
insert into public.paycheck_records
  (id, user_id, period_start, period_end, paid_tips_cents, gross_pay_cents,
   net_pay_cents, taxes_cents, client_updated_at, deleted_at)
values
  ('dddddddd-0000-4000-8000-0000000000e1', '61000000-0000-4000-8000-000000000003',
   '2026-09-21', '2026-10-04', 1000, 50000, 40000, 8000, now(), null),
  ('dddddddd-0000-4000-8000-0000000000e2', '61000000-0000-4000-8000-000000000003',
   '2026-10-05', '2026-10-18', 2000, 60000, 48000, 9000, now(), null),
  ('dddddddd-0000-4000-8000-0000000000e3', '61000000-0000-4000-8000-000000000003',
   '2026-09-21', '2026-10-04', 3000, 70000, 56000, 10000, now(), now());

-- The fault this guards: the totals were read from tip_entries alone, so a
-- night the current app logged was missing from count and every total.
select pg_temp.expect('theSummaryCountsShiftsTheCurrentAppWrites',
  (select (s -> 'count')::bigint = 2
          and (s -> 'tip_entry_count')::bigint = 0
          and (s -> 'cash_voluntary_tips_cents')::bigint = 3000
          and (s -> 'credit_voluntary_tips_cents')::bigint = 6000
          and (s -> 'gratuity_cents')::bigint = 400
          and (s -> 'tip_out_cents')::bigint = 1500
          and (s -> 'sales_cents')::bigint = 40000
          and (s -> 'hours_worked')::numeric = 9.5
     from (select public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
             '2026-10-01', '2026-10-05') -> 'shifts' as s) q),
  (select (public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
             '2026-10-01', '2026-10-05') -> 'shifts')::text));

-- 2000 + 6000 + 400 gratuity + 3000 share - 1500 tip-out, plus 1000.
select pg_temp.expect('theSummaryNetIncludesTheShareAndGrossAddsTheTipOutBack',
  (select (s -> 'net_tip_earnings_cents')::bigint = 10900
          and (s -> 'gross_tip_earnings_cents')::bigint = 12400
          and (s -> 'tip_share_in_cents')::bigint = 3000
     from (select public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
             '2026-10-01', '2026-10-05') -> 'shifts' as s) q),
  (select (public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
             '2026-10-01', '2026-10-05') -> 'shifts')::text));

select pg_temp.expect('aDeletedShiftIsNotInTheSummary',
  (public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
     '2026-10-05', '2026-10-05') #>> '{shifts,count}')::bigint = 0
  and (public.payday_agent_summary('61000000-0000-4000-8000-000000000003')
     #>> '{shifts,count}')::bigint = 4,
  (public.payday_agent_summary('61000000-0000-4000-8000-000000000003') -> 'shifts')::text);

select pg_temp.expect('theSummaryDateBoundsAreInclusiveOnWorkDate',
  (public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
     '2026-09-30', '2026-09-30') #>> '{shifts,count}')::bigint = 1
  and (public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
     '2026-10-06', '2026-10-06') #>> '{shifts,count}')::bigint = 1
  and (public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
     '2026-09-30', '2026-10-06') #>> '{shifts,count}')::bigint = 4,
  '');

-- One response must not answer "how many, how much" differently from the
-- listing it sits beside: same rows, same deleted rule, same date column.
select pg_temp.expect('theSummaryAgreesWithTheListingOverARange',
  (select (s -> 'count')::bigint = l.n
          and (s -> 'net_tip_earnings_cents')::bigint = l.net
          and (s -> 'tip_out_cents')::bigint = l.tip_out
     from (select public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
             '2026-09-30', '2026-10-05') -> 'shifts' as s) q,
          (select count(*) as n, sum(non_wage_earnings_cents) as net,
                  sum(coalesce(tip_out_cents, 0)) as tip_out
             from public.payday_agent_recent_shifts('61000000-0000-4000-8000-000000000003',
               '2026-09-30', '2026-10-05', 201)) l),
  '');

select pg_temp.expect('theSummaryAgreesWithTheListingOverTheWholeAccount',
  (select (s -> 'count')::bigint = l.n
          and (s -> 'net_tip_earnings_cents')::bigint = l.net
     from (select public.payday_agent_summary('61000000-0000-4000-8000-000000000003')
             -> 'shifts' as s) q,
          (select count(*) as n, sum(non_wage_earnings_cents) as net
             from public.payday_agent_recent_shifts('61000000-0000-4000-8000-000000000003',
               null, null, 201)) l),
  '');

select pg_temp.expect('anotherAccountsShiftIsNeverInTheSummary',
  (public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
     '2026-10-02', '2026-10-02') #>> '{shifts,count}')::bigint = 0
  and (public.payday_agent_summary('61000000-0000-4000-8000-000000000002',
     '2026-10-01', '2026-10-05') #>> '{shifts,cash_voluntary_tips_cents}')::bigint = 7777,
  '');

-- Account D's night was logged on a 1.0 build as two legacy rows and then
-- converted. With one receipt and every detail on one row there is no rule
-- to disagree about, so the totals are the ones the legacy rows gave, and
-- tip_entry_count still counts those rows.
insert into public.tip_entries
  (id, user_id, shift_id, work_date, amount_cents, kind, tip_out_cents,
   sales_cents, hours_worked, receipt_metrics, client_updated_at)
values
  ('dddddddd-0000-4000-8000-0000000000a1', '61000000-0000-4000-8000-000000000004',
   'dddddddd-0000-4000-8000-0000000000d1', '2026-10-01', 3000, 'cash',
   null, null, null, null, '2026-10-01 23:00:00+00'),
  ('dddddddd-0000-4000-8000-0000000000a2', '61000000-0000-4000-8000-000000000004',
   'dddddddd-0000-4000-8000-0000000000d1', '2026-10-01', 7000, 'credit',
   1000, 50000, 6, '{"earningsSchemaVersion": 2, "gratuityFeesCents": 500}',
   '2026-10-01 23:00:00+00');
select private.derive_shifts('61000000-0000-4000-8000-000000000004',
  array['dddddddd-0000-4000-8000-0000000000d1'::uuid]);

select pg_temp.expect('aConvertedLegacyShiftSumsAsItsLegacyRowsDid',
  (public.payday_agent_summary('61000000-0000-4000-8000-000000000004') -> 'shifts')
    - 'tip_share_in_cents'
  = '{"count": 1, "tip_entry_count": 2, "cash_voluntary_tips_cents": 3000,
      "credit_voluntary_tips_cents": 7000, "gratuity_cents": 500,
      "gross_tip_earnings_cents": 10500, "tip_out_cents": 1000,
      "net_tip_earnings_cents": 9500, "sales_cents": 50000,
      "hours_worked": 6}'::jsonb,
  (public.payday_agent_summary('61000000-0000-4000-8000-000000000004') -> 'shifts')::text);

select pg_temp.expect('thePaycheckTotalsCountLivePaychecksByPeriodEnd',
  public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
    '2026-10-01', '2026-10-05') -> 'paychecks'
  = '{"count": 1, "paid_tips_cents": 1000, "gross_pay_cents": 50000,
      "net_pay_cents": 40000, "taxes_cents": 8000}'::jsonb,
  (public.payday_agent_summary('61000000-0000-4000-8000-000000000003',
    '2026-10-01', '2026-10-05') -> 'paychecks')::text);

-- ===========================================================================
-- Grants: these are admin-path functions, reached with the service role.
-- ===========================================================================

select pg_temp.expect('neitherReadFunctionIsReachableByAClient',
  not has_function_privilege('anon',
    'public.payday_agent_recent_shifts(uuid,date,date,integer,date,timestamptz,uuid)', 'execute')
  and not has_function_privilege('authenticated',
    'public.payday_agent_recent_shifts(uuid,date,date,integer,date,timestamptz,uuid)', 'execute')
  and not has_function_privilege('anon',
    'public.payday_agent_shift_by_id(uuid,uuid)', 'execute')
  and not has_function_privilege('authenticated',
    'public.payday_agent_shift_by_id(uuid,uuid)', 'execute'));

select pg_temp.expect('theSummaryIsReachableByTheServiceRoleOnly',
  not has_function_privilege('anon',
    'public.payday_agent_summary(uuid,date,date)', 'execute')
  and not has_function_privilege('authenticated',
    'public.payday_agent_summary(uuid,date,date)', 'execute')
  and has_function_privilege('service_role',
    'public.payday_agent_summary(uuid,date,date)', 'execute'));

select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 26,
  'ran ' || (select count(*) from results)::text || ' of 26');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'agent_api_shifts_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'agent_api_shifts_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id in (
  '61000000-0000-4000-8000-000000000001',
  '61000000-0000-4000-8000-000000000002',
  '61000000-0000-4000-8000-000000000003',
  '61000000-0000-4000-8000-000000000004');
