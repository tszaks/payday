-- Device clocks are advisory metadata, never the authority for accepting a
-- write. The authenticated sync client already uploads only locally changed
-- rows, so server arrival order is the deterministic conflict order.

alter table public.tip_entries
  add column agent_idempotency_key text
  check (agent_idempotency_key is null or char_length(agent_idempotency_key) between 8 and 200);
alter table public.paycheck_records
  add column agent_idempotency_key text
  check (agent_idempotency_key is null or char_length(agent_idempotency_key) between 8 and 200);
alter table public.user_settings
  add column agent_idempotency_key text
  check (agent_idempotency_key is null or char_length(agent_idempotency_key) between 8 and 200);
alter table public.payday_agent_api_keys
  add column revoked_by_idempotency_key text
  check (
    revoked_by_idempotency_key is null
    or char_length(revoked_by_idempotency_key) between 8 and 200
  );

comment on column public.tip_entries.agent_idempotency_key is
  'Server-only key-and-request-scoped recovery marker for an interrupted Payday agent mutation.';
comment on column public.paycheck_records.agent_idempotency_key is
  'Server-only key-and-request-scoped recovery marker for an interrupted Payday agent mutation.';
comment on column public.user_settings.agent_idempotency_key is
  'Server-only key-and-request-scoped recovery marker for an interrupted Payday agent mutation.';

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
    least(row.client_updated_at, statement_timestamp()),
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
    least(row.client_updated_at, statement_timestamp()),
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
    least(row.client_updated_at, statement_timestamp()),
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
    least(row.client_updated_at, statement_timestamp()),
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
  returning public.paycheck_records.*;
$$;

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
    client_updated_at = excluded.client_updated_at
  returning public.user_settings.*;
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
  set deleted_at = least(p_deleted_at, statement_timestamp()),
      client_updated_at = least(p_deleted_at, statement_timestamp())
  where user_id = (select auth.uid())
    and id = any(p_ids)
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
  set deleted_at = least(p_deleted_at, statement_timestamp()),
      client_updated_at = least(p_deleted_at, statement_timestamp())
  where user_id = (select auth.uid())
    and id = any(p_ids)
  returning id;
$$;

revoke all on function public.import_tip_entries(jsonb) from public, anon;
revoke all on function public.upsert_tip_entries(jsonb) from public, anon;
revoke all on function public.import_paycheck_records(jsonb) from public, anon;
revoke all on function public.upsert_paycheck_records(jsonb) from public, anon;
revoke all on function public.import_user_settings(jsonb) from public, anon;
revoke all on function public.upsert_user_settings(jsonb) from public, anon;
revoke all on function public.soft_delete_tip_entries(uuid[], timestamptz) from public, anon;
revoke all on function public.soft_delete_paycheck_records(uuid[], timestamptz) from public, anon;

grant execute on function public.import_tip_entries(jsonb) to authenticated;
grant execute on function public.upsert_tip_entries(jsonb) to authenticated;
grant execute on function public.import_paycheck_records(jsonb) to authenticated;
grant execute on function public.upsert_paycheck_records(jsonb) to authenticated;
grant execute on function public.import_user_settings(jsonb) to authenticated;
grant execute on function public.upsert_user_settings(jsonb) to authenticated;
grant execute on function public.soft_delete_tip_entries(uuid[], timestamptz) to authenticated;
grant execute on function public.soft_delete_paycheck_records(uuid[], timestamptz) to authenticated;

drop function if exists public.payday_agent_recent_tip_entries(uuid, date, date, integer);

create function public.payday_agent_recent_tip_entries(
  p_user_id uuid,
  p_start_date date default null,
  p_end_date date default null,
  p_shift_limit integer default 101,
  p_before_work_date date default null,
  p_before_recorded_at timestamptz default null,
  p_before_shift_id uuid default null
)
returns setof public.tip_entries
language sql
stable
security invoker
set search_path = ''
as $$
  with shift_facts as (
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
  ), ordered_shifts as (
    select *
    from shift_facts
    where p_before_shift_id is null
      or (
        work_date,
        coalesce(recorded_at, '-infinity'::timestamptz),
        semantic_shift_id
      ) < (
        p_before_work_date,
        coalesce(p_before_recorded_at, '-infinity'::timestamptz),
        p_before_shift_id
      )
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

revoke all on function public.payday_agent_recent_tip_entries(
  uuid, date, date, integer, date, timestamptz, uuid
) from public, anon, authenticated;
grant execute on function public.payday_agent_recent_tip_entries(
  uuid, date, date, integer, date, timestamptz, uuid
) to service_role;

drop function if exists public.revoke_payday_agent_key_tree(uuid, uuid);

create function public.revoke_payday_agent_key_tree(
  p_user_id uuid,
  p_key_id uuid,
  p_idempotency_key text
)
returns table (id uuid, name text, revoked_at timestamptz)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_revoked_at timestamptz := now();
begin
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));

  return query
  with recursive descendants as (
    select key.id
    from public.payday_agent_api_keys as key
    where key.user_id = p_user_id
      and key.id = p_key_id
      and (
        key.revoked_at is null
        or key.revoked_by_idempotency_key = p_idempotency_key
      )
    union all
    select child.id
    from public.payday_agent_api_keys as child
    join descendants as parent on child.created_by_key_id = parent.id
    where child.user_id = p_user_id
  ), updated as (
    update public.payday_agent_api_keys as key
    set revoked_at = coalesce(key.revoked_at, v_revoked_at),
        revoked_by_idempotency_key = p_idempotency_key
    where key.user_id = p_user_id
      and key.id in (select descendants.id from descendants)
      and (
        key.revoked_at is null
        or key.revoked_by_idempotency_key = p_idempotency_key
      )
    returning key.id, key.name, key.revoked_at
  )
  select updated.id, updated.name, updated.revoked_at from updated;
end;
$$;

revoke all on function public.revoke_payday_agent_key_tree(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.revoke_payday_agent_key_tree(uuid, uuid, text)
  to service_role;

create table public.payday_agent_rejected_requests (
  request_id uuid primary key,
  requested_at timestamptz not null default now(),
  method text not null check (char_length(method) between 1 and 12),
  path text not null check (char_length(path) between 1 and 500),
  status_code integer not null check (status_code between 400 and 599),
  duration_ms integer not null check (duration_ms >= 0),
  error_code text not null,
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object')
);

create index payday_agent_rejected_requests_requested_idx
  on public.payday_agent_rejected_requests (requested_at desc);

alter table public.payday_agent_rejected_requests enable row level security;
revoke all on table public.payday_agent_rejected_requests
  from public, anon, authenticated;
grant select, insert on table public.payday_agent_rejected_requests
  to service_role;
