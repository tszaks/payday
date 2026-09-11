do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable()
      from public, anon, authenticated;
  end if;
end;
$$;

create or replace function public.upsert_tip_entries(p_rows jsonb)
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
    row.deleted_at
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
    client_updated_at timestamptz,
    deleted_at timestamptz
  )
  where (select auth.uid()) is not null
  on conflict (id) do update set
    shift_id = excluded.shift_id,
    work_date = excluded.work_date,
    amount_cents = excluded.amount_cents,
    kind = excluded.kind,
    note = excluded.note,
    recorded_at = excluded.recorded_at,
    is_double = excluded.is_double,
    hours_worked = excluded.hours_worked,
    tip_out_cents = excluded.tip_out_cents,
    sales_cents = excluded.sales_cents,
    shift_period = excluded.shift_period,
    clock_in = excluded.clock_in,
    clock_out = excluded.clock_out,
    server_count = excluded.server_count,
    receipt_metrics = excluded.receipt_metrics,
    client_updated_at = excluded.client_updated_at,
    deleted_at = excluded.deleted_at
  where public.tip_entries.user_id = (select auth.uid())
    and excluded.client_updated_at >= public.tip_entries.client_updated_at
  returning public.tip_entries.*;
$$;

create or replace function public.upsert_paycheck_records(p_rows jsonb)
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
    row.deleted_at
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
    client_updated_at = excluded.client_updated_at,
    deleted_at = excluded.deleted_at
  where public.paycheck_records.user_id = (select auth.uid())
    and excluded.client_updated_at >= public.paycheck_records.client_updated_at
  returning public.paycheck_records.*;
$$;

create or replace function public.soft_delete_tip_entries(
  p_ids uuid[],
  p_deleted_at timestamptz
)
returns setof uuid
language sql
security invoker
set search_path = ''
as $$
  update public.tip_entries
  set deleted_at = p_deleted_at,
      client_updated_at = p_deleted_at
  where user_id = (select auth.uid())
    and id = any(p_ids)
    and p_deleted_at >= client_updated_at
  returning id;
$$;

create or replace function public.soft_delete_paycheck_records(
  p_ids uuid[],
  p_deleted_at timestamptz
)
returns setof uuid
language sql
security invoker
set search_path = ''
as $$
  update public.paycheck_records
  set deleted_at = p_deleted_at,
      client_updated_at = p_deleted_at
  where user_id = (select auth.uid())
    and id = any(p_ids)
    and p_deleted_at >= client_updated_at
  returning id;
$$;

revoke all on function public.upsert_tip_entries(jsonb) from public, anon;
revoke all on function public.upsert_paycheck_records(jsonb) from public, anon;
revoke all on function public.soft_delete_tip_entries(uuid[], timestamptz) from public, anon;
revoke all on function public.soft_delete_paycheck_records(uuid[], timestamptz) from public, anon;

grant execute on function public.upsert_tip_entries(jsonb) to authenticated;
grant execute on function public.upsert_paycheck_records(jsonb) to authenticated;
grant execute on function public.soft_delete_tip_entries(uuid[], timestamptz) to authenticated;
grant execute on function public.soft_delete_paycheck_records(uuid[], timestamptz) to authenticated;
