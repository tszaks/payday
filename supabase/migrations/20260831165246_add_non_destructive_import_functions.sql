create or replace function public.import_tip_entries(p_rows jsonb)
returns setof public.tip_entries
language sql
security invoker
set search_path = ''
as $$
  insert into public.tip_entries (
    id, user_id, shift_id, work_date, amount_cents, kind, note,
    recorded_at, is_double, hours_worked, tip_out_cents, sales_cents,
    shift_period, clock_in, clock_out, server_count, receipt_metrics,
    client_updated_at, deleted_at
  )
  select
    row.id,
    (select auth.uid()),
    row.shift_id,
    row.work_date,
    row.amount_cents,
    row.kind,
    row.note,
    row.recorded_at,
    coalesce(row.is_double, false),
    row.hours_worked,
    row.tip_out_cents,
    row.sales_cents,
    row.shift_period,
    row.clock_in,
    row.clock_out,
    row.server_count,
    row.receipt_metrics,
    row.client_updated_at,
    null
  from jsonb_to_recordset(p_rows) as row(
    id uuid,
    shift_id uuid,
    work_date date,
    amount_cents integer,
    kind text,
    note text,
    recorded_at timestamptz,
    is_double boolean,
    hours_worked numeric,
    tip_out_cents integer,
    sales_cents integer,
    shift_period text,
    clock_in timestamptz,
    clock_out timestamptz,
    server_count integer,
    receipt_metrics jsonb,
    client_updated_at timestamptz
  )
  where (select auth.uid()) is not null
  on conflict (id) do nothing
  returning public.tip_entries.*;
$$;

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
    client_updated_at, deleted_at
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
    row.client_updated_at,
    null
  from jsonb_to_recordset(p_rows) as row(
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

revoke all on function public.import_tip_entries(jsonb) from public, anon;
revoke all on function public.import_paycheck_records(jsonb) from public, anon;
grant execute on function public.import_tip_entries(jsonb) to authenticated;
grant execute on function public.import_paycheck_records(jsonb) to authenticated;
