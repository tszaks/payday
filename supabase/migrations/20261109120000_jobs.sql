-- PR E1: a job per shift and per paycheck (Pillar 9, jobs foundation).
--
-- A job is a NAME, like a role (20261108120000): public.shifts.job_name and
-- public.paycheck_records.job_name hold the job as typed, trimmed, 1-40
-- characters, NULL for the primary job. The list of jobs and any per-job
-- schedule live inside user_settings.compensation_policies (PaydayCore
-- JobPolicy) and need no column. It is not money, so the generated net and
-- every money comparison are unchanged.
--
-- private.write_shifts is redefined to store the key when present and to
-- keep the STORED job when the key is absent, exactly as role_name does
-- (20261108120000), so an older phone editing a shift does not wipe its job.
-- public.upsert_paycheck_records follows the same rule for paychecks;
-- public.import_paycheck_records (insert-only, on conflict do nothing) takes
-- the key when present.
--
-- Deliberately NOT on public.tip_entries (frozen for 1.0 builds), and
-- private.derive_shifts is not touched: it never names job_name, so its
-- upsert leaves a stored job alone, and legacy rows never carry one. Pinned
-- by supabase/tests/jobs_test.sql.
--
-- RLS and grants: both tables already have row-level security on the whole
-- row, so a new column inherits it with no statement here. The paycheck
-- functions are recreated with the same signatures, so their grants stand;
-- they are restated below anyway, as 20260904134500 does.

alter table public.shifts
  add column if not exists job_name text
    constraint shifts_job_name_length
    check (job_name is null or (length(job_name) between 1 and 40));

comment on column public.shifts.job_name is
  'The job this shift was worked at, as typed: trimmed, 1-40 characters, '
  'NULL for the primary job. Written by private.write_shifts only; a payload '
  'without the key keeps the stored value.';

alter table public.paycheck_records
  add column if not exists job_name text
    constraint paycheck_records_job_name_length
    check (job_name is null or (length(job_name) between 1 and 40));

comment on column public.paycheck_records.job_name is
  'The job this paycheck is from, as typed: trimmed, 1-40 characters, NULL '
  'for the primary job. A payload to upsert_paycheck_records without the key '
  'keeps the stored value.';

