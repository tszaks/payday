create schema if not exists private;

revoke all on schema private from public, anon, authenticated;

create or replace function private.touch_versioned_row()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  new.version = old.version + 1;
  return new;
end;
$$;

create table public.tip_entries (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  shift_id uuid,
  work_date date not null,
  amount_cents integer not null check (amount_cents >= 0),
  kind text not null check (kind in ('cash', 'credit')),
  note text,
  recorded_at timestamptz,
  is_double boolean not null default false,
  hours_worked numeric check (hours_worked is null or hours_worked >= 0),
  tip_out_cents integer check (tip_out_cents is null or tip_out_cents >= 0),
  sales_cents integer check (sales_cents is null or sales_cents >= 0),
  shift_period text check (shift_period is null or shift_period in ('lunch', 'dinner')),
  clock_in timestamptz,
  clock_out timestamptz,
  server_count integer check (server_count is null or server_count >= 0),
  receipt_metrics jsonb,
  client_updated_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version >= 1)
);

comment on table public.tip_entries is
  'Lossless Supabase representation of Payday TipEntry rows. Rows sharing shift_id form one shift.';
comment on column public.tip_entries.receipt_metrics is
  'Versioned ShiftReceiptMetrics JSON. Preserve optional-versus-zero semantics during import.';
comment on column public.tip_entries.client_updated_at is
  'Last known local mutation time, used to reconcile CloudKit-era imports. updated_at is server-owned.';

create index tip_entries_user_work_date_idx
  on public.tip_entries (user_id, work_date desc)
  where deleted_at is null;
create index tip_entries_user_shift_idx
  on public.tip_entries (user_id, shift_id)
  where deleted_at is null;
create index tip_entries_user_updated_idx
  on public.tip_entries (user_id, updated_at, id);

create trigger tip_entries_touch_version
before update on public.tip_entries
for each row execute function private.touch_versioned_row();

create table public.paycheck_records (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  paid_tips_cents integer not null check (paid_tips_cents >= 0),
  note text,
  hourly_rate_cents integer check (hourly_rate_cents is null or hourly_rate_cents >= 0),
  owed_tips_cents integer check (owed_tips_cents is null or owed_tips_cents >= 0),
  gross_pay_cents integer check (gross_pay_cents is null or gross_pay_cents >= 0),
  net_pay_cents integer check (net_pay_cents is null or net_pay_cents >= 0),
  regular_wages_cents integer check (regular_wages_cents is null or regular_wages_cents >= 0),
  overtime_wages_cents integer check (overtime_wages_cents is null or overtime_wages_cents >= 0),
  gratuity_cents integer check (gratuity_cents is null or gratuity_cents >= 0),
  taxes_cents integer check (taxes_cents is null or taxes_cents >= 0),
  client_updated_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1 check (version >= 1),
  check (period_end >= period_start)
);

create index paycheck_records_user_period_idx
  on public.paycheck_records (user_id, period_end desc)
  where deleted_at is null;
create index paycheck_records_user_updated_idx
  on public.paycheck_records (user_id, updated_at, id);

create trigger paycheck_records_touch_version
before update on public.paycheck_records
for each row execute function private.touch_versioned_row();

create table public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  first_name text,
  base_hourly_wage_cents integer check (base_hourly_wage_cents is null or base_hourly_wage_cents >= 0),
  pay_frequency text check (pay_frequency is null or pay_frequency in ('weekly', 'biweekly', 'twiceMonthly', 'monthly')),
  anchor_period_end date,
  pay_delay_days integer check (pay_delay_days is null or pay_delay_days >= 0),
  first_weekday integer check (first_weekday is null or first_weekday between 1 and 7),
  smart_nudge_enabled boolean not null default true,
  payday_reminder_enabled boolean not null default true,
  move_ledger jsonb not null default '{}'::jsonb check (jsonb_typeof(move_ledger) = 'object'),
  client_updated_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version >= 1),
  check ((pay_frequency is null) = (anchor_period_end is null))
);

create trigger user_settings_touch_version
before update on public.user_settings
for each row execute function private.touch_versioned_row();

create table public.migration_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  schema_version integer not null check (schema_version > 0),
  tip_entry_count integer not null check (tip_entry_count >= 0),
  paycheck_record_count integer not null check (paycheck_record_count >= 0),
  tip_entry_hash text not null,
  paycheck_record_hash text not null,
  imported_at timestamptz not null default now(),
  verified_at timestamptz,
  primary key (user_id, device_id)
);

create index migration_receipts_user_verified_idx
  on public.migration_receipts (user_id, verified_at);

alter table public.tip_entries enable row level security;
alter table public.paycheck_records enable row level security;
alter table public.user_settings enable row level security;
alter table public.migration_receipts enable row level security;

create policy tip_entries_select_own
on public.tip_entries for select to authenticated
using ((select auth.uid()) = user_id);
create policy tip_entries_insert_own
on public.tip_entries for insert to authenticated
with check ((select auth.uid()) = user_id);
create policy tip_entries_update_own
on public.tip_entries for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);
create policy tip_entries_delete_own
on public.tip_entries for delete to authenticated
using ((select auth.uid()) = user_id);

create policy paycheck_records_select_own
on public.paycheck_records for select to authenticated
using ((select auth.uid()) = user_id);
create policy paycheck_records_insert_own
on public.paycheck_records for insert to authenticated
with check ((select auth.uid()) = user_id);
create policy paycheck_records_update_own
on public.paycheck_records for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);
create policy paycheck_records_delete_own
on public.paycheck_records for delete to authenticated
using ((select auth.uid()) = user_id);

create policy user_settings_select_own
on public.user_settings for select to authenticated
using ((select auth.uid()) = user_id);
create policy user_settings_insert_own
on public.user_settings for insert to authenticated
with check ((select auth.uid()) = user_id);
create policy user_settings_update_own
on public.user_settings for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);
create policy user_settings_delete_own
on public.user_settings for delete to authenticated
using ((select auth.uid()) = user_id);

create policy migration_receipts_select_own
on public.migration_receipts for select to authenticated
using ((select auth.uid()) = user_id);
create policy migration_receipts_insert_own
on public.migration_receipts for insert to authenticated
with check ((select auth.uid()) = user_id);
create policy migration_receipts_update_own
on public.migration_receipts for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

revoke all on table public.tip_entries from anon, authenticated;
revoke all on table public.paycheck_records from anon, authenticated;
revoke all on table public.user_settings from anon, authenticated;
revoke all on table public.migration_receipts from anon, authenticated;

grant select, insert, update, delete on table public.tip_entries to authenticated;
grant select, insert, update, delete on table public.paycheck_records to authenticated;
grant select, insert, update, delete on table public.user_settings to authenticated;
grant select, insert, update on table public.migration_receipts to authenticated;
