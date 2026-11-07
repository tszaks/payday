-- PR A: "card tips paid at close" (a setting) and "tip share received" (a
-- per-shift amount).
--
-- 1. public.user_settings.card_tips_paid_at_close. False means card tips
--    arrive on the paycheck (every account's behaviour before this column).
--    True means they are paid out at the end of the shift, in cash or to a
--    pay card, so the engine expects no tips line on the stub. Synced both
--    ways through the settings RPCs, which are redefined below; a payload
--    without the key leaves the stored value alone.
--
-- 2. public.shifts.tip_share_in_cents. A tip share or pool payout the person
--    RECEIVED from co-workers. Null means "not entered". It is earned money,
--    so it joins the generated net, non_wage_earnings_cents, which is dropped
--    and re-added below because a generated expression cannot be altered in
--    place.
--
-- Deliberately NOT on public.tip_entries. Legacy rows are written only by
-- 1.0 builds and by the agent API's legacy write path, and neither can carry
-- a received share. A shift folded from legacy rows therefore has a null
-- share, which is the truth, and private.derive_shifts needs no change: it
-- never names the column, so its upsert leaves it alone, and it only ever
-- rewrites a shift no device has written (private.shift_is_open_to_fold),
-- which is the only writer of this column.
--
-- private.legacy_non_wage_cents keeps its four-argument form for the
-- deriver (the legacy group has no share). A five-argument form is added as
-- the exact twin of the new generated expression; the four-argument form now
-- delegates to it with a null share, so the arithmetic is spelled once.

-- ---------------------------------------------------------------------------
-- 1. The payout setting.
-- ---------------------------------------------------------------------------

alter table public.user_settings
  add column if not exists card_tips_paid_at_close boolean not null default false;

comment on column public.user_settings.card_tips_paid_at_close is
  'False: card tips are paid on the paycheck. True: card tips (and any tip '
  'share received) are paid at the end of the shift, so the expected check '
  'has no tips line and nothing is audited against the stub''s tips line.';

create or replace function public.import_user_settings(p_row jsonb)
returns setof public.user_settings
language sql
security invoker
set search_path = ''
as $$
  insert into public.user_settings (
    user_id, first_name, base_hourly_wage_cents, pay_frequency,
    anchor_period_end, pay_delay_days, first_weekday,
    smart_nudge_enabled, payday_reminder_enabled, move_ledger,
    compensation_policies, card_tips_paid_at_close,
    client_updated_at
  )
  select
    (select auth.uid()),
    row.first_name,
    row.base_hourly_wage_cents,
    row.pay_frequency,
    row.anchor_period_end,
    row.pay_delay_days,
    row.first_weekday,
    coalesce(row.smart_nudge_enabled, true),
    coalesce(row.payday_reminder_enabled, true),
    coalesce(row.move_ledger, '{}'::jsonb),
    row.compensation_policies,
    coalesce(row.card_tips_paid_at_close, false),
    least(row.client_updated_at, statement_timestamp())
  from jsonb_to_record(p_row) as row(
    first_name text,
    base_hourly_wage_cents integer,
    pay_frequency text,
    anchor_period_end date,
    pay_delay_days integer,
    first_weekday integer,
    smart_nudge_enabled boolean,
    payday_reminder_enabled boolean,
    move_ledger jsonb,
    compensation_policies jsonb,
    card_tips_paid_at_close boolean,
    client_updated_at timestamptz
  )
  where (select auth.uid()) is not null
  on conflict (user_id) do nothing
  returning public.user_settings.*;
$$;

create or replace function public.upsert_user_settings(p_row jsonb)
returns setof public.user_settings
language sql
security invoker
set search_path = ''
as $$
  insert into public.user_settings (
    user_id, first_name, base_hourly_wage_cents, pay_frequency,
    anchor_period_end, pay_delay_days, first_weekday,
    smart_nudge_enabled, payday_reminder_enabled, move_ledger,
    compensation_policies, card_tips_paid_at_close,
    client_updated_at
  )
  select
    (select auth.uid()),
    row.first_name,
    row.base_hourly_wage_cents,
    row.pay_frequency,
    row.anchor_period_end,
    row.pay_delay_days,
    row.first_weekday,
    coalesce(row.smart_nudge_enabled, true),
    coalesce(row.payday_reminder_enabled, true),
    coalesce(row.move_ledger, '{}'::jsonb),
    row.compensation_policies,
    coalesce(row.card_tips_paid_at_close, false),
    least(row.client_updated_at, statement_timestamp())
  from jsonb_to_record(p_row) as row(
    first_name text,
    base_hourly_wage_cents integer,
    pay_frequency text,
    anchor_period_end date,
    pay_delay_days integer,
    first_weekday integer,
    smart_nudge_enabled boolean,
    payday_reminder_enabled boolean,
    move_ledger jsonb,
    compensation_policies jsonb,
    card_tips_paid_at_close boolean,
    client_updated_at timestamptz
  )
  where (select auth.uid()) is not null
  on conflict (user_id) do update set
    first_name = excluded.first_name,
    base_hourly_wage_cents = excluded.base_hourly_wage_cents,
    pay_frequency = excluded.pay_frequency,
    anchor_period_end = excluded.anchor_period_end,
    pay_delay_days = excluded.pay_delay_days,
    first_weekday = excluded.first_weekday,
    smart_nudge_enabled = excluded.smart_nudge_enabled,
    payday_reminder_enabled = excluded.payday_reminder_enabled,
    move_ledger = excluded.move_ledger,
    -- A client that does not know about policies must not clear them.
    compensation_policies = coalesce(
      excluded.compensation_policies,
      public.user_settings.compensation_policies
    ),
    -- Same rule for the payout setting: a build that does not know it sends
    -- no key, and must not reset a person's choice to the default.
    card_tips_paid_at_close = case when p_row ? 'card_tips_paid_at_close'
                                   then excluded.card_tips_paid_at_close
                                   else public.user_settings.card_tips_paid_at_close end,
    client_updated_at = excluded.client_updated_at
  returning public.user_settings.*;
$$;

revoke all on function public.import_user_settings(jsonb) from public, anon;
revoke all on function public.upsert_user_settings(jsonb) from public, anon;
grant execute on function public.import_user_settings(jsonb) to authenticated;
grant execute on function public.upsert_user_settings(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Tip share received, and the net that now includes it.
-- ---------------------------------------------------------------------------

alter table public.shifts
  add column if not exists tip_share_in_cents integer
    check (tip_share_in_cents is null or tip_share_in_cents >= 0);

comment on column public.shifts.tip_share_in_cents is
  'A tip share or pool payout the person received from co-workers, in cents. '
  'Null means not entered. Added to non_wage_earnings_cents; never counted '
  'as a tip the guest left.';

create or replace function private.legacy_non_wage_cents(
  p_cash integer, p_credit integer, p_receipt jsonb, p_tip_out integer,
  p_tip_share_in integer)
returns integer language sql immutable set search_path = '' as $$
  select greatest(-2147483648::numeric, least(2147483647::numeric,
      coalesce(p_cash, 0)::numeric + coalesce(p_credit, 0)::numeric
    + private.receipt_gratuity_cents(p_receipt)::numeric
    + coalesce(p_tip_share_in, 0)::numeric
    - coalesce(p_tip_out, 0)::numeric))::integer;
$$;

comment on function private.legacy_non_wage_cents(integer, integer, jsonb, integer, integer) is
  'cash + credit + gratuity + tip_share_in - tip_out, computed and clamped in '
  'numeric space: the SQL-callable twin of public.shifts.non_wage_earnings_cents'' '
  'generated expression. Pinned equal by supabase/tests/shift_deriver_test.sql '
  'and supabase/tests/tip_share_in_test.sql; changing either one alone is a '
  'money bug that no error message would report.';

create or replace function private.legacy_non_wage_cents(
  p_cash integer, p_credit integer, p_receipt jsonb, p_tip_out integer)
returns integer language sql immutable set search_path = '' as $$
  select private.legacy_non_wage_cents(p_cash, p_credit, p_receipt, p_tip_out, null);
$$;

comment on function private.legacy_non_wage_cents(integer, integer, jsonb, integer) is
  'The legacy fold''s net: the five-argument twin with no tip share, because '
  'a legacy tip_entries group cannot carry one.';

alter table public.shifts drop column non_wage_earnings_cents;

alter table public.shifts
  add column non_wage_earnings_cents integer generated always as (
    greatest(-2147483648::numeric, least(2147483647::numeric,
        cash_tips_cents::numeric + credit_tips_cents::numeric
      + private.receipt_gratuity_cents(receipt_metrics)::numeric
      + coalesce(tip_share_in_cents, 0)::numeric
      - coalesce(tip_out_cents, 0)::numeric))::integer) stored;

comment on column public.shifts.non_wage_earnings_cents is
  'cash + credit + gratuity + tip_share_in - tip_out, computed and clamped in '
  'numeric space. Deliberately has NO non-negativity check: a tip-out larger '
  'than the night''s tips is real and already representable.';

-- ---------------------------------------------------------------------------
-- 3. The device writer, carrying the share.
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
           p.receipt_metrics, p.note, p.recorded_at, p.client_updated_at
    from picked p
  ),
  written as (
    insert into public.shifts as s (
      id, user_id, work_date, shift_period,
      cash_tips_cents, credit_tips_cents, tip_out_cents, sales_cents,
      hours_worked, clock_in, clock_out, server_count, tip_share_in_cents,
      receipt_metrics, note, recorded_at, source, native_modified_at,
      client_updated_at
    )
    select
      d.id, p_user_id, d.work_date, d.shift_period,
      d.cash_tips_cents, d.credit_tips_cents, d.tip_out_cents, d.sales_cents,
      d.hours_worked, d.clock_in, d.clock_out, d.server_count, d.tip_share_in_cents,
      d.receipt_metrics, d.note, d.recorded_at, 'device', v_now,
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


revoke all on function private.write_shifts(uuid, jsonb) from public, anon, authenticated;
