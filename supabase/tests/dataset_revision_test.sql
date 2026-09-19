-- PR 6, group 2.14, part 1: the server watermark and the snapshot acceptance
-- rule.
--
-- Same plain-psql convention as the other suites. Run by CI job E and by
-- `bash scripts/db-test-local.sh`.
--
-- The assertion this suite exists for is `aShiftBumpsTheWatermarkWithNoSettingsRow`.
-- PAYDAYCORE_PLAN.md:188 puts `dataset_revision` on `public.user_settings`,
-- and that row is created only by a settings sync while `public.shifts.user_id`
-- references `auth.users` -- so under the planned design the bump is an
-- `update ... where user_id = $1` against a row that need not exist, it
-- affects zero rows, and the watermark stays 0 while the money changes. A
-- snapshot stamped 0 then reads as current forever. This suite fails on that
-- design and passes on the dedicated table.

\set ON_ERROR_STOP on
\timing off
\pset pager off

create temporary table results (
  seq serial primary key, name text not null, ok boolean not null, detail text not null default '');

create function pg_temp.expect(p_name text, p_ok boolean, p_detail text default '')
returns void language sql as $$
  insert into results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail);
$$;

-- Acts as the given account for one statement, the way PostgREST does.
create function pg_temp.as_user(p_uid uuid, p_sql text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  set local role authenticated;
  execute p_sql;
  reset role;
end $$;

-- Calls the RPC as the account and returns its verdict. A plpgsql variable,
-- not a temp table: role `authenticated` has no USAGE on this session's
-- pg_temp, so capturing into one inside the role switch fails in a way that
-- looks exactly like a grant defect in the code under test.
create function pg_temp.upsert_as(
  p_uid uuid, p_rev bigint, p_engine integer, p_digest text,
  p_payload jsonb default '{"total": 1}'::jsonb, p_as_of date default date '2026-09-18')
returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  set local role authenticated;
  v := public.upsert_earnings_snapshot(p_rev, p_engine, p_as_of, p_digest, p_payload);
  reset role;
  return v;
end $$;

create function pg_temp.rev(p_uid uuid) returns bigint language sql as $$
  select coalesce((select d.revision from public.dataset_revisions d where d.user_id = p_uid), 0);
$$;

delete from auth.users where id in (
  '71000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000002');
insert into auth.users (id, email) values
  ('71000000-0000-4000-8000-000000000001', 'payday-s14-a@test.invalid'),
  ('71000000-0000-4000-8000-000000000002', 'payday-s14-b@test.invalid');

-- ===========================================================================
-- 1. THE WATERMARK MOVES, INCLUDING FOR A USER WITH NO SETTINGS ROW.
-- ===========================================================================

-- Deliberately NO user_settings row for A. This is the state the planned
-- design could not represent a bump in.
select pg_temp.expect('aStartsWithNoSettingsRowAndNoWatermark',
  not exists (select 1 from public.user_settings
              where user_id = '71000000-0000-4000-8000-000000000001')
  and pg_temp.rev('71000000-0000-4000-8000-000000000001') = 0);

insert into public.shifts (id, user_id, work_date, cash_tips_cents, client_updated_at)
values ('aaaa0001-0000-4000-8000-000000000001',
        '71000000-0000-4000-8000-000000000001', date '2026-09-01', 1000,
        timestamptz '2026-09-01T23:00:00Z');

-- THE ASSERTION. Zero under the planned design, 1 here.
select pg_temp.expect('aShiftBumpsTheWatermarkWithNoSettingsRow',
  pg_temp.rev('71000000-0000-4000-8000-000000000001') = 1,
  'rev=' || pg_temp.rev('71000000-0000-4000-8000-000000000001'));

update public.shifts set cash_tips_cents = 1500
  where id = 'aaaa0001-0000-4000-8000-000000000001';
select pg_temp.expect('anUpdateBumpsIt',
  pg_temp.rev('71000000-0000-4000-8000-000000000001') = 2,
  'rev=' || pg_temp.rev('71000000-0000-4000-8000-000000000001'));

-- One statement, three rows, ONE bump. The trigger is FOR EACH ROW (deferred
-- triggers must be), so a transaction-local guard is what collapses three
-- firings into one bump. Without it this reads 5, not 3.
insert into public.shifts (id, user_id, work_date, cash_tips_cents, client_updated_at)
values ('aaaa0001-0000-4000-8000-000000000002','71000000-0000-4000-8000-000000000001',date '2026-09-02',100,timestamptz '2026-09-02T23:00:00Z'),
       ('aaaa0001-0000-4000-8000-000000000003','71000000-0000-4000-8000-000000000001',date '2026-09-03',200,timestamptz '2026-09-03T23:00:00Z'),
       ('aaaa0001-0000-4000-8000-000000000004','71000000-0000-4000-8000-000000000001',date '2026-09-04',300,timestamptz '2026-09-04T23:00:00Z');
select pg_temp.expect('aBulkInsertBumpsOncePerStatementNotOncePerRow',
  pg_temp.rev('71000000-0000-4000-8000-000000000001') = 3,
  'rev=' || pg_temp.rev('71000000-0000-4000-8000-000000000001'));

delete from public.shifts where id = 'aaaa0001-0000-4000-8000-000000000004';
select pg_temp.expect('aDeleteBumpsIt',
  pg_temp.rev('71000000-0000-4000-8000-000000000001') = 4,
  'rev=' || pg_temp.rev('71000000-0000-4000-8000-000000000001'));

insert into public.paycheck_records (id, user_id, period_start, period_end, paid_tips_cents, client_updated_at)
values ('bbbb0001-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001',
        date '2026-09-01', date '2026-09-14', 5000, timestamptz '2026-09-15T00:00:00Z');
select pg_temp.expect('aPaycheckBumpsIt',
  pg_temp.rev('71000000-0000-4000-8000-000000000001') = 5,
  'rev=' || pg_temp.rev('71000000-0000-4000-8000-000000000001'));

insert into public.user_settings (user_id, client_updated_at)
values ('71000000-0000-4000-8000-000000000001', timestamptz '2026-09-15T00:00:00Z');
select pg_temp.expect('settingsBumpItToo',
  pg_temp.rev('71000000-0000-4000-8000-000000000001') = 6,
  'rev=' || pg_temp.rev('71000000-0000-4000-8000-000000000001'));

-- B has touched nothing. A watermark that moved for everyone would make every
-- device's snapshot stale on every other device's write.
select pg_temp.expect('anotherAccountsWatermarkDidNotMove',
  pg_temp.rev('71000000-0000-4000-8000-000000000002') = 0);

select pg_temp.expect('theWatermarkCoversEveryMoneyBearingTable',
  (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
    where c.relname in ('shifts','paycheck_records','user_settings')
      and t.tgname like '%_bump_revision%' and not t.tgisinternal
      and t.tgdeferrable and t.tginitdeferred) = 3,
  'deferrable triggers=' || (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
    where c.relname in ('shifts','paycheck_records','user_settings')
      and t.tgname like '%_bump_revision%' and not t.tgisinternal
      and t.tgdeferrable and t.tginitdeferred));

-- ===========================================================================
-- 2. THE ACCEPTANCE RULE.
-- ===========================================================================

select pg_temp.expect('aStaleRevisionIsRejected',
  pg_temp.upsert_as('71000000-0000-4000-8000-000000000001', 3, 1, 'digest-stale') = 'stale_input');

-- A revision the server never issued is not "ahead", it is invented.
select pg_temp.expect('aRevisionAheadOfTheServerIsRejected',
  pg_temp.upsert_as('71000000-0000-4000-8000-000000000001', 99, 1, 'digest-future') = 'stale_input');

select pg_temp.expect('theCurrentRevisionIsAccepted',
  pg_temp.upsert_as('71000000-0000-4000-8000-000000000001', 6, 1, 'digest-one') = 'accepted');

select pg_temp.expect('theSnapshotLanded',
  (select manifest_digest from public.earnings_snapshots
    where user_id = '71000000-0000-4000-8000-000000000001') = 'digest-one');

-- If storing the snapshot bumped the watermark, every upload would invalidate
-- itself the instant it landed and no snapshot could ever be current.
select pg_temp.expect('storingASnapshotDoesNotBumpTheWatermark',
  pg_temp.rev('71000000-0000-4000-8000-000000000001') = 6,
  'rev=' || pg_temp.rev('71000000-0000-4000-8000-000000000001'));

-- Same revision, same engine: a recompute of the same inputs may replace.
select pg_temp.expect('sameRevisionSameEngineMayReplace',
  pg_temp.upsert_as('71000000-0000-4000-8000-000000000001', 6, 1, 'digest-two') = 'accepted');

-- Same revision, OLDER engine: an older build must not overwrite a newer
-- engine's answer for the same data.
select pg_temp.expect('sameRevisionOlderEngineIsRejected',
  pg_temp.upsert_as('71000000-0000-4000-8000-000000000001', 6, 0, 'digest-old') = 'stale_input');

select pg_temp.expect('theRejectedUploadsDidNotOverwrite',
  (select manifest_digest from public.earnings_snapshots
    where user_id = '71000000-0000-4000-8000-000000000001') = 'digest-two');

-- Move the dataset on, then a snapshot from the NEW revision supersedes.
insert into public.shifts (id, user_id, work_date, cash_tips_cents, client_updated_at)
values ('aaaa0001-0000-4000-8000-000000000005','71000000-0000-4000-8000-000000000001',
        date '2026-09-05', 400, timestamptz '2026-09-05T23:00:00Z');
select pg_temp.expect('aNewerRevisionSupersedes',
  pg_temp.upsert_as('71000000-0000-4000-8000-000000000001', 7, 1, 'digest-three') = 'accepted');

-- A malformed payload is refused as an ORDINARY outcome. `jsonb_typeof` is
-- checked before anything casts, because a cast inside a CHECK aborts the
-- statement uncatchably on Postgres 17.
select pg_temp.expect('aNonObjectPayloadIsRefusedNotAborted',
  pg_temp.upsert_as('71000000-0000-4000-8000-000000000001', 7, 1, 'digest-bad',
                    '[1,2,3]'::jsonb) = 'stale_input');
select pg_temp.expect('anEmptyDigestIsRefused',
  pg_temp.upsert_as('71000000-0000-4000-8000-000000000001', 7, 1, '') = 'stale_input');

-- ===========================================================================
-- 3. REACH AND GRANTS.
-- ===========================================================================

select pg_temp.expect('theRevisionReaderAnswersForTheCaller',
  (select public.payday_dataset_revision()
   from (select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000001',true)) _) = 7);

-- RLS is `using (auth.uid() = user_id)`, which returns ZERO ROWS rather than
-- an error for an unauthorised read -- so the assertion must be about the
-- count, never about an exception.
--
-- The count comes back through a plpgsql RETURN rather than an insert into
-- pg_temp, because role `authenticated` has no USAGE on this session's
-- pg_temp schema: capturing inside the role switch fails with "permission
-- denied for table", which reads exactly like an RLS defect in the code
-- under test and is not one. Written the wrong way first and caught by the
-- local runner; the neighbouring suite documents the same trap.
create function pg_temp.count_as(p_uid uuid, p_relation text)
returns integer language plpgsql as $$
declare n integer;
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  set local role authenticated;
  execute format('select count(*) from %s', p_relation) into n;
  reset role;
  return n;
end $$;

select pg_temp.expect('anotherAccountCannotSeeMySnapshot',
  pg_temp.count_as('71000000-0000-4000-8000-000000000002', 'public.earnings_snapshots') = 0,
  'B saw ' || pg_temp.count_as('71000000-0000-4000-8000-000000000002', 'public.earnings_snapshots'));

select pg_temp.expect('anotherAccountCannotSeeMyWatermark',
  pg_temp.count_as('71000000-0000-4000-8000-000000000002', 'public.dataset_revisions') = 0,
  'B saw ' || pg_temp.count_as('71000000-0000-4000-8000-000000000002', 'public.dataset_revisions'));

select pg_temp.expect('anonHasNoExecuteOnTheSnapshotRpc',
  not has_function_privilege('anon',
    'public.upsert_earnings_snapshot(bigint, integer, date, text, jsonb)', 'execute'));
select pg_temp.expect('authenticatedHasExecuteOnTheSnapshotRpc',
  has_function_privilege('authenticated',
    'public.upsert_earnings_snapshot(bigint, integer, date, text, jsonb)', 'execute'));
select pg_temp.expect('theBumpIsNotCallableByAClient',
  not has_function_privilege('authenticated', 'private.bump_revision_row()', 'execute')
  and not has_function_privilege('anon', 'private.bump_revision_row()', 'execute'));
select pg_temp.expect('clientsCannotWriteTheWatermarkOrSnapshotDirectly',
  not has_table_privilege('authenticated', 'public.dataset_revisions', 'insert')
  and not has_table_privilege('authenticated', 'public.dataset_revisions', 'update')
  and not has_table_privilege('authenticated', 'public.earnings_snapshots', 'insert')
  and not has_table_privilege('authenticated', 'public.earnings_snapshots', 'update'));

select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 27, 'ran ' || (select count(*) from results) || ' of 27');

select seq, case when ok then 'PASS' else 'FAIL' end as status, name, detail from results order by seq;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from results;

do $$
declare n integer;
begin
  select count(*) into n from results where not ok;
  if n > 0 then
    raise exception 'dataset_revision_test: % assertion(s) failed', n;
  end if;
  raise notice 'dataset_revision_test: all % assertions passed', (select count(*) from results);
end $$;

delete from auth.users where id in (
  '71000000-0000-4000-8000-000000000001',
  '71000000-0000-4000-8000-000000000002');
