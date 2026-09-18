-- PR 2 slice S6: the shift write RPCs and their one shared writer.
--
-- S2 created public.shifts, S3 the deriver, S4 the on-arrival fold, S5 the
-- one-shot. All of those WRITE shifts from inside the database. This slice is
-- the first path by which a DEVICE writes one, so it is where the rules that
-- keep a device write from fighting a conversion live.
--
-- Five rules, each paid for by something measured, four of them earlier in
-- PR 2 and the fifth on this file's own first draft:
--
-- 1. SECURITY DEFINER with the subject captured FIRST. A security-invoker
--    function that reaches into schema `private` fails 42501 ("permission
--    denied for schema private") because Supabase's `postgres` role is not a
--    superuser and `private` is revoked from `authenticated`. Every public
--    entry point here is definer, resolves `auth.uid()` into a local before
--    it touches anything, and refuses to name another account.
--
-- 2. The BLOCKING advisory lock on payday:shiftmig:<uid>, not the try-lock.
--    The fold trigger uses `pg_try_advisory_xact_lock` because it runs inside
--    a shipped 1.0 build's transaction and must never make that write wait.
--    A device write to `shifts` is a PR-2-build write: it is allowed to wait,
--    and it must, because the alternative is racing the one-shot over the same
--    keys and losing a row's money to a stale snapshot. S4 measured that
--    exact loss: two writers on one group under READ COMMITTED with no lock
--    produced cash=0/credit=2000 and an orphaned cash row.
--
-- 3. NO CLOCK GATE. `upsert_tip_entries` gates on
--    `excluded.client_updated_at >= existing.client_updated_at`, which is
--    last-write-wins by a DEVICE clock. Shifts do not: a device's clock can
--    be wrong, and the hotfix on 2026-09-17 proved the client half of that
--    contract was never even reached (`didSet` never fires on a SwiftData
--    model, so `modifiedAt` was frozen and an edited row never entered the
--    upload set). Instead the incoming `client_updated_at` is CLAMPED to
--    `statement_timestamp()`, so a device that thinks it is next year cannot
--    park a row permanently ahead of every later edit, and the outcome row
--    tells the client what was actually stored.
--
-- 4. `deleted_at` is ONE-WAY here. A write never resurrects a tombstone; only
--    `restore_shifts` does, and only one it did not create as `'converted'`.
--    The fold's own un-delete arm reopens a `'converted'` tombstone; a user
--    deletion is `'user'` and stays deleted until the user undoes it.
--
-- 5. TOTAL OVER ARBITRARY JSON. No device payload may abort the statement.
--    This rule is the whole reason the field reading below looks laborious,
--    and it was bought with three measurements against Postgres 17.11 on this
--    file's first draft, which had all three defects:
--
--      * two rows carrying the SAME id in one batch raised 21000
--        ("ON CONFLICT DO UPDATE command cannot affect row a second time");
--      * `"shift_period":"brunch"` raised 23514 against the domain CHECK;
--      * a cents value above int4, or a non-numeric one, raises 22003 / 22P02
--        inside `jsonb_to_recordset` before any guard of ours can see it.
--        Note what "one row" means for that third one: the row is REFUSED,
--        not clamped. Clamping it to int4max would have stored
--        $21,474,836.47 as the user's tips, which is a fabrication the app
--        would then display; see private.jsonb_try_cents.
--
--    Each of those aborts the ENTIRE batch, which is far worse than it looks:
--    the device's push is a fixed set of rows, so it retries the identical
--    payload, gets the identical abort, and the account stops syncing
--    permanently and silently. One malformed field must cost one row.
--
--    So this file does not use `jsonb_to_recordset`, whose column-definition
--    list does the casting where no guard can reach. It walks
--    `jsonb_array_elements ... with ordinality` and reads every field through
--    a `jsonb_typeof` guard or a try-cast. (`with ordinality` is also why
--    `jsonb_to_recordset` had to go: combining it with a column-definition
--    list is a 42601 syntax error, measured, and ordinality is what makes
--    "the last of two rows sharing an id wins" deterministic.)
--
-- One thing this file deliberately does NOT write: `source`. An update leaves
-- it exactly as it was, so a shift the one-shot derived still reads
-- `source = 'migration'` after a device edits it. S2 declares
-- `source = 'migration'` plus `legacy_entry_ids` to be the only safe rollback
-- query, and stamping 'device' on an edit would hide a conversion artifact
-- from the one query rollback depends on. Origin and human-touch are two
-- orthogonal facts: `source` is where the row came from, `native_modified_at`
-- is whether anyone has touched it since.
--
-- The cost of that, stated plainly: a rollback stops reading public.shifts and
-- reads public.tip_entries again, where the shift is still worth its ORIGINAL
-- amount, because a PR-2 build's edit never writes back to the legacy table.
-- A device edit to a CONVERTED shift would therefore be lost by a rollback.
-- That is an accepted cost of an emergency lever, but it must be findable
-- before anyone pulls it, so the set is queryable and asserted in
-- scripts/db-test-race.sh:
--
--   select * from public.shifts
--    where source = 'migration' and native_modified_at is not null;
--
-- Every function returns an OUTCOME per requested id rather than a bare count,
-- so the client can tell "stored" from "refused" from "not mine" without a
-- second read. Totality is a test: every requested id appears exactly once in
-- the result, and ids repeated in one batch collapse to one outcome.

set check_function_bodies = off;

-- ---------------------------------------------------------------------------
-- Safe readers. Each returns NULL rather than raising, which is what makes
-- rule 5 hold. They are STABLE, not IMMUTABLE: casting text to date or
-- timestamptz reads the DateStyle and TimeZone GUCs. Nothing here may be used
-- in an index or a generated column for that reason.
--
-- pg_catalog is always searched ahead of `search_path`, so the built-ins and
-- operators below need no qualification even under `set search_path = ''` --
-- the same thing private.receipt_gratuity_cents relies on.
-- ---------------------------------------------------------------------------

create or replace function private.jsonb_try_uuid(p jsonb)
returns uuid language plpgsql stable set search_path = '' as $$
begin
  if jsonb_typeof(p) is distinct from 'string' then return null; end if;
  return (p #>> '{}')::uuid;
exception when others then return null;
end;
$$;

create or replace function private.jsonb_try_date(p jsonb)
returns date language plpgsql stable set search_path = '' as $$
begin
  if jsonb_typeof(p) is distinct from 'string' then return null; end if;
  return (p #>> '{}')::date;
exception when others then return null;
end;
$$;

create or replace function private.jsonb_try_timestamptz(p jsonb)
returns timestamptz language plpgsql stable set search_path = '' as $$
begin
  if jsonb_typeof(p) is distinct from 'string' then return null; end if;
  return (p #>> '{}')::timestamptz;
exception when others then return null;
end;
$$;

-- A JSON number is always numeric-castable, so the typeof guard alone makes
-- the cast safe. It stays NUMERIC on the way out, because casting to integer
-- is what raises 22003 and a clamp applied after that cast is too late.
--
-- It clamps the FLOOR and deliberately not the ceiling, and that asymmetry is
-- the point. Negative cents are never a real quantity in this app, so pinning
-- one to 0 changes the figure by less than the figure itself and the shift
-- still saves. A value ABOVE int4 is different in kind: pinning it to
-- 2147483647 would fabricate $21,474,836.47 and put it in front of the user as
-- their own tips. So the ceiling is not clamped here -- `valid` below rejects
-- the row instead, which is the only honest option for money this column
-- cannot hold. Clamp up to the floor, never down from the ceiling.
create or replace function private.jsonb_try_cents(p jsonb)
returns numeric language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p) = 'number'
    then greatest(0::numeric, (p #>> '{}')::numeric)
    else null end;
$$;

-- hours_worked is a NUMERIC column with no precision limit, so there is no
-- ceiling to overflow and the floor clamp is the whole job.
create or replace function private.jsonb_try_hours(p jsonb)
returns numeric language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p) = 'number'
    then greatest(0::numeric, (p #>> '{}')::numeric)
    else null end;
$$;

create or replace function private.jsonb_try_text(p jsonb)
returns text language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p) = 'string' then p #>> '{}' else null end;
$$;

comment on function private.jsonb_try_cents(jsonb) is
  'NULL unless the value is a JSON number; then floored at 0 and returned as '
  'NUMERIC, never cast to integer -- the cast is what raises 22003. The '
  'ceiling is deliberately NOT clamped: a cents value above int4 invalidates '
  'its row, because pinning it to int4max would fabricate $21,474,836.47 and '
  'show it to the user as earnings.';

-- ---------------------------------------------------------------------------
-- The one writer. upsert_shifts funnels here so the lock, the clamp, the
-- sanitising and the stamping cannot drift between callers.
-- ---------------------------------------------------------------------------
create or replace function private.write_shifts(
  p_user_id uuid,
  p_rows jsonb
)
returns table (shift_id uuid, status text, stored_client_updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := statement_timestamp();
begin
  -- The ENVELOPE is the one thing that is allowed to raise, because a payload
  -- that is not an array carries no rows at all: there is nothing to report an
  -- outcome for, and silently treating it as empty would let a client bug look
  -- like a successful no-op push forever.
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'write_shifts expects a JSON array of shift objects, got %',
      coalesce(jsonb_typeof(p_rows), 'null')
      using errcode = '22023';
  end if;

  -- Rule 2. Blocking, and taken BEFORE the first read of public.shifts, so a
  -- concurrent one-shot or fold either finished before us or waits for us.
  -- hashtextextended keeps the key space disjoint from the fold's own.
  perform pg_advisory_xact_lock(
    hashtextextended('payday:shiftmig:' || p_user_id::text, 0));

  return query
  with elements as (
    select e.row, e.ord
    from jsonb_array_elements(p_rows) with ordinality as e(row, ord)
  ),
  -- Rule 5. Every field read through a guard. Nothing below can raise, so a
  -- malformed row costs exactly itself.
  read_rows as (
    select
      el.ord,
      private.jsonb_try_uuid(el.row -> 'id')                        as id,
      private.jsonb_try_date(el.row -> 'work_date')                 as work_date,
      -- Out of domain becomes NULL rather than a 23514 that kills the batch.
      -- A lost period costs a label; a rejected batch costs the night.
      case when private.jsonb_try_text(el.row -> 'shift_period')
                in ('lunch', 'dinner')
           then private.jsonb_try_text(el.row -> 'shift_period')
           else null end                                            as shift_period,
      coalesce(private.jsonb_try_cents(el.row -> 'cash_tips_cents'), 0)
                                                                    as cash_tips_cents,
      coalesce(private.jsonb_try_cents(el.row -> 'credit_tips_cents'), 0)
                                                                    as credit_tips_cents,
      private.jsonb_try_cents(el.row -> 'tip_out_cents')            as tip_out_cents,
      private.jsonb_try_cents(el.row -> 'sales_cents')              as sales_cents,
      private.jsonb_try_hours(el.row -> 'hours_worked')             as hours_worked,
      private.jsonb_try_timestamptz(el.row -> 'clock_in')           as clock_in,
      private.jsonb_try_timestamptz(el.row -> 'clock_out')          as clock_out,
      private.jsonb_try_cents(el.row -> 'server_count')             as server_count,
      -- The v2 CHECK is satisfiable-by-construction or the payload is dropped:
      -- a device that sends a v1 or junk payload gets a shift with no receipt
      -- rather than a rejected write. jsonb_typeof is tested BEFORE the cast,
      -- because a numeric cast on `true` aborts the statement uncatchably.
      case
        when jsonb_typeof(el.row -> 'receipt_metrics') <> 'object' then null
        when jsonb_typeof(el.row -> 'receipt_metrics' -> 'earningsSchemaVersion') = 'number'
             and (el.row -> 'receipt_metrics' ->> 'earningsSchemaVersion')::numeric >= 2
          then el.row -> 'receipt_metrics'
        else null
      end                                                           as receipt_metrics,
      private.jsonb_try_text(el.row -> 'note')                      as note,
      private.jsonb_try_timestamptz(el.row -> 'recorded_at')        as recorded_at,
      -- Rule 3. Clamped, never trusted.
      least(coalesce(private.jsonb_try_timestamptz(el.row -> 'client_updated_at'), v_now),
            v_now)                                                  as client_updated_at
    from elements el
    where jsonb_typeof(el.row) = 'object'
  ),
  valid as (
    select
      r.ord, r.id, r.work_date, r.shift_period,
      r.cash_tips_cents::integer   as cash_tips_cents,
      r.credit_tips_cents::integer as credit_tips_cents,
      r.tip_out_cents::integer     as tip_out_cents,
      r.sales_cents::integer       as sales_cents,
      r.hours_worked,
      r.clock_in, r.clock_out,
      r.server_count::integer      as server_count,
      r.receipt_metrics, r.note, r.recorded_at, r.client_updated_at
    from read_rows r
    where r.id is not null
      and r.work_date is not null
      -- Money this column cannot hold makes the ROW invalid. See
      -- private.jsonb_try_cents: the alternative is a fabricated $21m
      -- headline. The casts above are safe only because of this filter.
      and r.cash_tips_cents   <= 2147483647
      and r.credit_tips_cents <= 2147483647
      and coalesce(r.tip_out_cents, 0)  <= 2147483647
      and coalesce(r.sales_cents, 0)    <= 2147483647
      and coalesce(r.server_count, 0)   <= 2147483647
  ),
  -- One outcome per requested id, and one UPDATE per key. Postgres raises
  -- 21000 if ON CONFLICT DO UPDATE touches a row twice, so a batch carrying
  -- the same id twice USED to abort whole. Last intent wins: the greatest
  -- stored client_updated_at, and on a tie -- which is the common case, since
  -- the clamp collapses every future-dated row onto v_now -- the later array
  -- position, which is the device's own ordering.
  deduped as (
    select distinct on (v.id) v.*
    from valid v
    order by v.id, v.client_updated_at desc, v.ord desc
  ),
  written as (
    insert into public.shifts as s (
      id, user_id, work_date, shift_period,
      cash_tips_cents, credit_tips_cents, tip_out_cents, sales_cents,
      hours_worked, clock_in, clock_out, server_count, receipt_metrics,
      note, recorded_at, source, native_modified_at, client_updated_at
    )
    select
      d.id, p_user_id, d.work_date, d.shift_period,
      d.cash_tips_cents, d.credit_tips_cents, d.tip_out_cents, d.sales_cents,
      d.hours_worked, d.clock_in, d.clock_out, d.server_count, d.receipt_metrics,
      d.note, d.recorded_at, 'device', v_now, d.client_updated_at
    from deduped d
    on conflict (user_id, id) do update set
      work_date         = excluded.work_date,
      shift_period      = excluded.shift_period,
      cash_tips_cents   = excluded.cash_tips_cents,
      credit_tips_cents = excluded.credit_tips_cents,
      tip_out_cents     = excluded.tip_out_cents,
      sales_cents       = excluded.sales_cents,
      hours_worked      = excluded.hours_worked,
      clock_in          = excluded.clock_in,
      clock_out         = excluded.clock_out,
      server_count      = excluded.server_count,
      receipt_metrics   = excluded.receipt_metrics,
      note              = excluded.note,
      recorded_at       = excluded.recorded_at,
      -- A device edit is what makes a derived shift "adopted":
      -- private.shift_is_open_to_fold reads exactly this column, so stamping
      -- it is what stops the fold repricing this shift's money from the
      -- legacy rows. The fold never writes it; this function is its only
      -- author, which is why public.shifts grants no direct INSERT or UPDATE.
      native_modified_at = v_now,
      client_updated_at  = excluded.client_updated_at,
      -- Rule 4. One-way. A write never clears a tombstone.
      deleted_at        = s.deleted_at,
      deleted_reason    = s.deleted_reason
    returning s.id, s.client_updated_at
  )
  -- 'refused' is unreachable today and stays anyway. Every deduped row is
  -- written, because the only trigger on public.shifts (shifts_touch_version)
  -- always returns NEW and there is no BEFORE INSERT trigger at all. If a
  -- later slice adds one that can return NULL, this arm turns a SILENTLY
  -- dropped shift into an honest outcome instead of a false 'stored'.
  select d.id,
         case when w.id is null then 'refused' else 'stored' end,
         w.client_updated_at
  from deduped d
  left join written w on w.id = d.id
  union all
  -- Totality, part two: an element that carried no usable id, or no work
  -- date, or was not even an object, still produces exactly one row. Its
  -- shift_id is NULL when the id itself is what was unreadable.
  select r.id, 'invalid', null::timestamptz
  from read_rows r
  where r.id is null
     or r.work_date is null
     or r.cash_tips_cents   > 2147483647
     or r.credit_tips_cents > 2147483647
     or coalesce(r.tip_out_cents, 0) > 2147483647
     or coalesce(r.sales_cents, 0)   > 2147483647
     or coalesce(r.server_count, 0)  > 2147483647
  union all
  select null::uuid, 'invalid', null::timestamptz
  from elements el
  where jsonb_typeof(el.row) <> 'object';
end;
$$;

revoke all on function private.write_shifts(uuid, jsonb) from public, anon, authenticated;

comment on function private.write_shifts(uuid, jsonb) is
  'The one writer behind upsert_shifts. Takes the BLOCKING payday:shiftmig lock '
  'before touching public.shifts (the try-lock is the fold''s, because the fold '
  'runs inside a shipped 1.0 transaction and may not wait; a device write may). '
  'Clamps client_updated_at to statement_timestamp rather than gating on it, '
  'stamps source=device and native_modified_at so the fold stops repricing an '
  'adopted shift, and never clears a tombstone. Total over arbitrary JSON: one '
  'malformed field costs one row, never the batch, because a rejected batch is '
  'retried identically forever and stops the account syncing.';

-- ---------------------------------------------------------------------------
-- public.upsert_shifts
-- ---------------------------------------------------------------------------
create or replace function public.upsert_shifts(p_rows jsonb)
returns table (shift_id uuid, status text, stored_client_updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'upsert_shifts requires an authenticated subject'
      using errcode = '42501';
  end if;
  return query select * from private.write_shifts(v_uid, p_rows);
end;
$$;

revoke all on function public.upsert_shifts(jsonb) from public, anon;
grant execute on function public.upsert_shifts(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- public.soft_delete_shifts. The client sends id -> deleted_at; the stored
-- value is the EARLIEST of the two, so a replayed delete cannot move a
-- tombstone later and a clock-skewed one cannot park it in the future.
--
-- The UPDATE is guarded on the value actually changing. Without that guard a
-- replayed delete bumps `version` every time, and `version` is what the
-- agent's .eq("version", expected_version) check reads: an idempotent retry
-- would manufacture 409s against a shift nobody edited.
-- ---------------------------------------------------------------------------
create or replace function public.soft_delete_shifts(p_rows jsonb)
returns table (shift_id uuid, status text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_now timestamptz := statement_timestamp();
begin
  if v_uid is null then
    raise exception 'soft_delete_shifts requires an authenticated subject'
      using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'soft_delete_shifts expects a JSON array of {id, deleted_at}, got %',
      coalesce(jsonb_typeof(p_rows), 'null')
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('payday:shiftmig:' || v_uid::text, 0));

  return query
  with read_rows as (
    select
      private.jsonb_try_uuid(e.row -> 'id') as id,
      least(coalesce(private.jsonb_try_timestamptz(e.row -> 'deleted_at'), v_now),
            v_now)                          as deleted_at
    from jsonb_array_elements(p_rows) as e(row)
    where jsonb_typeof(e.row) = 'object'
  ),
  -- One outcome per id; earliest requested tombstone wins, matching the
  -- earliest-of-the-two rule applied against what is already stored.
  incoming as (
    select distinct on (r.id) r.id, r.deleted_at
    from read_rows r
    where r.id is not null
    order by r.id, r.deleted_at asc
  ),
  -- Classified from the SAME pre-statement snapshot the UPDATE below reads,
  -- which is what lets "already deleted" and "does not exist" be told apart.
  mine as (
    select i.id, i.deleted_at as requested_at, s.id as found_id
    from incoming i
    left join public.shifts s on s.user_id = v_uid and s.id = i.id
  ),
  touched as (
    update public.shifts s
       set deleted_at        = i.deleted_at,
           deleted_reason    = coalesce(s.deleted_reason, 'user'),
           client_updated_at = greatest(s.client_updated_at, i.deleted_at)
      from incoming i
     where s.user_id = v_uid
       and s.id = i.id
       and (s.deleted_at is null or s.deleted_at > i.deleted_at)
    returning s.id
  )
  select m.id,
         case when m.found_id is null then 'absent' else 'deleted' end
  from mine m
  union all
  select r.id, 'invalid' from read_rows r where r.id is null;
end;
$$;

revoke all on function public.soft_delete_shifts(jsonb) from public, anon;
grant execute on function public.soft_delete_shifts(jsonb) to authenticated;

comment on function public.soft_delete_shifts(jsonb) is
  'Stores the EARLIEST of the requested and the stored tombstone, and only '
  'when that actually moves it, so a replayed delete is a true no-op and does '
  'not inflate `version` into a spurious 409. Reports deleted | absent | '
  'invalid, exactly once per requested id.';

-- ---------------------------------------------------------------------------
-- public.restore_shifts. The inverse of a USER deletion only. A 'converted'
-- tombstone belongs to the fold's own un-delete arm: restoring one here would
-- resurrect a shift whose legacy rows are gone, which is the shape that
-- destroyed an undone shift in the design's first draft.
--
-- p_ids is uuid[], so a malformed id is rejected at the API boundary by
-- Postgres itself and never reaches this body -- rule 5 needs no help here.
-- ---------------------------------------------------------------------------
create or replace function public.restore_shifts(p_ids uuid[])
returns table (shift_id uuid, status text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_now timestamptz := statement_timestamp();
begin
  if v_uid is null then
    raise exception 'restore_shifts requires an authenticated subject'
      using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('payday:shiftmig:' || v_uid::text, 0));

  return query
  with incoming as (
    select distinct unnest(coalesce(p_ids, '{}'::uuid[])) as id
  ),
  mine as (
    select i.id, s.id as found_id, s.deleted_at
    from incoming i
    left join public.shifts s on s.user_id = v_uid and s.id = i.id
  ),
  reopened as (
    update public.shifts s
       set deleted_at         = null,
           deleted_reason     = null,
           client_updated_at  = greatest(s.client_updated_at, v_now),
           native_modified_at = v_now
      from incoming i
     where s.user_id = v_uid
       and s.id = i.id
       and s.deleted_at is not null
       and coalesce(s.deleted_reason, 'user') <> 'converted'
    returning s.id
  )
  -- Four distinguishable outcomes, because the client's recovery differs for
  -- each: retry a sync (absent), do nothing (not_deleted), or surface that the
  -- shift belongs to a conversion (refused).
  select m.id,
         case
           when r.id is not null       then 'restored'
           when m.found_id is null     then 'absent'
           when m.deleted_at is null   then 'not_deleted'
           else                             'refused'
         end
  from mine m
  left join reopened r on r.id = m.id;
end;
$$;

revoke all on function public.restore_shifts(uuid[]) from public, anon;
grant execute on function public.restore_shifts(uuid[]) to authenticated;

comment on function public.restore_shifts(uuid[]) is
  'Undo of a USER deletion. Refuses a ''converted'' tombstone, which belongs to '
  'the fold''s un-delete arm: reopening one here would resurrect a shift whose '
  'legacy source rows are gone. Reports restored | absent | not_deleted | '
  'refused so the client can tell those four apart without a second read.';
