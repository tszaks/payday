-- PR 3: schema tests for user_settings.compensation_policies and the two
-- settings sync RPCs.
--
-- Same conventions as shift_schema_test.sql: a plain psql script, every
-- assertion in a temporary results table, a raise at the end so psql exits
-- non-zero under -v ON_ERROR_STOP=1. Run by CI job E after
-- `supabase db reset --local`, and locally by `bash scripts/db-test-local.sh`.
--
-- The assertion this file exists for is #4. Payday 1.0 is shipped, in review,
-- and calls `upsert_user_settings` with a payload that has no
-- `compensation_policies` key at all. If that write cleared the column, an old
-- phone in the same account would erase a newer phone's rate history — the
-- thing that decides what every wage in the app is worth. The column is
-- nullable and the update branch coalesces null back to the stored value
-- precisely so that cannot happen, and this measures it rather than asserting
-- it in a comment.

\set ON_ERROR_STOP on
\timing off
\pset pager off

create temporary table results (
  seq serial primary key, name text not null, ok boolean not null, detail text not null default '');

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

-- Fixture account ------------------------------------------------------------

delete from auth.users where id = '44444444-4444-4444-8444-444444444444';
insert into auth.users (id, email)
values ('44444444-4444-4444-8444-444444444444', 'payday-pr3-a@test.invalid');

-- The payload a PR 3 build sends: one assumed rate policy and one frozen
-- calendar policy, exactly the shape `CompensationPolicies` encodes.
create function pg_temp.policies_v1() returns jsonb language sql immutable as $$
  select '{
    "version": 1,
    "rates": [{
      "id": "aaaaaaaa-0000-4000-8000-000000000001",
      "effectiveFrom": "2026-03-14",
      "hourlyRateCents": 283,
      "provenance": "assumedFromLegacySetting"
    }],
    "calendars": [{
      "id": "bbbbbbbb-0000-4000-8000-000000000001",
      "effectiveFrom": "0001-01-01",
      "workweekStartWeekday": 2,
      "overtimeThresholdMinutes": 2400,
      "overtimeMultiplierHundredths": 150,
      "payrollTimeZone": "America/New_York"
    }]
  }'::jsonb;
$$;

-- 1. The column and its CHECK ------------------------------------------------

select pg_temp.expect(
  'theColumnIsNullableJsonb',
  (select is_nullable = 'YES' and data_type = 'jsonb'
   from information_schema.columns
   where table_schema = 'public' and table_name = 'user_settings'
     and column_name = 'compensation_policies'),
  (select coalesce(is_nullable, 'MISSING') || '/' || coalesce(data_type, 'MISSING')
   from information_schema.columns
   where table_schema = 'public' and table_name = 'user_settings'
     and column_name = 'compensation_policies'));

-- 2. import_user_settings carries the payload --------------------------------

do $$
begin
  perform set_config('request.jwt.claim.sub', '44444444-4444-4444-8444-444444444444', true);
  set local role authenticated;
  perform public.import_user_settings(jsonb_build_object(
    'first_name', 'Alex',
    'base_hourly_wage_cents', 283,
    'pay_frequency', 'biweekly',
    'anchor_period_end', '2026-10-04',
    'pay_delay_days', 5,
    'first_weekday', 2,
    'compensation_policies', pg_temp.policies_v1(),
    'client_updated_at', '2026-09-17T12:00:00Z'));
end;
$$;

