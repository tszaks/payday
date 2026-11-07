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

-- ---------------------------------------------------------------------------
-- 4. The deriver compares legacy money against legacy money.
-- ---------------------------------------------------------------------------
-- Found by review before this file was ever applied. The deriver's conflict
-- arms (1, 2, 4a, 4b in private.derive_shifts) compare a CLOSED shift's
-- generated net against the net its legacy rows would produce, to report a
-- disagreement between an old build and a device edit. The generated net now
-- includes tip_share_in_cents, which no legacy row can carry, so a closed
-- shift holding a share would report a conflict exactly the size of the
-- share every time an old build touched one of its legacy rows, and
-- unconverted_legacy_cents would show that share as money "not converted".
--
-- The fix is one helper and a redefinition of the deriver that uses it in
-- those four places and nowhere else: the legacy-comparable part of a shift's
-- net is its net without the share. The conservation sum at the end of the
-- function is over OPEN shifts only, and an open shift can never carry a
-- share because private.write_shifts, the only writer of the column, stamps
-- native_modified_at on every row it touches. That line is unchanged.
--
-- The function body is otherwise the one applied by
-- 20260917200000_add_shift_deriver.sql, copied whole because a plpgsql body
-- cannot be patched in place. Pinned by supabase/tests/tip_share_in_test.sql
-- (a share-bearing closed shift re-folded with unchanged legacy money records
-- no conflict; with changed legacy money it records one, share excluded) on
-- top of the existing supabase/tests/shift_deriver_test.sql, which must keep
-- passing unchanged.

create or replace function private.shift_legacy_net_cents(s public.shifts)
returns integer language sql immutable set search_path = '' as $$
  select s.non_wage_earnings_cents - coalesce(s.tip_share_in_cents, 0);
$$;

comment on function private.shift_legacy_net_cents(public.shifts) is
  'The part of a shift''s net that its legacy tip_entries rows could have '
  'produced: non_wage_earnings_cents without tip_share_in_cents, which no '
  'legacy row carries. The ONLY figure the deriver may compare against '
  'private.legacy_non_wage_cents(...) of a legacy group; comparing the '
  'generated net itself reports a false conflict the size of the share.';

create or replace function private.derive_shifts(
  p_user_id uuid, p_group_keys uuid[]
) returns table (touched_count integer, wrote_count integer,
                 source_cents bigint, shift_cents bigint, conflicts integer)
language plpgsql security definer set search_path = '' as $fn$
declare
  v_keys uuid[];
  v_grouped jsonb;
  v_rows integer := 0;
  v_wrote integer := 0;
  v_conflicts integer := 0;
