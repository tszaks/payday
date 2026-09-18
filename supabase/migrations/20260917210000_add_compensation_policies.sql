-- PaydayCore PR 3 (plan Design 1, "Severing calendar from payroll"):
-- compensation policies roam with the account.
--
-- Rate history and payroll-calendar history are settings, not records: they
-- live in the App Group on the device and in one jsonb column here, so the
-- choice follows the user to a new phone instead of being re-derived from
-- `base_hourly_wage_cents` (which would re-mint an `assumedFromLegacySetting`
-- policy and put the "estimated" caption back after they had answered the
-- rate-history prompt).
--
-- The column is NULLABLE on purpose, and null means "this client has never
-- said anything about policies" rather than "no policies".
--
-- Payday 1.0 is already shipped and in review. It calls
-- `upsert_user_settings` with a payload that has no `compensation_policies`
-- key at all. Were the column `not null default '{}'`, that write would
-- coalesce to `{}` and erase the policies a newer device had stored, which is
-- the user's rate history. With a nullable column the old payload writes
-- null, and the update branch below coalesces null back to whatever is
-- already on the row, so an old build passing through touches nothing.
--
-- The CHECK guards `jsonb_typeof` rather than casting anything: a numeric
-- cast inside a CHECK aborts the statement uncatchably when the payload is
-- the wrong shape (measured on Postgres 17.11 during PR 2).

alter table public.user_settings
  add column if not exists compensation_policies jsonb;

alter table public.user_settings
  drop constraint if exists user_settings_compensation_policies_object;

alter table public.user_settings
  add constraint user_settings_compensation_policies_object
  check (compensation_policies is null or jsonb_typeof(compensation_policies) = 'object');

comment on column public.user_settings.compensation_policies is
  'CompensationPolicies JSON (PaydayCore): {version, rates[], calendars[]}. '
  'Null means the writing client does not know about policies (e.g. Payday 1.0); '
  'the upsert RPC preserves the stored value in that case rather than clearing it.';

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
    compensation_policies,
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
    compensation_policies,
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
    client_updated_at = excluded.client_updated_at
  returning public.user_settings.*;
$$;

revoke all on function public.import_user_settings(jsonb) from public, anon;
revoke all on function public.upsert_user_settings(jsonb) from public, anon;
grant execute on function public.import_user_settings(jsonb) to authenticated;
grant execute on function public.upsert_user_settings(jsonb) to authenticated;