select pg_temp.expect(
  'importCarriesTheWholePolicyPayload',
  (select compensation_policies = pg_temp.policies_v1()
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'),
  (select coalesce(compensation_policies::text, 'NULL')
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'));

select pg_temp.expect(
  'theStoredRateSurvivesTheRoundTrip',
  (select compensation_policies -> 'rates' -> 0 ->> 'hourlyRateCents' = '283'
     and compensation_policies -> 'rates' -> 0 ->> 'provenance' = 'assumedFromLegacySetting'
     and compensation_policies -> 'calendars' -> 0 ->> 'payrollTimeZone' = 'America/New_York'
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'),
  (select coalesce(compensation_policies -> 'rates' -> 0 ->> 'hourlyRateCents', 'NULL')
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'));

-- 3. upsert_user_settings updates the payload --------------------------------

do $$
begin
  perform set_config('request.jwt.claim.sub', '44444444-4444-4444-8444-444444444444', true);
  set local role authenticated;
  perform public.upsert_user_settings(jsonb_build_object(
    'first_name', 'Alex',
    'base_hourly_wage_cents', 500,
    'pay_frequency', 'biweekly',
    'anchor_period_end', '2026-10-04',
    'compensation_policies', jsonb_set(
      pg_temp.policies_v1(), '{rates,0,hourlyRateCents}', '500'::jsonb),
    'client_updated_at', '2026-09-17T13:00:00Z'));
end;
$$;

select pg_temp.expect(
  'anUpsertFromAPolicyAwareBuildUpdatesTheRate',
  (select compensation_policies -> 'rates' -> 0 ->> 'hourlyRateCents' = '500'
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'),
  (select coalesce(compensation_policies -> 'rates' -> 0 ->> 'hourlyRateCents', 'NULL')
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'));

-- 4. The one that matters: a Payday 1.0 payload cannot erase the history -----

do $$
begin
  perform set_config('request.jwt.claim.sub', '44444444-4444-4444-8444-444444444444', true);
  set local role authenticated;
  -- Verbatim the key set the shipped 1.0 build sends: no
  -- `compensation_policies` at all.
  perform public.upsert_user_settings(jsonb_build_object(
    'first_name', 'Alex',
    'base_hourly_wage_cents', 500,
    'pay_frequency', 'biweekly',
    'anchor_period_end', '2026-10-04',
    'pay_delay_days', 5,
    'first_weekday', 2,
    'smart_nudge_enabled', true,
    'payday_reminder_enabled', true,
    'move_ledger', '{}'::jsonb,
    'client_updated_at', '2026-09-17T14:00:00Z'));
end;
$$;

select pg_temp.expect(
  'anOldBuildsUpsertPreservesTheStoredPolicies',
  (select compensation_policies -> 'rates' -> 0 ->> 'hourlyRateCents' = '500'
     and jsonb_array_length(compensation_policies -> 'calendars') = 1
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'),
  (select coalesce(compensation_policies::text, 'NULL')
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'));

select pg_temp.expect(
  'anOldBuildsUpsertStillWroteItsOwnFields',
  (select first_weekday = 2 and client_updated_at = '2026-09-17T14:00:00Z'::timestamptz
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'),
  (select coalesce(first_weekday::text, 'NULL') || '/' || client_updated_at::text
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'));

-- 5. An explicitly empty payload IS stored -----------------------------------
-- Null means "this client does not know about policies"; `{}` means "this
-- client has none". The device tells those two apart too (PaydaySyncService
-- .apply leaves the local copy alone for both, because a freshly migrated
-- device that has not uploaded yet is indistinguishable from a cleared one).

do $$
begin
  perform set_config('request.jwt.claim.sub', '44444444-4444-4444-8444-444444444444', true);
  set local role authenticated;
  perform public.upsert_user_settings(jsonb_build_object(
    'first_name', 'Alex',
    'pay_frequency', 'biweekly',
    'anchor_period_end', '2026-10-04',
    'compensation_policies', '{"version": 1, "rates": [], "calendars": []}'::jsonb,
    'client_updated_at', '2026-09-17T15:00:00Z'));
end;
$$;

select pg_temp.expect(
  'anExplicitlyEmptyPayloadIsStoredRatherThanCoalescedAway',
  (select jsonb_array_length(compensation_policies -> 'rates') = 0
     and jsonb_array_length(compensation_policies -> 'calendars') = 0
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'),
  (select coalesce(compensation_policies::text, 'NULL')
   from public.user_settings where user_id = '44444444-4444-4444-8444-444444444444'));

-- 6. The CHECK rejects a non-object, and does not abort uncatchably ----------
-- The PR 2 lesson, restated: the constraint guards `jsonb_typeof` and casts
-- nothing, so a junk payload is a catchable constraint violation rather than
-- a statement the transaction cannot recover from.

select pg_temp.expect(
  'aJsonArrayIsRejectedByTheCheck',
  pg_temp.outcome_of($$
    update public.user_settings
    set compensation_policies = '[1,2,3]'::jsonb
    where user_id = '44444444-4444-4444-8444-444444444444'$$)
    = '23514/user_settings_compensation_policies_object',
  pg_temp.outcome_of($$
    update public.user_settings
    set compensation_policies = '[1,2,3]'::jsonb
    where user_id = '44444444-4444-4444-8444-444444444444'$$));

select pg_temp.expect(
  'aJsonStringIsRejectedByTheCheck',
  pg_temp.outcome_of($$
    update public.user_settings
    set compensation_policies = '"nonsense"'::jsonb
    where user_id = '44444444-4444-4444-8444-444444444444'$$)
    = '23514/user_settings_compensation_policies_object',
  pg_temp.outcome_of($$
    update public.user_settings
    set compensation_policies = '"nonsense"'::jsonb
    where user_id = '44444444-4444-4444-8444-444444444444'$$));

select pg_temp.expect(
  'anExplicitNullIsAllowed',
  pg_temp.outcome_of($$
    update public.user_settings
    set compensation_policies = null
    where user_id = '44444444-4444-4444-8444-444444444444'$$) = '00000',
  pg_temp.outcome_of($$
    update public.user_settings
    set compensation_policies = null
    where user_id = '44444444-4444-4444-8444-444444444444'$$));

-- 7. Privileges are unchanged ------------------------------------------------

select pg_temp.expect(
  'bothRpcsRemainAuthenticatedOnly',
  (select bool_and(
    has_function_privilege('authenticated', p.oid, 'execute')
      and not has_function_privilege('anon', p.oid, 'execute'))
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('import_user_settings', 'upsert_user_settings')),
  (select string_agg(p.proname || '=' ||
     has_function_privilege('authenticated', p.oid, 'execute')::text || '/' ||
     has_function_privilege('anon', p.oid, 'execute')::text, ' ')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('import_user_settings', 'upsert_user_settings')));

-- Report ---------------------------------------------------------------------

select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 11,
  'ran ' || (select count(*) from results)::text || ' of 11');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed
from results;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'compensation_policies_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'compensation_policies_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id = '44444444-4444-4444-8444-444444444444';