begin
  touched_count := 0;
  wrote_count := 0;
  source_cents := 0;
  shift_cents := 0;
  conflicts := 0;

  -- Deduplicated and sorted: the callers pass the union of old and new group
  -- keys and may repeat one, and a sorted key list is what keeps two
  -- concurrent sessions from taking row locks in opposite orders.
  v_keys := array(
    select distinct k
    from unnest(coalesce(p_group_keys, '{}'::uuid[])) as k
    where k is not null
    order by k);

  -- An empty or junk invocation is a no-op with defined output, never an
  -- error: the trigger calls this with whatever the transition tables held.
  if p_user_id is null or cardinality(v_keys) = 0 then
    return next;
    return;
  end if;

  touched_count := cardinality(v_keys);

  perform set_config('payday.folding', 'on', true);

  -- -------------------------------------------------------------------------
  -- ONE evaluation of the grouping chain.
  --
  -- metrics_rank is OBJECT-FIRST, then credit, then id. Ranking on
  -- `receipt_metrics is not null` instead is a measured $42.00 money bug: a
  -- non-object payload ("hi") is not null, so it won rank 1, no subtraction
  -- happened on any row, and the object payload's gratuity was then ADDED by
  -- the generated column without ever being SUBTRACTED -- cash 5000 /
  -- credit 2000 / gratuity 4200 / non-wage 11200 where the answer is
  -- 800 / 2000 / 4200 / 7000. Object-first is also what keeps the gratuity
  -- OWNER and the group's STORED payload the same row by construction.
  --
  -- The `filter (where jsonb_typeof(...) = 'object')` on the payload
  -- aggregate stays: it is what keeps a group in which NO row holds an
  -- object payload from storing a scalar and violating
  -- shifts_receipt_is_object.
  --
  -- detail_rank is credit-first then id. Every scalar is resolved as the
  -- first NON-NULL in that order across ALL of a group's rows: a tip-out
  -- duplicated onto both rows of a group must subtract once, and a value
  -- sitting on a group's SECOND credit row must not be invisible.
  --
  -- On the scope of the claim "this is a port of ShiftDetails.resolve".
  -- When this file was first written it was NOT a port; it was the correct
  -- rule next to a different one. ShiftDetails.resolve was
  -- `first{kind == .credit} ?? first{kind == .cash}` PER FIELD, with no rank
  -- and no visibility of a second row of either kind, and for a group of
  -- exactly one cash row plus one credit row the two rules agree to the cent
  -- -- which is why N1/N3/N4/N5/L1/L2/P6 all passed under both and none of
  -- them could see it. MEASURED on the real shipped TipBreakdown over a
  -- four-row group (fixture P7: cash 5000 a1, credit 2000 tip-out 1000 b1,
  -- cash 1000 c1, credit 3000 carrying a v1 receipt with gratuity 4200 d1),
  -- Swift returned TWO different answers for identical data depending on
  -- array order -- 6000/5000/0/1000/10000 in 12 of the 24 orderings and
  -- 6000/2000/4200/0/12200 in the other 12 -- and this fold agreed with
  -- neither: it folds that group to 6000/2000/4200/1000/11200.
  --
  -- Conservation cannot catch that class of disagreement at all. Both sides
  -- of the check are THIS fold's own grouping, so P7 returns
  -- source_cents = shift_cents = 11200 with conflicts = 0 while both shipped
  -- readers are wrong. Only a pinned fixture catches it, which is what P7 is.
  --
  -- The ranking was therefore ported INTO Swift rather than the reverse,
  -- because the fold's answer is the correct one: ShiftDetails now carries
  -- detailRanked / metricsRanked / metricsOwner, resolves every scalar as the
  -- first non-null in detail-rank order across all rows, and writes onto
  -- detail rank 1. The same five numbers are literals in
  -- supabase/tests/shift_deriver_test.sql (P7) and in
  -- PaydayTests/ShiftGroupRankingParityTests.swift, so neither side can move
  -- alone. One asymmetry remains and is deliberate: this file ranks on
  -- `jsonb_typeof(...) = 'object'`, while Swift can only see a payload that
  -- DECODES as ShiftReceiptMetrics, so an object-but-undecodable payload
  -- outranks on this side and is nil on that one. The sanitizer below is what
  -- confines it to un-folded legacy rows, and
  -- ShiftRecord.receiptPayloadIsUnreadable is the surface that reports it.
  --
  -- The agent API's groupShifts (supabase/functions/payday-api/index.ts) is
  -- still a THIRD reader of the legacy rows with the old first-credit rule
  -- and a max(work_date) that correction D1 already names as wrong. It is
  -- deliberately NOT patched here: its slice replaces that function with a
  -- read of public.shifts, and porting a ranking into code scheduled for
  -- deletion would be the fourth copy of a money rule, not the second.
  --
  -- min(work_date), never max: ShiftDays and StatsEngine use min, and the
  -- agent API's groupShifts reduced to the largest, which is correction D1.
  --
  -- The v1-to-v2 receipt conversion ports the READ path (TipBreakdown.total:
  -- resolve the owner, then max(0, amount - gratuity) on THAT ROW ONLY), not
  -- LogTipSheet.gratuityFeesBinding's edit path, which moves the whole
  -- folded gratuity to the other kind. On the N4 shape that difference is
  -- $22.00 and a different cash-versus-credit split, and the split is what
  -- drives the paycheck comparison.
  --
  -- Sums widen to bigint and then clamp into int4: amount_cents is int4, a
  -- junk account can overflow a group sum, and an overflow is a statement
  -- abort, which here is a rejected 1.0 write.
  --
  -- The scope filter is inside `source`, so it precedes the group by. Two
  -- shifts on one work_date (lunch and dinner, or a late legacy row next to a
  -- native shift) are different group keys, and deriving one of them must
  -- never read the other's rows.
  -- -------------------------------------------------------------------------
  v_grouped := (
    select coalesce(jsonb_agg(to_jsonb(g) order by g.id), '[]'::jsonb)
    from (
      with source as (
        select e.*, private.legacy_group_key(e.shift_id, e.work_date) as group_key
        from public.tip_entries e
        where e.user_id = p_user_id
          and private.legacy_group_key(e.shift_id, e.work_date) = any(v_keys)
          and e.deleted_at is null
      ),
      ranked as (
        select s.*,
          -- `nulls last` is load-bearing and was MEASURED, not reasoned.
          -- jsonb_typeof(NULL) is NULL, so `jsonb_typeof(receipt_metrics) =
          -- 'object'` is NULL on a row with no payload at all -- not false --
          -- and `order by ... desc` defaults to NULLS FIRST. Without `nulls
          -- last` a row carrying NO receipt outranks the row carrying the
          -- object receipt, which is the commonest real shape there is (one
          -- scanned row, one hand-entered row) and is fixture N4 exactly. The
          -- owner then resolves to the payload-less row, its gratuity reads 0,
          -- NOTHING is subtracted, and the object payload's gratuity is still
          -- ADDED by the generated column: N4 folds to non-wage 10200 instead
          -- of 8200, $20.00 of money that does not exist, on one shift. That is
          -- the identical failure mode the object-first ranking exists to fix,
          -- reintroduced by a NULL sort default. Pinned by
          -- N4_theNullsFirstRankingInventsTwentyDollars.
          row_number() over (partition by s.group_key order by
            (jsonb_typeof(s.receipt_metrics) = 'object') desc nulls last,
            (s.kind = 'credit') desc, s.id asc) as metrics_rank,
          row_number() over (partition by s.group_key order by
            (s.kind = 'credit') desc, s.id asc) as detail_rank
        from source s
      ),
      owned as (
        select r.*,
          case when r.metrics_rank = 1
               then private.receipt_gratuity_cents(r.receipt_metrics)
               else 0 end as owner_gratuity_cents,
          case when r.metrics_rank = 1
                    and jsonb_typeof(r.receipt_metrics -> 'earningsSchemaVersion') = 'number'
               then (r.receipt_metrics ->> 'earningsSchemaVersion')::numeric
               else 1 end as schema_version
        from ranked r
      ),
      grouped as (
        select
          o.group_key as id,
          min(o.work_date) as work_date,
          (array_agg(o.shift_period order by o.detail_rank)
             filter (where o.shift_period is not null))[1] as shift_period,
          least(greatest(0, sum(case when o.kind = 'cash'
            then case when o.schema_version >= 2 then o.amount_cents
                      else greatest(0, o.amount_cents - o.owner_gratuity_cents) end
            else 0 end)::bigint), 2147483647)::integer as cash_tips_cents,
          least(greatest(0, sum(case when o.kind = 'credit'
            then case when o.schema_version >= 2 then o.amount_cents
                      else greatest(0, o.amount_cents - o.owner_gratuity_cents) end
            else 0 end)::bigint), 2147483647)::integer as credit_tips_cents,
          (array_agg(o.tip_out_cents order by o.detail_rank)
             filter (where o.tip_out_cents is not null))[1] as tip_out_cents,
          (array_agg(o.sales_cents order by o.detail_rank)
             filter (where o.sales_cents is not null))[1] as sales_cents,
          (array_agg(o.hours_worked order by o.detail_rank)
             filter (where o.hours_worked is not null))[1] as hours_worked,
          (array_agg(o.clock_in order by o.detail_rank)
             filter (where o.clock_in is not null))[1] as clock_in,
          (array_agg(o.clock_out order by o.detail_rank)
             filter (where o.clock_out is not null))[1] as clock_out,
          (array_agg(o.server_count order by o.detail_rank)
             filter (where o.server_count is not null))[1] as server_count,
          -- The sanitizer. earningsSchemaVersion is relabelled to 2 because
          -- the subtraction above has just made the payload v2, and
          -- gratuityFeesCents is rewritten through the SAME helper the
          -- arithmetic used (create_missing = false: never invent the key).
          -- Both halves exist so the STORED payload decodes as
          -- ShiftReceiptMetrics on the device: that struct decodes
          -- earningsSchemaVersion and gratuityFeesCents as Int?, so a payload
          -- carrying "1", true, "42" or 1234.6 fails to decode AS A WHOLE,
          -- ShiftRecord.receiptPayloadIsUnreadable fires, and that shift is
          -- excluded from the sync push set and reported forever, because the
          -- server keeps re-folding the same value. jsonb_set on a
          -- non-object raises ("cannot set path in scalar"), which is why the
          -- CASE guard is not optional.
          (array_agg(
             case when jsonb_typeof(o.receipt_metrics) = 'object'
                  then jsonb_set(
                         jsonb_set(o.receipt_metrics,
                                   '{earningsSchemaVersion}', '2'::jsonb, true),
                         '{gratuityFeesCents}',
                         to_jsonb(private.receipt_gratuity_cents(o.receipt_metrics)),
                         false)
                  else null end
             order by o.metrics_rank)
             filter (where jsonb_typeof(o.receipt_metrics) = 'object'))[1] as receipt_metrics,
          (array_agg(o.note order by o.detail_rank)
             filter (where o.note is not null))[1] as note,
          (array_agg(o.recorded_at order by o.detail_rank)
             filter (where o.recorded_at is not null))[1] as recorded_at,
          array_agg(distinct o.id order by o.id) as legacy_entry_ids,
          max(o.client_updated_at) as source_max_updated_at
        from owned o
        group by o.group_key
      )
      select * from grouped
    ) g);

  -- -------------------------------------------------------------------------
  -- ARM 3: the un-delete arm, BEFORE arm 1 so the reopened shift is then
  -- filled by arm 1's CASE.
  --
  -- A legacy un-delete is a first-class live path on both writers:
  -- RemoteTipEntry(entry:userID:) hardcodes deletedAt = nil, and
  -- upsert_tip_entries lost its staleness guard in 20260904134500, so EVERY
  -- 1.0 push of a locally present row writes deleted_at = null over a server
  -- tombstone. Without this arm the source row comes back, its money is back
  -- in tip_entries, and the shift stays tombstoned forever: the new build
  -- shows nothing while the old build shows the night.
  --
  -- Only a tombstone the fold itself set ('converted') on a shift no human
  -- has touched is reopened. A user deletion is never cleared.
  -- -------------------------------------------------------------------------
  update public.shifts s
     set deleted_at = null, deleted_reason = null
   where s.user_id = p_user_id
     and s.id = any(v_keys)
     and s.deleted_reason = 'converted'
     and s.native_modified_at is null
     and exists (select 1 from jsonb_to_recordset(v_grouped) as g(id uuid)
                  where g.id = s.id);

  -- -------------------------------------------------------------------------
  -- ARM 1: the upsert of derived groups.
  --
  -- deleted_at is guarded PER COLUMN, provenance is written
  -- UNCONDITIONALLY, and the conflict predicate never filters on deleted_at.
  -- There is NO `where` clause on the DO UPDATE and there may never be one:
  -- measured on PG 17, `on conflict (user_id,id) do update ... where
  -- deleted_at is null` against a deleted target reports INSERT 0 0 and
  -- leaves the row untouched with no error, so the arriving legacy id is
  -- never added to any legacy_entry_ids and this statement -- which runs
  -- inside a shipped 1.0 build's transaction -- silently drops that build's
  -- write. A CASE per column keeps the partition TOTAL over a closed target.
  -- scripts/design-lint.sh fails the build on `on conflict` combined with
  -- `where` in any statement touching public.shifts.
  --
  -- deleted_at is never written here, so nothing resurrects. source is never
  -- rewritten, so a native shift stays 'device'.
  --
  -- unconverted_legacy_cents is abs(), not greatest(0, ...): it means "the
  -- magnitude of the latest disagreement", never "unconverted money".
  -- Measured on a closed shift at 6000, a DOWNWARD correction from an old
  -- build (6000 to 4000) gave greatest(0, 4000-6000) = 0 and Data health
  -- showed nothing at all, and downward is the common shape of a correction.
  -- It is never accumulated: a repeated re-push of the same row would
  -- inflate it without bound. The honest account-wide figure comes from
  -- public.shift_legacy_conflicts (arm 4).
  -- -------------------------------------------------------------------------
  insert into public.shifts (
    user_id, id, work_date, shift_period, cash_tips_cents, credit_tips_cents,
    tip_out_cents, sales_cents, hours_worked, clock_in, clock_out, server_count,
    receipt_metrics, note, recorded_at, source, legacy_entry_ids,
    legacy_source_max_updated_at, converted_at, client_updated_at)
  select p_user_id, g.id, g.work_date, g.shift_period,
         g.cash_tips_cents, g.credit_tips_cents, g.tip_out_cents, g.sales_cents,
         g.hours_worked, g.clock_in, g.clock_out, g.server_count,
         g.receipt_metrics, g.note, g.recorded_at, 'migration', g.legacy_entry_ids,
         g.source_max_updated_at, statement_timestamp(),
         least(g.source_max_updated_at, statement_timestamp())
  from jsonb_to_recordset(v_grouped) as g(
    id uuid, work_date date, shift_period text,
    cash_tips_cents integer, credit_tips_cents integer,
    tip_out_cents integer, sales_cents integer, hours_worked numeric,
    clock_in timestamptz, clock_out timestamptz, server_count integer,
    receipt_metrics jsonb, note text, recorded_at timestamptz,
    legacy_entry_ids uuid[], source_max_updated_at timestamptz)
  on conflict (user_id, id) do update set
    work_date = case when private.shift_is_open_to_fold(public.shifts.*)
                     then excluded.work_date else public.shifts.work_date end,
    shift_period = case when private.shift_is_open_to_fold(public.shifts.*)
                        then excluded.shift_period else public.shifts.shift_period end,
    cash_tips_cents = case when private.shift_is_open_to_fold(public.shifts.*)
                           then excluded.cash_tips_cents else public.shifts.cash_tips_cents end,
    credit_tips_cents = case when private.shift_is_open_to_fold(public.shifts.*)
                             then excluded.credit_tips_cents else public.shifts.credit_tips_cents end,
    tip_out_cents = case when private.shift_is_open_to_fold(public.shifts.*)
                         then excluded.tip_out_cents else public.shifts.tip_out_cents end,
    sales_cents = case when private.shift_is_open_to_fold(public.shifts.*)
                       then excluded.sales_cents else public.shifts.sales_cents end,
    hours_worked = case when private.shift_is_open_to_fold(public.shifts.*)
                        then excluded.hours_worked else public.shifts.hours_worked end,
    clock_in = case when private.shift_is_open_to_fold(public.shifts.*)
                    then excluded.clock_in else public.shifts.clock_in end,
    clock_out = case when private.shift_is_open_to_fold(public.shifts.*)
                     then excluded.clock_out else public.shifts.clock_out end,
    server_count = case when private.shift_is_open_to_fold(public.shifts.*)
                        then excluded.server_count else public.shifts.server_count end,
    receipt_metrics = case when private.shift_is_open_to_fold(public.shifts.*)
                           then excluded.receipt_metrics else public.shifts.receipt_metrics end,
    note = case when private.shift_is_open_to_fold(public.shifts.*)
                then excluded.note else public.shifts.note end,
    recorded_at = case when private.shift_is_open_to_fold(public.shifts.*)
                       then excluded.recorded_at else public.shifts.recorded_at end,
    client_updated_at = case when private.shift_is_open_to_fold(public.shifts.*)
                             then excluded.client_updated_at else public.shifts.client_updated_at end,
    converted_at = statement_timestamp(),
    legacy_entry_ids = excluded.legacy_entry_ids,
    legacy_source_max_updated_at = excluded.legacy_source_max_updated_at,
    unconverted_legacy_cents = case
      when private.shift_is_open_to_fold(public.shifts.*) then 0
      else least(2147483647::numeric, abs(
             private.legacy_non_wage_cents(
               excluded.cash_tips_cents, excluded.credit_tips_cents,
               excluded.receipt_metrics, excluded.tip_out_cents)::numeric
             - private.shift_legacy_net_cents(public.shifts.*)::numeric))::integer end;

  get diagnostics v_rows = row_count;
  v_wrote := v_rows;

  -- -------------------------------------------------------------------------
  -- ARM 4a: the conflict record for a group whose money arm 1 declined
  -- because the shift is closed and the numbers actually disagree. Arm 1
  -- cannot have changed either side of this comparison on a closed shift, so
  -- reading it here still reads the pre-arrival value.
  -- -------------------------------------------------------------------------
  insert into public.shift_legacy_conflicts
    (user_id, shift_id, detected_at, shift_cents_before, legacy_cents_after)
  select p_user_id, g.id, statement_timestamp(), private.shift_legacy_net_cents(s),
         private.legacy_non_wage_cents(g.cash_tips_cents, g.credit_tips_cents,
                                       g.receipt_metrics, g.tip_out_cents)
  from jsonb_to_recordset(v_grouped) as g(
         id uuid, cash_tips_cents integer, credit_tips_cents integer,
         tip_out_cents integer, receipt_metrics jsonb)
  join public.shifts s on s.user_id = p_user_id and s.id = g.id
  where not private.shift_is_open_to_fold(s)
    and private.shift_legacy_net_cents(s) <> private.legacy_non_wage_cents(
          g.cash_tips_cents, g.credit_tips_cents, g.receipt_metrics, g.tip_out_cents);

  get diagnostics v_rows = row_count;
  v_conflicts := v_conflicts + v_rows;

  -- -------------------------------------------------------------------------
  -- ARM 2: the emptied-group arm, in TWO statements, because provenance and
  -- money must be released independently.
  --
  -- A `group by` over an empty source emits nothing. Measured: soft-deleting
  -- one row of a two-row group re-derives correctly; soft-deleting the LAST
  -- live row leaves the shift at cash 5000 with a stale provenance id,
  -- PERMANENTLY -- the user deleted the money on their old phone and the new
  -- build keeps counting it. Under this shape the arm fires on ordinary 1.0
  -- deletions, continuously.
  --
  -- ARM 2b (money and tombstone) runs BEFORE 2a (provenance), so
  -- shift_is_open_to_fold is evaluated against the pre-release row.
  -- -------------------------------------------------------------------------
  update public.shifts s
     set cash_tips_cents = 0, credit_tips_cents = 0,
         tip_out_cents = null, sales_cents = null, hours_worked = null,
         clock_in = null, clock_out = null, server_count = null,
         receipt_metrics = null,
         deleted_at = coalesce(s.deleted_at, statement_timestamp()),
         deleted_reason = coalesce(s.deleted_reason, 'converted')
   where s.user_id = p_user_id
     and s.id = any(v_keys)
     and not exists (select 1 from jsonb_to_recordset(v_grouped) as g(id uuid)
                      where g.id = s.id)
     and private.shift_is_open_to_fold(s);

  -- -------------------------------------------------------------------------
  -- ARM 2a: release provenance. UNCONDITIONAL. Closed and deleted shifts
  -- included.
  --
  -- With the single gated statement an earlier draft wrote, a closed shift
  -- whose sources move away or get tombstoned keeps naming rows it no longer
  -- derives from, forever, and that one stranded claim causes all three of:
  -- the night displayed twice on two different dates (and 5.5's duplicate
  -- detector groups by work_date, so two different dates are never
  -- reported); the conservation duplicate count returning 1 forever; and
  -- payday_unmigrated_tip_row_count() never returning 0, which makes the
  -- client re-invoke the one-shot on every pass forever.
  --
  -- The watermark is computed PER KEY over every row of that key including
  -- tombstoned ones, which is what the column comment on
  -- legacy_source_max_updated_at says the column means. The design printed a
  -- single invocation-wide scalar here; per key is strictly narrower and
  -- cannot be worse, and a cross-key max would make the column lie. It is
  -- informational either way, because this statement empties
  -- legacy_entry_ids, so the 5.2 predicate arms that read the watermark
  -- cannot apply to this shift until it names a row again.
  -- -------------------------------------------------------------------------
  update public.shifts s
     set legacy_entry_ids = '{}',
         legacy_source_max_updated_at = (
           select max(e.client_updated_at) from public.tip_entries e
            where e.user_id = p_user_id
              and private.legacy_group_key(e.shift_id, e.work_date) = s.id),
         -- The folded value of an emptied group IS zero, so the magnitude of
         -- the latest disagreement is abs(0 - this shift's net). One
         -- expression covers all three cases: an OPEN shift arm 2b just
         -- released reads 0, a CLOSED shift that kept its money reads that
         -- money, and a user-deleted shift likewise. The design's printed arm
         -- 2a did not write this column at all, which left a CLOSED emptied
         -- shift displaying a STALE magnitude from some earlier arrival -- the
         -- one number Data health puts in front of the person in exactly this
         -- case. Never accumulated: this is an absolute assignment.
         unconverted_legacy_cents =
           least(2147483647::numeric, abs(private.shift_legacy_net_cents(s)::numeric))::integer,
         converted_at = statement_timestamp()
   where s.user_id = p_user_id
     and s.id = any(v_keys)
     and not exists (select 1 from jsonb_to_recordset(v_grouped) as g(id uuid)
                      where g.id = s.id)
     and array_length(s.legacy_entry_ids, 1) > 0;

  -- -------------------------------------------------------------------------
  -- ARM 4b: the emptied-and-closed case, which has no grouped row. A CLOSED
  -- emptied shift keeps its money -- the user's own edit wins -- and the
  -- disagreement is recorded here rather than silently retained.
  -- -------------------------------------------------------------------------
  insert into public.shift_legacy_conflicts
    (user_id, shift_id, detected_at, shift_cents_before, legacy_cents_after)
  select p_user_id, s.id, statement_timestamp(), private.shift_legacy_net_cents(s), 0
  from public.shifts s
  where s.user_id = p_user_id
    and s.id = any(v_keys)
    and not exists (select 1 from jsonb_to_recordset(v_grouped) as g(id uuid)
                     where g.id = s.id)
    and not private.shift_is_open_to_fold(s)
    and private.shift_legacy_net_cents(s) <> 0;

  get diagnostics v_rows = row_count;
  v_conflicts := v_conflicts + v_rows;

  -- -------------------------------------------------------------------------
  -- The conservation numbers. RECORDED, never raised, and scoped so that
  -- equality is a real invariant rather than an aspiration.
  --
  -- Account-wide conservation is permanently unsatisfiable once one native
  -- shift, one post-conversion edit or one deletion exists, and scoping by
  -- legacy provenance alone is still not enough, because provenance is
  -- written unconditionally onto a CLOSED shift whose money the fold
  -- deliberately declined. So CLOSED shifts are excluded from BOTH sides:
  -- the comparison is over exactly the population where equality must hold,
  -- shifts nobody has touched derived from rows nobody has moved.
  --
  -- The "in" side is per GROUP, not per row, because the tip-out is resolved
  -- once per group and summing it per row would double-subtract it.
  -- -------------------------------------------------------------------------
  select coalesce(sum(private.legacy_non_wage_cents(
           g.cash_tips_cents, g.credit_tips_cents, g.receipt_metrics, g.tip_out_cents))::bigint, 0)
    into source_cents
  from jsonb_to_recordset(v_grouped) as g(
         id uuid, cash_tips_cents integer, credit_tips_cents integer,
         tip_out_cents integer, receipt_metrics jsonb)
  where not exists (
    select 1 from public.shifts s
     where s.user_id = p_user_id and s.id = g.id
       and (not private.shift_is_open_to_fold(s)
            or s.client_updated_at > statement_timestamp()));

  select coalesce(sum(s.non_wage_earnings_cents)::bigint, 0)
    into shift_cents
  from public.shifts s
  where s.user_id = p_user_id
    and s.id = any(v_keys)
    and array_length(s.legacy_entry_ids, 1) > 0
    and s.deleted_at is null
    and s.native_modified_at is null
    and s.client_updated_at <= statement_timestamp();

  wrote_count := v_wrote;
  conflicts := v_conflicts;

  perform set_config('payday.folding', 'off', true);
  return next;
  return;

exception
  -- 57014 (statement_timeout) and assert_failure are NOT caught by OTHERS,
  -- and 57014 is the abort class most likely to hit a 500-row 1.0 batch, so
  -- both get named arms. Each clears the GUC and re-raises: the CALLER
  -- records the failure and queues the keys (S4), because only the caller
  -- knows whether it is the trigger, the one-shot, or a future writer.
  --
  -- Measured on PG 17.11: catching in the caller also rolls the subtransaction
  -- back, which reverts this set_config on its own, so the clear here is belt
  -- rather than braces. It ships anyway, because the day a handler above
  -- stops re-raising, a GUC left at 'on' would silently freeze `version` on
  -- every later shift UPDATE in that transaction, and that is invisible at
  -- the call site that breaks.
  when query_canceled then
    perform set_config('payday.folding', 'off', true);
    raise;
  when assert_failure then
    perform set_config('payday.folding', 'off', true);
    raise;
  when others then
    perform set_config('payday.folding', 'off', true);
    raise;
end;
$fn$;

