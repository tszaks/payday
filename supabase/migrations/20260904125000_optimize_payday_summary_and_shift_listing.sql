-- Keep aggregate and semantic-shift reads inside Postgres. The API previously
-- downloaded every matching row into the Edge Function just to total or trim
-- it, which made response cost grow with a user's entire history.

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
  with tip_source as (
    select
      entry.*,
      coalesce(entry.shift_id, entry.id) as semantic_shift_id,
      row_number() over (
        partition by coalesce(entry.shift_id, entry.id)
        order by
          (entry.receipt_metrics is not null) desc,
          (entry.kind = 'credit') desc,
          entry.id asc
      ) as metrics_rank
    from public.tip_entries as entry
    where entry.user_id = p_user_id
      and entry.deleted_at is null
      and (p_start_date is null or entry.work_date >= p_start_date)
      and (p_end_date is null or entry.work_date <= p_end_date)
  ),
  tip_facts as (
    select
      source.*,
      case
        when source.metrics_rank = 1
          and jsonb_typeof(source.receipt_metrics -> 'gratuityFeesCents') = 'number'
        then (source.receipt_metrics ->> 'gratuityFeesCents')::bigint
        else 0
      end as gratuity_cents,
      case
        when source.metrics_rank = 1
          and jsonb_typeof(source.receipt_metrics -> 'earningsSchemaVersion') = 'number'
        then (source.receipt_metrics ->> 'earningsSchemaVersion')::numeric
        else 1
      end as earnings_schema_version
    from tip_source as source
  ),
  shift_facts as (
    select
      facts.semantic_shift_id,
      count(*)::bigint as tip_entry_count,
      sum(
        case when facts.kind = 'cash' then
          case when facts.earnings_schema_version >= 2
            then facts.amount_cents::bigint
            else greatest(0::bigint, facts.amount_cents::bigint - facts.gratuity_cents)
          end
        else 0 end
      ) as cash_voluntary_tips_cents,
      sum(
        case when facts.kind = 'credit' then
          case when facts.earnings_schema_version >= 2
            then facts.amount_cents::bigint
            else greatest(0::bigint, facts.amount_cents::bigint - facts.gratuity_cents)
          end
        else 0 end
      ) as credit_voluntary_tips_cents,
      sum(facts.gratuity_cents)::bigint as gratuity_cents,
      sum(
        case when facts.earnings_schema_version >= 2
          then facts.amount_cents::bigint + facts.gratuity_cents
          else facts.amount_cents::bigint
        end
      )::bigint as gross_tip_earnings_cents,
      coalesce(
        (array_agg(facts.tip_out_cents order by facts.id)
          filter (where facts.kind = 'credit' and facts.tip_out_cents is not null))[1],
        (array_agg(facts.tip_out_cents order by facts.id)
          filter (where facts.kind = 'cash' and facts.tip_out_cents is not null))[1],
        0
      )::bigint as tip_out_cents,
      coalesce(
        (array_agg(facts.sales_cents order by facts.id)
          filter (where facts.kind = 'credit' and facts.sales_cents is not null))[1],
        (array_agg(facts.sales_cents order by facts.id)
          filter (where facts.kind = 'cash' and facts.sales_cents is not null))[1],
        0
      )::bigint as sales_cents,
      coalesce(
        (array_agg(facts.hours_worked order by facts.id)
          filter (where facts.kind = 'credit' and facts.hours_worked is not null))[1],
        (array_agg(facts.hours_worked order by facts.id)
          filter (where facts.kind = 'cash' and facts.hours_worked is not null))[1],
        0
      )::numeric as hours_worked
    from tip_facts as facts
    group by facts.semantic_shift_id
  ),
  tip_summary as (
    select
      count(*)::bigint as shift_count,
      coalesce(sum(shift.tip_entry_count), 0)::bigint as tip_entry_count,
      coalesce(sum(shift.cash_voluntary_tips_cents), 0)::bigint as cash_voluntary_tips_cents,
      coalesce(sum(shift.credit_voluntary_tips_cents), 0)::bigint as credit_voluntary_tips_cents,
      coalesce(sum(shift.gratuity_cents), 0)::bigint as gratuity_cents,
      coalesce(sum(shift.gross_tip_earnings_cents), 0)::bigint as gross_tip_earnings_cents,
      coalesce(sum(shift.tip_out_cents), 0)::bigint as tip_out_cents,
      coalesce(sum(shift.gross_tip_earnings_cents - shift.tip_out_cents), 0)::bigint
        as net_tip_earnings_cents,
      coalesce(sum(shift.sales_cents), 0)::bigint as sales_cents,
      coalesce(sum(shift.hours_worked), 0)::numeric as hours_worked
    from shift_facts as shift
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
      'count', tips.shift_count,
      'tip_entry_count', tips.tip_entry_count,
      'cash_voluntary_tips_cents', tips.cash_voluntary_tips_cents,
      'credit_voluntary_tips_cents', tips.credit_voluntary_tips_cents,
      'gratuity_cents', tips.gratuity_cents,
      'gross_tip_earnings_cents', tips.gross_tip_earnings_cents,
      'tip_out_cents', tips.tip_out_cents,
      'net_tip_earnings_cents', tips.net_tip_earnings_cents,
      'sales_cents', tips.sales_cents,
      'hours_worked', tips.hours_worked
    ),
    'paychecks', jsonb_build_object(
      'count', paychecks.paycheck_count,
      'paid_tips_cents', paychecks.paid_tips_cents,
      'gross_pay_cents', paychecks.gross_pay_cents,
      'net_pay_cents', paychecks.net_pay_cents,
      'taxes_cents', paychecks.taxes_cents
    )
  )
  from tip_summary as tips
  cross join paycheck_summary as paychecks;
