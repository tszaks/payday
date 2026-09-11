-- Payday records exact hour fractions (often minute/60 values). The original
-- double-precision column retained the right IEEE-754 bits, but this project's
-- extra_float_digits=0 setting shortened PostgREST responses to 15 digits.
-- Numeric preserves the client JSON decimal exactly and round-trips through
-- PostgREST without weakening the verified-import equality check.
set local extra_float_digits = 3;

alter table public.tip_entries
  alter column hours_worked type numeric
  using hours_worked::text::numeric;

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

revoke all on function public.import_tip_entries(jsonb) from public, anon;
revoke all on function public.upsert_tip_entries(jsonb) from public, anon;
grant execute on function public.import_tip_entries(jsonb) to authenticated;
grant execute on function public.upsert_tip_entries(jsonb) to authenticated;
