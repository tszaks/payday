-- PR 2, slice S6: tests for the shift write RPCs.
--
-- Same plain-psql convention as the other four suites (see the header of
-- shift_schema_test.sql): assertions land in a temporary `results` table and
-- the last statement raises, so psql exits non-zero under ON_ERROR_STOP=1.
--
-- Run by CI job E and by `bash scripts/db-test-local.sh`. The concurrency arm
-- of S6 -- proving the BLOCKING lock actually serialises a device write
-- against the one-shot -- needs several real psql processes and lives in
-- scripts/db-test-race.sh, not here.
--
-- What this suite is mostly about: the writer must be TOTAL over arbitrary
-- JSON. Three separate defects in this slice's first draft each aborted the
-- WHOLE batch on one bad field (21000 on a repeated id, 23514 on an
-- out-of-domain period, 22003 on an oversized cents value). That is not a
-- cosmetic difference. A device's push is a fixed set of rows, so it retries
-- the identical payload, hits the identical abort, and the account stops
-- syncing permanently and with no error anyone sees. Nearly every assertion
-- below is a row that USED to take the batch down with it.

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

-- Acts as the given account for one statement, the way PostgREST does.
create function pg_temp.as_user(p_uid uuid, p_sql text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  set local role authenticated;
  execute p_sql;
  reset role;
end;
$$;

-- Calls an RPC as the given account and hands the outcome rows BACK as jsonb,
-- so the caller records them under its own role. Role `authenticated` has no
-- USAGE on this session's pg_temp schema, so a capture written as
-- `insert into <temp> select * from public.upsert_shifts(...)` inside the role
-- switch fails with "permission denied for table" -- which looks exactly like
-- an RLS or grant defect in the code under test, and is not one.
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

-- outcome_of, but as an account. The handler resets the role explicitly: the
-- subtransaction the EXCEPTION block opens starts AFTER the role switch, so an
-- abort does not roll that switch back on its own.
create function pg_temp.outcome_as(p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare v_constraint text;
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  set local role authenticated;
  execute p_sql;
  reset role;
  return '00000';
exception when others then
  reset role;
  get stacked diagnostics v_constraint = constraint_name;
  return sqlstate || coalesce('/' || nullif(v_constraint, ''), '');
end;
$$;

-- Fixture accounts -----------------------------------------------------------

delete from auth.users where id in (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222');
insert into auth.users (id, email) values
  ('11111111-1111-4111-8111-111111111111', 'payday-s6-a@test.invalid'),
  ('22222222-2222-4222-8222-222222222222', 'payday-s6-b@test.invalid');

-- ===========================================================================
-- 1. The hostile batch. One payload carrying every shape that used to abort,
--    interleaved with good rows, submitted once.
-- ===========================================================================

create temporary table hostile (shift_id uuid, status text, stored_client_updated_at timestamptz);

insert into hostile
select (r ->> 'shift_id')::uuid, r ->> 'status',
       (r ->> 'stored_client_updated_at')::timestamptz
from jsonb_array_elements(pg_temp.rpc_as('11111111-1111-4111-8111-111111111111', $s$
  select * from public.upsert_shifts($j$[
    {"id":"aaaaaaaa-0000-4000-8000-000000000001","work_date":"2026-09-01","cash_tips_cents":1000},
    {"id":"aaaaaaaa-0000-4000-8000-000000000001","work_date":"2026-09-01","cash_tips_cents":2000},
    {"id":"aaaaaaaa-0000-4000-8000-000000000002","work_date":"2026-09-02","shift_period":"brunch"},
    {"id":"aaaaaaaa-0000-4000-8000-000000000003","work_date":"2026-09-03","cash_tips_cents":99999999999},
    {"id":"aaaaaaaa-0000-4000-8000-000000000004","work_date":"2026-09-04","credit_tips_cents":"abc"},
    {"id":"aaaaaaaa-0000-4000-8000-000000000005","work_date":"not-a-date"},
    {"id":"not-a-uuid","work_date":"2026-09-06"},
    {"id":"aaaaaaaa-0000-4000-8000-000000000007","work_date":"2026-09-07","hours_worked":-3,
     "receipt_metrics":{"earningsSchemaVersion":1,"gratuityFeesCents":500}},
    {"id":"aaaaaaaa-0000-4000-8000-000000000008","work_date":"2026-09-08",
     "receipt_metrics":{"earningsSchemaVersion":2,"gratuityFeesCents":true}},
    "i am not an object",
    {"id":"aaaaaaaa-0000-4000-8000-000000000009","work_date":"2026-09-09","shift_period":"dinner",
     "client_updated_at":"2099-01-01T00:00:00Z","tip_out_cents":-40,"note":"kept"}
  ]$j$::jsonb)
$s$)) as r;

-- The batch survived at all. This single assertion is the slice's headline:
-- before the rewrite this payload stored NOTHING.
select pg_temp.expect('hostileBatchStoresItsGoodRows',
  (select count(*) from hostile where status = 'stored') = 6,
  'stored ' || (select count(*) from hostile where status = 'stored')::text || ' of 6');

-- Totality: 11 elements, two of which share an id, so 10 outcomes.
select pg_temp.expect('everyElementGetsExactlyOneOutcome',
  (select count(*) from hostile) = 10,
  'got ' || (select count(*) from hostile)::text || ' of 10');

select pg_temp.expect('anIdAppearsInTheOutcomeAtMostOnce',
  not exists (select 1 from hostile where shift_id is not null
              group by shift_id having count(*) > 1));

select pg_temp.expect('statusIsAlwaysFromTheKnownSet',
  not exists (select 1 from hostile where status not in ('stored','refused','invalid')));

-- The repeated id collapses to ONE row and the LAST intent wins. Both rows
-- clamp to the same statement_timestamp, so array order is the tie-break.
select pg_temp.expect('repeatedIdCollapsesAndLastWins',
  (select cash_tips_cents from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 2000,
  'cash=' || coalesce((select cash_tips_cents from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000001')::text, 'missing'));

-- An out-of-domain period loses the LABEL, not the night's money.
select pg_temp.expect('outOfDomainPeriodBecomesNullAndTheShiftSaves',
  (select shift_period is null from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000002'));

-- The asymmetry: floor clamped, ceiling refused.
select pg_temp.expect('centsAboveInt4RefusesTheRowRatherThanFabricating',
  (select status from hostile where shift_id = 'aaaaaaaa-0000-4000-8000-000000000003') = 'invalid'
  and not exists (select 1 from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000003'),
  'status=' || coalesce((select status from hostile
    where shift_id = 'aaaaaaaa-0000-4000-8000-000000000003'), 'none'));

select pg_temp.expect('negativeCentsClampToTheFloorAndTheShiftSaves',
  (select tip_out_cents = 0 and note = 'kept' from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000009'));

select pg_temp.expect('negativeHoursClampToTheFloor',
  (select hours_worked = 0 from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000007'));

-- A field that is not a number at all has no number to distort, so it takes
-- the column default instead of invalidating the row.
select pg_temp.expect('nonNumericCentsTakesTheDefault',
  (select credit_tips_cents = 0 from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000004'));

select pg_temp.expect('unreadableWorkDateInvalidatesOnlyItsOwnRow',
  (select status from hostile where shift_id = 'aaaaaaaa-0000-4000-8000-000000000005') = 'invalid');

select pg_temp.expect('unreadableIdIsReportedWithANullShiftId',
  (select count(*) from hostile where shift_id is null and status = 'invalid') = 2,
  'got ' || (select count(*) from hostile where shift_id is null and status = 'invalid')::text || ' of 2');

-- Receipt payloads: v1 or junk is DROPPED, never allowed to fail the write
-- against shifts_receipt_is_v2.
select pg_temp.expect('v1ReceiptIsDroppedNotRejected',
  (select receipt_metrics is null and gratuity_fees_cents = 0 from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000007'));

-- A v2 payload whose gratuity is the wrong TYPE is kept (it satisfies the
-- CHECK) and reads as zero gratuity, because receipt_gratuity_cents guards
-- jsonb_typeof before the cast. A numeric cast on `true` would abort the
-- statement in a way `when others` cannot catch.
select pg_temp.expect('v2ReceiptWithJunkGratuityIsKeptAndReadsZero',
  (select receipt_metrics is not null and gratuity_fees_cents = 0 from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000008'));

-- ===========================================================================
-- 2. Stamping, clamping and provenance.
-- ===========================================================================

select pg_temp.expect('aDeviceWriteIsStampedSourceDevice',
  (select bool_and(source = 'device') from public.shifts
    where user_id = '11111111-1111-4111-8111-111111111111'));

-- native_modified_at is what private.shift_is_open_to_fold reads. Stamping it
-- is what stops a conversion repricing a shift the user authored or edited.
select pg_temp.expect('aDeviceWriteClosesTheShiftToTheFold',
  (select bool_and(not private.shift_is_open_to_fold(public.shifts.*)) from public.shifts
    where user_id = '11111111-1111-4111-8111-111111111111'));

-- Rule 3: no clock gate, so a future-dated write is stored, but CLAMPED.
select pg_temp.expect('aFutureClientTimestampIsClampedNotRejected',
  (select client_updated_at <= statement_timestamp() from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000009'));

select pg_temp.expect('theOutcomeReportsTheTimestampActuallyStored',
  (select h.stored_client_updated_at = s.client_updated_at
     from hostile h join public.shifts s on s.id = h.shift_id
    where h.shift_id = 'aaaaaaaa-0000-4000-8000-000000000009'));

-- A stale-clocked device must still be able to correct a row it parked ahead
-- of the present. This is the case the tip_entries clock gate gets wrong.
select pg_temp.as_user('11111111-1111-4111-8111-111111111111', $s$
  select public.upsert_shifts($j$[
    {"id":"aaaaaaaa-0000-4000-8000-000000000009","work_date":"2026-09-09",
     "cash_tips_cents":555,"client_updated_at":"2020-01-01T00:00:00Z"}
  ]$j$::jsonb)
$s$);
select pg_temp.expect('anOlderTimestampStillEditsTheRow',
  (select cash_tips_cents from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000009') = 555,
  'cash=' || coalesce((select cash_tips_cents from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000009')::text, 'missing'));

-- ===========================================================================
-- 3. Authorisation. Definer functions reaching schema `private` are the 42501
--    trap; the subject must be captured first and never be another account's.
-- ===========================================================================

select pg_temp.expect('anAuthenticatedUpsertNeverRaises42501',
  (select status from hostile where shift_id = 'aaaaaaaa-0000-4000-8000-000000000001') = 'stored');

select pg_temp.expect('upsertWithNoSubjectRaises42501',
  pg_temp.outcome_of($q$ select * from public.upsert_shifts('[]'::jsonb) $q$) = '42501');

select pg_temp.expect('softDeleteWithNoSubjectRaises42501',
  pg_temp.outcome_of($q$ select * from public.soft_delete_shifts('[]'::jsonb) $q$) = '42501');

select pg_temp.expect('restoreWithNoSubjectRaises42501',
  pg_temp.outcome_of($q$ select * from public.restore_shifts('{}'::uuid[]) $q$) = '42501');

-- Account B writing B's own id, then A trying to write the same id, must not
-- let A read or move B's row. The composite primary key (user_id, id) makes
-- them separate rows; the point is that A never touches B's.
select pg_temp.as_user('22222222-2222-4222-8222-222222222222', $s$
  select public.upsert_shifts($j$[
    {"id":"cccccccc-0000-4000-8000-00000000000b","work_date":"2026-09-20","cash_tips_cents":9900}
  ]$j$::jsonb)
$s$);
select pg_temp.as_user('11111111-1111-4111-8111-111111111111', $s$
  select public.upsert_shifts($j$[
    {"id":"cccccccc-0000-4000-8000-00000000000b","work_date":"2026-09-20","cash_tips_cents":100}
  ]$j$::jsonb)
$s$);
select pg_temp.expect('anotherAccountsRowIsNeverOverwritten',
  (select cash_tips_cents from public.shifts
    where id = 'cccccccc-0000-4000-8000-00000000000b'
      and user_id = '22222222-2222-4222-8222-222222222222') = 9900);
select pg_temp.expect('theSameIdUnderTwoAccountsIsTwoRows',
  (select count(*) from public.shifts
    where id = 'cccccccc-0000-4000-8000-00000000000b') = 2);

-- A shift written for the caller is written under the CALLER, never under an
-- id named in the payload.
select pg_temp.expect('aPayloadCannotNameAnotherAccount',
  (select user_id from public.shifts
    where id = 'cccccccc-0000-4000-8000-00000000000b'
      and cash_tips_cents = 100) = '11111111-1111-4111-8111-111111111111');

-- ===========================================================================
-- 4. The envelope. A payload that is not an array carries no rows, so there is
--    nothing to report an outcome for and silence would look like a
--    successful no-op push forever. This is the ONE thing allowed to raise.
-- ===========================================================================

create temporary table envelope (name text, sqlstate text);
insert into envelope
select 'upsertObject',   pg_temp.outcome_as('11111111-1111-4111-8111-111111111111',
  $q$ select * from public.upsert_shifts('{"id":"x"}'::jsonb) $q$)
union all
select 'upsertString',   pg_temp.outcome_as('11111111-1111-4111-8111-111111111111',
  $q$ select * from public.upsert_shifts('"x"'::jsonb) $q$)
union all
select 'upsertJsonNull', pg_temp.outcome_as('11111111-1111-4111-8111-111111111111',
  $q$ select * from public.upsert_shifts('null'::jsonb) $q$)
union all
select 'deleteObject',   pg_temp.outcome_as('11111111-1111-4111-8111-111111111111',
  $q$ select * from public.soft_delete_shifts('{"id":"x"}'::jsonb) $q$);
select pg_temp.expect('aNonArrayEnvelopeRaises22023',
  (select bool_and(sqlstate = '22023') from envelope),
  (select string_agg(name || '=' || sqlstate, ' ') from envelope));

select pg_temp.expect('anEmptyArrayIsAcceptedAndWritesNothing',
  pg_temp.outcome_as('11111111-1111-4111-8111-111111111111',
    $q$ select * from public.upsert_shifts('[]'::jsonb) $q$) = '00000');

-- An id in the case Swift actually sends. Every other fixture in this file is
-- lowercase, and PaydayRemoteModels encodes a UUID in UPPERCASE, so a reader
-- that was case-sensitive anywhere would pass this whole suite and fail on
-- every real device write.
create temporary table upper (shift_id uuid, status text, stored_client_updated_at timestamptz);
insert into upper
select (r ->> 'shift_id')::uuid, r ->> 'status',
       (r ->> 'stored_client_updated_at')::timestamptz
from jsonb_array_elements(pg_temp.rpc_as('11111111-1111-4111-8111-111111111111', $s$
  select * from public.upsert_shifts($j$[
    {"id":"AAAAAAAA-0000-4000-8000-00000000000A","work_date":"2026-09-11","cash_tips_cents":1234}
  ]$j$::jsonb)
$s$)) as r;
select pg_temp.expect('anUppercaseUuidIsAcceptedAndNormalised',
  (select status from upper) = 'stored'
  and (select cash_tips_cents from public.shifts
        where id = 'aaaaaaaa-0000-4000-8000-00000000000a'
          and user_id = '11111111-1111-4111-8111-111111111111') = 1234,
  'status=' || coalesce((select status from upper), 'none'));

-- ===========================================================================
-- 5. Deletion. The stored tombstone is the EARLIEST of requested and stored,
--    and the update only fires when that actually moves.
-- ===========================================================================

create temporary table del (shift_id uuid, status text);
insert into del
select (r ->> 'shift_id')::uuid, r ->> 'status'
from jsonb_array_elements(pg_temp.rpc_as('11111111-1111-4111-8111-111111111111', $s$
  select * from public.soft_delete_shifts($j$[
    {"id":"aaaaaaaa-0000-4000-8000-000000000009","deleted_at":"2099-01-01T00:00:00Z"},
    {"id":"aaaaaaaa-0000-4000-8000-000000000009","deleted_at":"2026-09-10T00:00:00Z"},
    {"id":"bbbbbbbb-0000-4000-8000-00000000ffff","deleted_at":"2026-09-10T00:00:00Z"},
    {"id":"not-a-uuid"}
  ]$j$::jsonb)
$s$)) as r;

select pg_temp.expect('deleteOutcomesAreTotalAndOnePerId',
  (select count(*) from del) = 3
  and (select count(*) from del where status = 'deleted') = 1
  and (select count(*) from del where status = 'absent') = 1
  and (select count(*) from del where status = 'invalid' and shift_id is null) = 1,
  (select string_agg(coalesce(shift_id::text,'(null)') || '=' || status, ' ' order by status) from del));

select pg_temp.expect('theEarliestRequestedTombstoneWins',
  (select deleted_at = '2026-09-10T00:00:00Z'::timestamptz from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000009'));

select pg_temp.expect('aUserDeletionIsReasonUser',
  (select deleted_reason = 'user' from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000009'));

-- A replayed delete must be a TRUE no-op. `version` is what the agent's
-- .eq("version", expected_version) guard reads, so bumping it on an
-- idempotent retry would manufacture 409s against a shift nobody edited.
create temporary table vsn as
  select version as before, version as after from public.shifts
   where id = 'aaaaaaaa-0000-4000-8000-000000000009';
select pg_temp.as_user('11111111-1111-4111-8111-111111111111', $s$
  select public.soft_delete_shifts($j$[
    {"id":"aaaaaaaa-0000-4000-8000-000000000009","deleted_at":"2026-09-10T00:00:00Z"}
  ]$j$::jsonb)
$s$);
update vsn set after = (select version from public.shifts
  where id = 'aaaaaaaa-0000-4000-8000-000000000009');
select pg_temp.expect('aReplayedDeleteDoesNotBumpVersion',
  (select before = after from vsn),
  (select 'before=' || before || ' after=' || after from vsn));

-- A later tombstone must not move an earlier one forward either.
select pg_temp.as_user('11111111-1111-4111-8111-111111111111', $s$
  select public.soft_delete_shifts($j$[
    {"id":"aaaaaaaa-0000-4000-8000-000000000009","deleted_at":"2026-09-30T00:00:00Z"}
  ]$j$::jsonb)
$s$);
select pg_temp.expect('aLaterDeleteCannotMoveTheTombstoneForward',
  (select deleted_at = '2026-09-10T00:00:00Z'::timestamptz from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000009'));

-- Rule 4: a WRITE never resurrects a tombstone. Only restore_shifts does.
select pg_temp.as_user('11111111-1111-4111-8111-111111111111', $s$
  select public.upsert_shifts($j$[
    {"id":"aaaaaaaa-0000-4000-8000-000000000009","work_date":"2026-09-09","cash_tips_cents":777}
  ]$j$::jsonb)
$s$);
select pg_temp.expect('aWriteNeverClearsATombstone',
  (select deleted_at is not null and deleted_reason = 'user' and cash_tips_cents = 777
     from public.shifts where id = 'aaaaaaaa-0000-4000-8000-000000000009'),
  'the edit must land and the shift must stay deleted');

-- A delete cannot reach another account's row. This uses an id only B owns,
-- NOT the shared one above: A owns a row under the shared id, so a delete
-- aimed at it would tombstone A's own row and every later assertion about
-- "A cannot touch this" would then be measuring A's row instead of B's.
select pg_temp.as_user('22222222-2222-4222-8222-222222222222', $s$
  select public.upsert_shifts($j$[
    {"id":"cccccccc-0000-4000-8000-00000000000c","work_date":"2026-09-22","cash_tips_cents":4200}
  ]$j$::jsonb)
$s$);
create temporary table xdel (shift_id uuid, status text);
insert into xdel
select (r ->> 'shift_id')::uuid, r ->> 'status'
from jsonb_array_elements(pg_temp.rpc_as('11111111-1111-4111-8111-111111111111', $s$
  select * from public.soft_delete_shifts($j$[
    {"id":"cccccccc-0000-4000-8000-00000000000c","deleted_at":"2026-09-22T00:00:00Z"}
  ]$j$::jsonb)
$s$)) as r;
select pg_temp.expect('aDeleteCannotReachAnotherAccountsRow',
  (select status from xdel) = 'absent'
  and (select deleted_at is null and cash_tips_cents = 4200 from public.shifts
    where id = 'cccccccc-0000-4000-8000-00000000000c'
      and user_id = '22222222-2222-4222-8222-222222222222'),
  'A saw status=' || coalesce((select status from xdel), 'none'));

-- ===========================================================================
-- 6. Restore. Four distinguishable outcomes, and 'converted' is untouchable.
-- ===========================================================================

-- The fold owns 'converted' tombstones. Reopening one here would resurrect a
-- shift whose legacy source rows are gone -- the shape that permanently
-- destroyed an undone shift in this design's first draft.
update public.shifts set deleted_at = statement_timestamp(), deleted_reason = 'converted'
  where id = 'aaaaaaaa-0000-4000-8000-000000000008';

create temporary table res (shift_id uuid, status text);
insert into res
select (r ->> 'shift_id')::uuid, r ->> 'status'
from jsonb_array_elements(pg_temp.rpc_as('11111111-1111-4111-8111-111111111111', $s$
  select * from public.restore_shifts(array[
    'aaaaaaaa-0000-4000-8000-000000000009'::uuid,   -- user tombstone
    'aaaaaaaa-0000-4000-8000-000000000008'::uuid,   -- converted tombstone
    'aaaaaaaa-0000-4000-8000-000000000001'::uuid,   -- live, not deleted
    'aaaaaaaa-0000-4000-8000-000000000009'::uuid,   -- duplicate of the first
    'bbbbbbbb-0000-4000-8000-00000000ffff'::uuid])  -- no such shift
$s$)) as r;

select pg_temp.expect('restoreOutcomesAreTotalAndOnePerId',
  (select count(*) from res) = 4
  and (select count(*) from res where status = 'restored') = 1
  and (select count(*) from res where status = 'refused') = 1
  and (select count(*) from res where status = 'not_deleted') = 1
  and (select count(*) from res where status = 'absent') = 1,
  (select string_agg(shift_id::text || '=' || status, ' ' order by status) from res));

select pg_temp.expect('restoringAUserTombstoneClearsBothColumns',
  (select deleted_at is null and deleted_reason is null from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000009'));

select pg_temp.expect('aConvertedTombstoneIsRefusedAndLeftDeleted',
  (select status from res where shift_id = 'aaaaaaaa-0000-4000-8000-000000000008') = 'refused'
  and (select deleted_at is not null and deleted_reason = 'converted' from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000008'));

select pg_temp.expect('restoreStampsNativeModifiedAtSoTheFoldStaysOut',
  (select native_modified_at is not null from public.shifts
    where id = 'aaaaaaaa-0000-4000-8000-000000000009'));

select pg_temp.expect('restoreIgnoresANullIdArray',
  pg_temp.outcome_as('11111111-1111-4111-8111-111111111111',
    $q$ select * from public.restore_shifts(null::uuid[]) $q$) = '00000');

-- Restore cannot reach another account's tombstone. Again B's exclusive id:
-- A owns no row under it, so the only honest answer for A is 'absent', and
-- B's tombstone must survive A's attempt untouched.
select pg_temp.as_user('22222222-2222-4222-8222-222222222222', $s$
  select public.soft_delete_shifts($j$[
    {"id":"cccccccc-0000-4000-8000-00000000000c","deleted_at":"2026-09-22T00:00:00Z"}
  ]$j$::jsonb)
$s$);
create temporary table xres (shift_id uuid, status text);
insert into xres
select (r ->> 'shift_id')::uuid, r ->> 'status'
from jsonb_array_elements(pg_temp.rpc_as('11111111-1111-4111-8111-111111111111', $s$
  select * from public.restore_shifts(array['cccccccc-0000-4000-8000-00000000000c'::uuid])
$s$)) as r;
select pg_temp.expect('restoreCannotReachAnotherAccountsTombstone',
  (select status from xres) = 'absent'
  and (select deleted_at is not null from public.shifts
    where id = 'cccccccc-0000-4000-8000-00000000000c'
      and user_id = '22222222-2222-4222-8222-222222222222'),
  'A saw status=' || coalesce((select status from xres), 'none'));

-- And A's OWN row under the shared id is still live: nothing above touched it.
select pg_temp.expect('theReachTestsLeftTheCallersOwnRowsAlone',
  (select deleted_at is null and cash_tips_cents = 100 from public.shifts
    where id = 'cccccccc-0000-4000-8000-00000000000b'
      and user_id = '11111111-1111-4111-8111-111111111111'));

-- ===========================================================================
-- 7. Grants. Every client write goes through the definer RPCs; a direct write
--    to public.shifts would let a session forge source, legacy_entry_ids,
--    deleted_reason or native_modified_at.
-- ===========================================================================

select pg_temp.expect('anonHasNoExecuteOnTheWriteRpcs',
  not has_function_privilege('anon', 'public.upsert_shifts(jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.soft_delete_shifts(jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.restore_shifts(uuid[])', 'execute'));

select pg_temp.expect('authenticatedHasExecuteOnAllThreeWriteRpcs',
  has_function_privilege('authenticated', 'public.upsert_shifts(jsonb)', 'execute')
  and has_function_privilege('authenticated', 'public.soft_delete_shifts(jsonb)', 'execute')
  and has_function_privilege('authenticated', 'public.restore_shifts(uuid[])', 'execute'));

select pg_temp.expect('theInnerWriterIsNotCallableByAClient',
  not has_function_privilege('authenticated', 'private.write_shifts(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'private.write_shifts(uuid, jsonb)', 'execute'));

select pg_temp.expect('shiftsStillGrantsNoDirectWrite',
  not has_table_privilege('authenticated', 'public.shifts', 'insert')
  and not has_table_privilege('authenticated', 'public.shifts', 'update')
  and not has_table_privilege('authenticated', 'public.shifts', 'delete'));

-- The safe readers must not be mistaken for immutable: casting text to date or
-- timestamptz reads DateStyle and TimeZone, so neither may reach an index or a
-- generated column.
select pg_temp.expect('theDateAndTimestampReadersAreStableNotImmutable',
  (select bool_and(provolatile = 's') from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname in ('jsonb_try_date','jsonb_try_timestamptz','jsonb_try_uuid')));

-- ===========================================================================
-- Report
-- ===========================================================================

select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 48,
  'ran ' || (select count(*) from results)::text || ' of 48');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed
from results;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'shift_write_rpcs_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'shift_write_rpcs_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id in (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222');
