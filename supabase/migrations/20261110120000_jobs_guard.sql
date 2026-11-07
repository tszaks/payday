-- PR E2a (jobs engine): the server keeps the job list.
--
-- The job list lives inside user_settings.compensation_policies (PR E1).
-- A build from before jobs decodes that JSON, drops the `jobs` key it does
-- not know, and writes the rest back when the person edits a wage, which
-- would wipe every job. From E2a on, a build that knows jobs ALWAYS writes
-- `jobs` (`[]` when there are none), so the server can tell the two apart:
--
--   * incoming compensation_policies is null    -> keep the stored row
--     (unchanged rule);
--   * incoming has no `jobs` key (an older build) -> take the incoming
--     policies, keep the STORED `jobs`;
--   * incoming has `jobs` (any length)          -> take it as sent.
--
-- Every other column keeps its rule from 20261107120000.
-- import_user_settings is insert-only and is not redefined.
--
-- Known gap: a `jobName` on a rate or calendar INSIDE the arrays is still
-- dropped by an older build that edits its wage; this guard covers the
-- job list only.

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
    -- And a client that knows policies but predates jobs (no `jobs` key)
    -- must not clear the stored job list: keep it, as card_tips_paid_at_close
    -- keeps an absent key. A build that knows jobs always sends `jobs`
    -- (`[]` when there are none), so it can still clear or replace them.
    compensation_policies = case
      when excluded.compensation_policies is null
        then public.user_settings.compensation_policies
      when jsonb_typeof(excluded.compensation_policies) = 'object'
           and not (excluded.compensation_policies ? 'jobs')
           and jsonb_typeof(public.user_settings.compensation_policies) = 'object'
           and public.user_settings.compensation_policies ? 'jobs'
        then excluded.compensation_policies
             || jsonb_build_object('jobs', public.user_settings.compensation_policies -> 'jobs')
      else excluded.compensation_policies
    end,
    -- Same rule for the payout setting: a build that does not know it sends
    -- no key, and must not reset a person's choice to the default.
    card_tips_paid_at_close = case when p_row ? 'card_tips_paid_at_close'
                                   then excluded.card_tips_paid_at_close
                                   else public.user_settings.card_tips_paid_at_close end,
    client_updated_at = excluded.client_updated_at
  returning public.user_settings.*;
$$;

revoke all on function public.upsert_user_settings(jsonb) from public, anon;
grant execute on function public.upsert_user_settings(jsonb) to authenticated;
