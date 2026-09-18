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

delete from auth.users where id in (
  '61000000-0000-4000-8000-000000000001',
  '61000000-0000-4000-8000-000000000002');
insert into auth.users (id, email) values
  ('61000000-0000-4000-8000-000000000001', 'payday-s11-a@test.invalid'),
  ('61000000-0000-4000-8000-000000000002', 'payday-s11-b@test.invalid');

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

select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 16,
  'ran ' || (select count(*) from results)::text || ' of 16');

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
  '61000000-0000-4000-8000-000000000002');
