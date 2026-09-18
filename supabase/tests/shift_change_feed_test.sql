-- PR 2, slice S8: the shift change feed and the fence it exists for.
--
-- Same plain-psql convention as the other suites (see shift_schema_test.sql's
-- header). Run by CI job E and by `bash scripts/db-test-local.sh`.
--
-- The FENCE itself -- that a shift folded by a still-open transaction is
-- delivered with the clamped cursor and lost with the unclamped one -- needs
-- two concurrent sessions and lives in scripts/db-test-race.sh case 10. This
-- suite covers the shape the client depends on, which is what a single psql
-- script can actually prove.

\set ON_ERROR_STOP on
\timing off
\pset pager off

create temporary table results (
  seq serial primary key, name text not null, ok boolean not null, detail text not null default '');

create function pg_temp.expect(p_name text, p_ok boolean, p_detail text default '')
returns void language sql as $$
  insert into results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail);
$$;

create function pg_temp.outcome_of(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return '00000';
exception when others then return sqlstate; end;
$$;

-- Calls as an account and returns the jsonb result. Role `authenticated` has
-- no USAGE on this session's pg_temp schema, so a capture written inside the
-- role switch fails with "permission denied for table" -- which looks exactly
-- like an RLS defect in the code under test and is not one.
create function pg_temp.feed_as(p_uid uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  set local role authenticated;
  execute p_sql into v;
  reset role;
  return v;
end; $$;

delete from auth.users where id in (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222');
insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'payday-s8-a@test.invalid'),
  ('22222222-2222-4222-8222-222222222222', 'payday-s8-b@test.invalid');

-- Three shifts for A, one for B, through the S6 write path.
do $$ begin
  perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111', true);
  set local role authenticated;
  perform public.upsert_shifts($j$[
    {"id":"aaaaaaaa-0000-4000-8000-000000000001","work_date":"2026-09-01","cash_tips_cents":100},
    {"id":"aaaaaaaa-0000-4000-8000-000000000002","work_date":"2026-09-02","cash_tips_cents":200},
    {"id":"aaaaaaaa-0000-4000-8000-000000000003","work_date":"2026-09-03","cash_tips_cents":300}
  ]$j$::jsonb);
  reset role;
end $$;
do $$ begin
  perform set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222', true);
  set local role authenticated;
  perform public.upsert_shifts($j$[
    {"id":"cccccccc-0000-4000-8000-0000000000bb","work_date":"2026-09-01","cash_tips_cents":999}
  ]$j$::jsonb);
  reset role;
end $$;

create temporary table feed as
select pg_temp.feed_as('11111111-1111-4111-8111-111111111111',
  $q$ select public.fetch_shift_changes(null::timestamptz, null::uuid, 1000) $q$) as v;

select pg_temp.expect('theBaselineReturnsEveryOwnShift',
  (select jsonb_array_length(v -> 'rows') from feed) = 3,
  'got ' || (select jsonb_array_length(v -> 'rows') from feed)::text || ' of 3');

-- THE WHOLE POINT. Read in a separate statement this would be a different
-- snapshot, and a transaction committing between the two reads with an
-- earlier updated_at would be skipped by the client's cursor forever.
select pg_temp.expect('thePageCarriesTheSnapshotTimeItWasReadAt',
  (select (v ->> 'server_now') is not null
      and (v ->> 'server_now')::timestamptz <= statement_timestamp() from feed));

select pg_temp.expect('anotherAccountsShiftsAreNeverReturned',
  not exists (
    select 1 from jsonb_array_elements((select v -> 'rows' from feed)) e
     where e ->> 'user_id' <> '11111111-1111-4111-8111-111111111111'));

-- The client's cursor filter is `updated_at > X or (updated_at = X and
-- id > Y)`, which only works if the feed orders by exactly that pair.
select pg_temp.expect('rowsAreOrderedByUpdatedAtThenId',
  (select bool_and(ok) from (
    select (e ->> 'updated_at', e ->> 'id')
             >= lag((e ->> 'updated_at', e ->> 'id')) over (order by ord) is not false as ok
    from jsonb_array_elements((select v -> 'rows' from feed)) with ordinality as x(e, ord)
  ) q));

-- Provenance has to come down WITH the row: the bridge and the rollback query
-- both read it and neither can ask for it later.
select pg_temp.expect('everyRowCarriesItsProvenanceColumns',
  (select bool_and((e ? 'source') and (e ? 'legacy_entry_ids')
                   and (e ? 'native_modified_at') and (e ? 'deleted_reason')
                   and (e ? 'non_wage_earnings_cents') and (e ? 'version')
                   and (e ? 'updated_at'))
   from jsonb_array_elements((select v -> 'rows' from feed)) e));

-- A delta pass that finds nothing must still be able to advance the cursor,
-- or the account re-reads its whole history every pass forever.
create temporary table exhausted as
select pg_temp.feed_as('11111111-1111-4111-8111-111111111111', format(
  $q$ select public.fetch_shift_changes(%L::timestamptz, %L::uuid, 1000) $q$,
  (select max((e ->> 'updated_at')::timestamptz)
     from jsonb_array_elements((select v -> 'rows' from feed)) e),
  'ffffffff-ffff-4fff-8fff-ffffffffffff')) as v;

select pg_temp.expect('anExhaustedPageIsEmptyButStillStamped',
  (select jsonb_array_length(v -> 'rows') = 0
      and (v ->> 'server_now') is not null from exhausted));

select pg_temp.expect('theLimitIsHonoured',
  jsonb_array_length(
    pg_temp.feed_as('11111111-1111-4111-8111-111111111111',
      $q$ select public.fetch_shift_changes(null::timestamptz, null::uuid, 2) $q$) -> 'rows') = 2);

-- A client asking for a million rows is a client bug, not a licence. Capped
-- server-side rather than trusted.
select pg_temp.expect('anAbsurdLimitIsCappedRatherThanRaising',
  pg_temp.outcome_of(
    $q$ select public.fetch_shift_changes(null::timestamptz, null::uuid, 100000000) $q$) = '00000');

select pg_temp.expect('aZeroOrNegativeLimitStillReturnsAPage',
  jsonb_array_length(
    pg_temp.feed_as('11111111-1111-4111-8111-111111111111',
      $q$ select public.fetch_shift_changes(null::timestamptz, null::uuid, 0) $q$) -> 'rows') = 1);

-- Security invoker plus the shifts_select_own policy, rather than a definer
-- re-implementing that decision. With no subject there is no own row.
select pg_temp.expect('withNoAuthenticatedSubjectNothingIsReturned',
  jsonb_array_length(
    (select public.fetch_shift_changes(null::timestamptz, null::uuid, 1000)) -> 'rows') = 0);

select pg_temp.expect('theFeedIsAuthenticatedOnly',
  has_function_privilege('authenticated',
    'public.fetch_shift_changes(timestamptz,uuid,integer)', 'execute')
  and not has_function_privilege('anon',
    'public.fetch_shift_changes(timestamptz,uuid,integer)', 'execute'));

-- Invoker, not definer. A definer would have to re-implement the RLS decision
-- correctly, and it reads nothing in schema private so there is no 42501 to
-- wrap around in the first place.
select pg_temp.expect('theFeedIsSecurityInvoker',
  (select not prosecdef from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fetch_shift_changes'));

-- A tombstoned shift must still come down, or a deletion made on one device
-- never reaches another.
do $$ begin
  perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111', true);
  set local role authenticated;
  perform public.soft_delete_shifts($j$[
    {"id":"aaaaaaaa-0000-4000-8000-000000000003","deleted_at":"2026-09-04T00:00:00Z"}
  ]$j$::jsonb);
  reset role;
end $$;
select pg_temp.expect('aTombstonedShiftIsStillDelivered',
  exists (
    select 1 from jsonb_array_elements(
      pg_temp.feed_as('11111111-1111-4111-8111-111111111111',
        $q$ select public.fetch_shift_changes(null::timestamptz, null::uuid, 1000) $q$) -> 'rows') e
     where e ->> 'id' = 'aaaaaaaa-0000-4000-8000-000000000003'
       and (e ->> 'deleted_at') is not null));

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
    raise exception 'shift_change_feed_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'shift_change_feed_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id in (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222');