-- ---------------------------------------------------------------------------
-- The device writer, carrying the job. Identical to 20261108120000 except
-- for the job_name lines.
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
      private.jsonb_try_cents(el.row -> 'tip_share_in_cents')       as tip_share_in_cents,
      -- A build that predates tip share never sends the key. Its write must
      -- leave the stored share alone, not clear it, or the first edit made
      -- on an older phone silently deletes money from the shift.
      (el.row ? 'tip_share_in_cents')                               as has_tip_share_in,
      -- Trimmed, empty -> NULL, cut to 40 characters, so the CHECK on the
      -- column is satisfiable by construction and a long name costs its
      -- tail, never the batch (rule 5). Non-text JSON reads as NULL.
      left(nullif(btrim(private.jsonb_try_text(el.row -> 'role_name')), ''), 40)
                                                                    as role_name,
      -- Same rule as the share: a build that predates roles never sends the
      -- key, and its write keeps the stored role.
      (el.row ? 'role_name')                                        as has_role_name,
      -- The job (PR E1), read exactly as the role: trimmed, empty -> NULL,
      -- cut to 40 characters, non-text JSON reads as NULL. NULL means the
      -- primary job.
      left(nullif(btrim(private.jsonb_try_text(el.row -> 'job_name')), ''), 40)
                                                                    as job_name,
      -- A build that predates jobs never sends the key, and its write keeps
      -- the stored job.
      (el.row ? 'job_name')                                         as has_job_name,
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
      r.tip_share_in_cents::integer as tip_share_in_cents,
      r.has_tip_share_in,
      r.role_name,
      r.has_role_name,
      r.job_name,
      r.has_job_name,
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
      and coalesce(r.tip_share_in_cents, 0) <= 2147483647
  ),
  -- One outcome per requested id, and one UPDATE per key. Postgres raises
  -- 21000 if ON CONFLICT DO UPDATE touches a row twice, so a batch carrying
  -- the same id twice USED to abort whole. Last intent wins: the greatest
  -- stored client_updated_at, and on a tie -- which is the common case, since
  -- the clamp collapses every future-dated row onto v_now -- the later array
  -- position, which is the device's own ordering.
  picked as (
    select distinct on (v.id) v.*
    from valid v
    order by v.id, v.client_updated_at desc, v.ord desc
  ),
  -- A build that predates tip share never sends the key. Its row carries the
  -- STORED share forward rather than NULL, or the first edit made on an
  -- older phone would silently delete money from the shift. Read here, not
  -- in the DO UPDATE, because `excluded` cannot see whether the key was
  -- present. Race-free: the advisory lock above serialises every writer.
  deduped as (
    select p.ord, p.id, p.work_date, p.shift_period,
           p.cash_tips_cents, p.credit_tips_cents, p.tip_out_cents, p.sales_cents,
           p.hours_worked, p.clock_in, p.clock_out, p.server_count,
           case when p.has_tip_share_in then p.tip_share_in_cents
                else (select s0.tip_share_in_cents from public.shifts s0
                       where s0.user_id = p_user_id and s0.id = p.id) end
             as tip_share_in_cents,
           case when p.has_role_name then p.role_name
                else (select s0.role_name from public.shifts s0
                       where s0.user_id = p_user_id and s0.id = p.id) end
             as role_name,
           case when p.has_job_name then p.job_name
                else (select s0.job_name from public.shifts s0
                       where s0.user_id = p_user_id and s0.id = p.id) end
             as job_name,
           p.receipt_metrics, p.note, p.recorded_at, p.client_updated_at
    from picked p
  ),
  written as (
    insert into public.shifts as s (
      id, user_id, work_date, shift_period,
      cash_tips_cents, credit_tips_cents, tip_out_cents, sales_cents,
      hours_worked, clock_in, clock_out, server_count, tip_share_in_cents,
      role_name, job_name, receipt_metrics, note, recorded_at, source, native_modified_at,
      client_updated_at
    )
    select
      d.id, p_user_id, d.work_date, d.shift_period,
      d.cash_tips_cents, d.credit_tips_cents, d.tip_out_cents, d.sales_cents,
      d.hours_worked, d.clock_in, d.clock_out, d.server_count, d.tip_share_in_cents,
      d.role_name, d.job_name, d.receipt_metrics, d.note, d.recorded_at, 'device', v_now,
      d.client_updated_at
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
      tip_share_in_cents = excluded.tip_share_in_cents,
      role_name         = excluded.role_name,
      job_name          = excluded.job_name,
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
     or coalesce(r.tip_share_in_cents, 0) > 2147483647
  union all
  select null::uuid, 'invalid', null::timestamptz
  from elements el
  where jsonb_typeof(el.row) <> 'object';
end;
$$;

revoke all on function private.write_shifts(uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The paycheck writers, carrying the job. Identical to 20260904134500 except
-- that each element is read as an object (so the function can see whether
-- job_name is PRESENT) and for the job_name lines. The name is trimmed,
-- empty -> NULL and cut to 40 characters, so the CHECK can never abort a
-- batch. The text guard is spelled inline (as private.jsonb_try_text does
-- it) because these functions run as the caller, who has no usage on schema
-- private.
-- ---------------------------------------------------------------------------

create or replace function public.import_paycheck_records(p_rows jsonb)
returns setof public.paycheck_records
language sql
security invoker
set search_path = ''
as $$
  insert into public.paycheck_records (
    id, user_id, period_start, period_end, paid_tips_cents, note,
    hourly_rate_cents, owed_tips_cents, gross_pay_cents, net_pay_cents,
    regular_wages_cents, overtime_wages_cents, gratuity_cents, taxes_cents,
    job_name, client_updated_at, deleted_at
  )
  select
    row.id,
    (select auth.uid()),
    row.period_start,
    row.period_end,
    row.paid_tips_cents,
    row.note,
    row.hourly_rate_cents,
    row.owed_tips_cents,
    row.gross_pay_cents,
    row.net_pay_cents,
    row.regular_wages_cents,
    row.overtime_wages_cents,
    row.gratuity_cents,
    row.taxes_cents,
    left(nullif(btrim(case when jsonb_typeof(e.obj -> 'job_name') = 'string'
                         then e.obj ->> 'job_name' end), ''), 40),
    least(row.client_updated_at, statement_timestamp()),
    null
  from jsonb_array_elements(p_rows) as e(obj)
  cross join lateral jsonb_to_record(e.obj) as row(
    id uuid,
    period_start date,
    period_end date,
    paid_tips_cents integer,
    note text,
    hourly_rate_cents integer,
    owed_tips_cents integer,
    gross_pay_cents integer,
    net_pay_cents integer,
    regular_wages_cents integer,
    overtime_wages_cents integer,
    gratuity_cents integer,
    taxes_cents integer,
    client_updated_at timestamptz
  )
  where (select auth.uid()) is not null
  on conflict (id) do nothing
  returning public.paycheck_records.*;
$$;

create or replace function public.upsert_paycheck_records(p_rows jsonb)
returns setof public.paycheck_records
language sql
security invoker
set search_path = ''
as $$
  -- Serialised per user, as private.write_shifts is. The missing-key
  -- fallback below reads the STORED job in the insert's source; without
  -- this lock a newer phone's upload could commit between that read and
  -- the conflict update, and an older phone's write would put the old job
  -- back. Its own statement, so the insert's snapshot starts after the lock.
  select pg_advisory_xact_lock(hashtextextended('payday:paychecks:' || (select auth.uid())::text, 0))
  where (select auth.uid()) is not null;

  insert into public.paycheck_records (
    id, user_id, period_start, period_end, paid_tips_cents, note,
    hourly_rate_cents, owed_tips_cents, gross_pay_cents, net_pay_cents,
    regular_wages_cents, overtime_wages_cents, gratuity_cents, taxes_cents,
    job_name, client_updated_at, deleted_at
  )
  select
    row.id,
    (select auth.uid()),
    row.period_start,
    row.period_end,
    row.paid_tips_cents,
    row.note,
    row.hourly_rate_cents,
    row.owed_tips_cents,
    row.gross_pay_cents,
    row.net_pay_cents,
    row.regular_wages_cents,
    row.overtime_wages_cents,
    row.gratuity_cents,
    row.taxes_cents,
    -- A build that predates jobs never sends the key. Its write carries the
    -- STORED job forward rather than NULL, or the first edit made on an
    -- older phone would silently move the check to the primary job. Read
    -- here, not in the DO UPDATE, because `excluded` cannot see whether the
    -- key was present.
    case when e.obj ? 'job_name'
         then left(nullif(btrim(case when jsonb_typeof(e.obj -> 'job_name') = 'string'
                         then e.obj ->> 'job_name' end), ''), 40)
         else (select p0.job_name from public.paycheck_records p0
                where p0.id = row.id and p0.user_id = (select auth.uid())) end,
    least(row.client_updated_at, statement_timestamp()),
    row.deleted_at
  from jsonb_array_elements(p_rows) as e(obj)
  cross join lateral jsonb_to_record(e.obj) as row(
    id uuid,
    period_start date,
    period_end date,
    paid_tips_cents integer,
    note text,
    hourly_rate_cents integer,
    owed_tips_cents integer,
    gross_pay_cents integer,
    net_pay_cents integer,
    regular_wages_cents integer,
    overtime_wages_cents integer,
    gratuity_cents integer,
    taxes_cents integer,
    client_updated_at timestamptz,
    deleted_at timestamptz
  )
  where (select auth.uid()) is not null
  on conflict (id) do update set
    period_start = excluded.period_start,
    period_end = excluded.period_end,
    paid_tips_cents = excluded.paid_tips_cents,
    note = excluded.note,
    hourly_rate_cents = excluded.hourly_rate_cents,
    owed_tips_cents = excluded.owed_tips_cents,
    gross_pay_cents = excluded.gross_pay_cents,
    net_pay_cents = excluded.net_pay_cents,
    regular_wages_cents = excluded.regular_wages_cents,
    overtime_wages_cents = excluded.overtime_wages_cents,
    gratuity_cents = excluded.gratuity_cents,
    taxes_cents = excluded.taxes_cents,
    job_name = excluded.job_name,
    client_updated_at = excluded.client_updated_at,
    deleted_at = excluded.deleted_at
  where public.paycheck_records.user_id = (select auth.uid())
  returning public.paycheck_records.*;
$$;

revoke all on function public.import_paycheck_records(jsonb) from public, anon;
revoke all on function public.upsert_paycheck_records(jsonb) from public, anon;
grant execute on function public.import_paycheck_records(jsonb) to authenticated;
grant execute on function public.upsert_paycheck_records(jsonb) to authenticated;