$$;

create or replace function public.payday_agent_recent_tip_entries(
  p_user_id uuid,
  p_start_date date default null,
  p_end_date date default null,
  p_shift_limit integer default 101
)
returns setof public.tip_entries
language sql
stable
security invoker
set search_path = ''
as $$
  with ordered_shifts as (
    select
      coalesce(entry.shift_id, entry.id) as semantic_shift_id,
      max(entry.work_date) as work_date,
      coalesce(
        (array_agg(entry.recorded_at order by entry.id)
          filter (where entry.kind = 'credit' and entry.recorded_at is not null))[1],
        (array_agg(entry.recorded_at order by entry.id)
          filter (where entry.kind = 'cash' and entry.recorded_at is not null))[1]
      ) as recorded_at
    from public.tip_entries as entry
    where entry.user_id = p_user_id
      and entry.deleted_at is null
      and (p_start_date is null or entry.work_date >= p_start_date)
      and (p_end_date is null or entry.work_date <= p_end_date)
    group by coalesce(entry.shift_id, entry.id)
    order by work_date desc, recorded_at desc nulls last, semantic_shift_id desc
    limit greatest(1, least(p_shift_limit, 201))
  )
  select entry.*
  from ordered_shifts as shift
  join public.tip_entries as entry
    on entry.user_id = p_user_id
    and coalesce(entry.shift_id, entry.id) = shift.semantic_shift_id
    and entry.deleted_at is null
  order by
    shift.work_date desc,
    shift.recorded_at desc nulls last,
    shift.semantic_shift_id desc,
    entry.id asc;
$$;

revoke all on function public.payday_agent_summary(uuid, date, date)
  from public, anon, authenticated;
revoke all on function public.payday_agent_recent_tip_entries(uuid, date, date, integer)
  from public, anon, authenticated;

grant execute on function public.payday_agent_summary(uuid, date, date)
  to service_role;
grant execute on function public.payday_agent_recent_tip_entries(uuid, date, date, integer)
  to service_role;
