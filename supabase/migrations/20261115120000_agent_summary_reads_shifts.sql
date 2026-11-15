-- The agent API's `GET /v1/summary` totals its `shifts` block from
-- public.shifts, the same rows `GET /v1/shifts` lists.
--
-- THE PROBLEM. 20260904125000 built that block from public.tip_entries. The
-- current app writes a shift through upsert_shifts into public.shifts and
-- never writes a legacy row for it, so every night logged or edited on it
-- was missing from `count` and from every total, and the summary disagreed
-- with the listing beside it. The function also carried its own copy of the
-- gratuity owner rule and the credit-then-cash detail rule, and both differ
-- from private.derive_shifts: the deriver ranks the receipt owner
-- object-first, and its own comment calls ranking on
-- `receipt_metrics is not null`, as this function did, a money bug.
--
-- THE FIX reads the stored row, as 20260918140000 did for the listing. The
-- money rules live once, in the generated columns `gratuity_fees_cents` and
-- `non_wage_earnings_cents`; this sums them and restates no rule. The one
-- piece of arithmetic is `gross_tip_earnings_cents`, the net with the
-- tip-out added back: the presentation `shiftResponse` in
-- supabase/functions/payday-api/index.ts gives one shift, so the block and
-- the sum of the listed shifts agree.
--
-- Keys. Every key the block had keeps its name. `count` is live shifts by
-- `work_date`, inclusive, with the listing's deleted rule. `tip_entry_count`
-- is the number of legacy rows those shifts were converted from, 0 for a
-- shift the current app wrote. `tip_share_in_cents` is new: the net now
-- includes the share received, and a reader needs it to reconcile the block.
-- No wage is included; `data.earnings` in the response carries the
-- wage-inclusive engine figure.
--
-- The `paychecks` block is unchanged: live paycheck_records by `period_end`.

create or replace function public.payday_agent_summary(
  p_user_id uuid,
  p_start_date date default null,
  p_end_date date default null
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with shift_summary as (
    select
      count(*)::bigint as shift_count,
      coalesce(sum(cardinality(s.legacy_entry_ids)), 0)::bigint as tip_entry_count,
      coalesce(sum(s.cash_tips_cents), 0)::bigint as cash_voluntary_tips_cents,
      coalesce(sum(s.credit_tips_cents), 0)::bigint as credit_voluntary_tips_cents,
      coalesce(sum(s.gratuity_fees_cents), 0)::bigint as gratuity_cents,
      coalesce(sum(s.tip_share_in_cents), 0)::bigint as tip_share_in_cents,
      coalesce(sum(s.tip_out_cents), 0)::bigint as tip_out_cents,
      coalesce(sum(s.non_wage_earnings_cents), 0)::bigint as net_tip_earnings_cents,
      coalesce(sum(s.sales_cents), 0)::bigint as sales_cents,
      coalesce(sum(s.hours_worked), 0)::numeric as hours_worked
    from public.shifts as s
    where s.user_id = p_user_id
      and s.deleted_at is null
      and (p_start_date is null or s.work_date >= p_start_date)
      and (p_end_date is null or s.work_date <= p_end_date)
  ),
  paycheck_summary as (
    select
      count(*)::bigint as paycheck_count,
      coalesce(sum(paycheck.paid_tips_cents), 0)::bigint as paid_tips_cents,
      coalesce(sum(paycheck.gross_pay_cents), 0)::bigint as gross_pay_cents,
      coalesce(sum(paycheck.net_pay_cents), 0)::bigint as net_pay_cents,
      coalesce(sum(paycheck.taxes_cents), 0)::bigint as taxes_cents
    from public.paycheck_records as paycheck
    where paycheck.user_id = p_user_id
      and paycheck.deleted_at is null
      and (p_start_date is null or paycheck.period_end >= p_start_date)
      and (p_end_date is null or paycheck.period_end <= p_end_date)
  )
  select jsonb_build_object(
    'shifts', jsonb_build_object(
      'count', shifts.shift_count,
      'tip_entry_count', shifts.tip_entry_count,
      'cash_voluntary_tips_cents', shifts.cash_voluntary_tips_cents,
      'credit_voluntary_tips_cents', shifts.credit_voluntary_tips_cents,
      'gratuity_cents', shifts.gratuity_cents,
      'tip_share_in_cents', shifts.tip_share_in_cents,
      'gross_tip_earnings_cents',
        shifts.net_tip_earnings_cents + shifts.tip_out_cents,
      'tip_out_cents', shifts.tip_out_cents,
      'net_tip_earnings_cents', shifts.net_tip_earnings_cents,
      'sales_cents', shifts.sales_cents,
      'hours_worked', shifts.hours_worked
    ),
    'paychecks', jsonb_build_object(
      'count', paychecks.paycheck_count,
      'paid_tips_cents', paychecks.paid_tips_cents,
      'gross_pay_cents', paychecks.gross_pay_cents,
      'net_pay_cents', paychecks.net_pay_cents,
      'taxes_cents', paychecks.taxes_cents
    )
  )
  from shift_summary as shifts
  cross join paycheck_summary as paychecks;
$$;

revoke all on function public.payday_agent_summary(uuid, date, date)
  from public, anon, authenticated;

grant execute on function public.payday_agent_summary(uuid, date, date)
  to service_role;

comment on function public.payday_agent_summary(uuid, date, date) is
  'Shift and paycheck totals for the agent API. The shifts block sums the '
  'stored and generated columns of the live public.shifts rows that '
  'payday_agent_recent_shifts lists, so it restates no money rule; it '
  'includes no wage.';
