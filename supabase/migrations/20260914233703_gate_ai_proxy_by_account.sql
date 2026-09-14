-- Bind the AI proxy routes to a real account, and cap what they can spend.
--
-- Payday ships no provider secret (a 1.0 release gate), so receipt scanning
-- and Insights narration post to a Vercel proxy that owns the OpenAI
-- credential. Those routes asked the caller for nothing: no auth, no shared
-- secret, no rate limit. Anyone who observed one request could replay its
-- shape forever, consuming paid capacity and denying the feature to real
-- users (2026-09-14 security review, finding 3).
--
-- The fix does authentication and quota in ONE round trip. The proxy calls
-- consume_payday_ai_quota with the CALLER's JWT and the publishable key, so:
--
--   * PostgREST verifies the token signature before anything here executes,
--     which makes this function call itself the authentication step — no
--     separate auth.getUser() hop;
--   * an absent token runs as `anon`, which is denied EXECUTE below, and an
--     invalid or expired one is rejected by PostgREST as 401. The proxy maps
--     both to 401;
--   * the proxy therefore never needs a service-role key. If it were ever
--     compromised, the blast radius is this one narrow function rather than
--     the whole database.
--
-- Nothing here records receipt content — only counts — so the privacy policy
-- claim that Payday's server does not store receipt text or images stays true.

-- Ceilings live in data, not code, so they can be raised with one UPDATE and
-- no redeploy of either the function or the proxy.
create table if not exists public.payday_ai_quota_limits (
  kind text primary key check (kind in ('receipt', 'insights')),
  per_account_daily integer not null check (per_account_daily > 0),
  global_daily integer not null check (global_daily > 0),
  updated_at timestamptz not null default now()
);

-- Sized for a runaway to be a rounding error, not for projected demand.
--
-- Receipt scanning is occasional even for a heavy user: a shift ends once, a
-- double ends twice. And ScanResultCache keys on the JPEG bytes, so
-- re-submitting the same photo never re-consumes a unit — the per-account
-- number needs no retry headroom.
--
-- The global ceilings are the only figures here that are genuinely a SPEND
-- ceiling. Account binding shapes abuse but does not stop it: anyone can make
-- a free account with an Apple ID, and a real user can read their own token
-- out of their own keychain. So these are deliberately small. 2000 receipt
-- scans a day of an image model with medium reasoning is four figures a month
-- of authorised spend — a ceiling that high is an invoice, not a breaker.
-- Raising them is one UPDATE with no redeploy, which is the entire reason
-- they live in data.
insert into public.payday_ai_quota_limits (kind, per_account_daily, global_daily)
values
  ('receipt', 15, 60),
  ('insights', 10, 30)
on conflict (kind) do nothing;

alter table public.payday_ai_quota_limits enable row level security;
revoke all on table public.payday_ai_quota_limits
  from public, anon, authenticated;

-- Per-account usage. The FK cascades from auth.users, which is how
-- delete_my_account() already erases every Payday table for a deleted
-- account (see 20260911150000_add_account_deletion.sql) — so this table
-- needs no separate cleanup path.
create table if not exists public.payday_ai_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  usage_day date not null,
  kind text not null check (kind in ('receipt', 'insights')),
  request_count integer not null default 0 check (request_count >= 0),
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  primary key (user_id, usage_day, kind)
);

create index if not exists payday_ai_usage_day_idx
  on public.payday_ai_usage (usage_day desc);

alter table public.payday_ai_usage enable row level security;
revoke all on table public.payday_ai_usage from public, anon, authenticated;

-- The circuit breaker's counter. One row per day per kind, so it stays tiny.
create table if not exists public.payday_ai_global_usage (
  usage_day date not null,
  kind text not null check (kind in ('receipt', 'insights')),
  request_count integer not null default 0 check (request_count >= 0),
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  primary key (usage_day, kind)
);

alter table public.payday_ai_global_usage enable row level security;
revoke all on table public.payday_ai_global_usage
  from public, anon, authenticated;

-- Consume one unit of AI quota for the calling account.
--
-- Returns allowed=false with a machine-readable reason rather than raising,
-- so the proxy can distinguish "you personally are done for today" from
-- "the whole feature is paused" and say something true to the user.
--
-- KNOWN TRADEOFF: the per-account and global increments are two statements,
-- not one atomic unit. If the global ceiling trips in the window between
-- them, the account is charged a unit it did not actually spend. That fails
-- CLOSED — it can never over-spend — and self-corrects at UTC midnight.
-- Making it atomic would take a single composite statement far harder to read
-- than this, for a worst case of one unit of skew on the day the breaker
-- trips. Not worth the legibility.
create or replace function public.consume_payday_ai_quota(p_kind text)
returns table (allowed boolean, reason text, retry_after_seconds integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_day date := (now() at time zone 'utc')::date;
  v_account_limit integer;
  v_global_limit integer;
  v_count integer;
  v_retry integer;
begin
  v_user_id := (select auth.uid());

  -- Defence in depth. `anon` is denied EXECUTE below and PostgREST rejects a
  -- bad token before we run, so reaching this branch means a caller arrived
  -- with a role that has no subject. Refuse rather than fall through.
  if v_user_id is null then
    return query select false, 'no_account'::text, 0;
    return;
  end if;

  if p_kind is null or p_kind not in ('receipt', 'insights') then
    return query select false, 'unknown_kind'::text, 0;
    return;
  end if;

  select q.per_account_daily, q.global_daily
    into v_account_limit, v_global_limit
  from public.payday_ai_quota_limits q
  where q.kind = p_kind;

  -- No configured ceiling is a configuration error, and the safe reading of a
  -- missing limit is zero, not infinity.
  if not found then
    return query select false, 'unconfigured'::text, 0;
    return;
  end if;

  -- Seconds until the counters roll over, so a 429 can carry an honest
  -- Retry-After instead of a guess.
  v_retry := greatest(
    1,
    ceil(
      extract(epoch from (((v_day + 1)::timestamp at time zone 'utc') - now()))
    )::integer
  );

  -- The race-free idiom from consume_payday_agent_rate_limit: the WHERE runs
  -- as part of the conflicting UPDATE, so a NULL return means the ceiling was
  -- already reached. No read-then-write window.
  insert into public.payday_ai_usage as u (user_id, usage_day, kind, request_count)
  values (v_user_id, v_day, p_kind, 1)
  on conflict (user_id, usage_day, kind) do update
    set request_count = u.request_count + 1,
        last_at = now()
    where u.request_count < v_account_limit
  returning u.request_count into v_count;

  if v_count is null then
    return query select false, 'account_daily'::text, v_retry;
    return;
  end if;

  -- Retention runs only when an account's counter is newly created, which is
  -- at most once per account per day — never once per request.
  if v_count = 1 then
    delete from public.payday_ai_usage
      where usage_day < v_day - 90;
    delete from public.payday_ai_global_usage
      where usage_day < v_day - 90;
  end if;

  insert into public.payday_ai_global_usage as g (usage_day, kind, request_count)
  values (v_day, p_kind, 1)
  on conflict (usage_day, kind) do update
    set request_count = g.request_count + 1,
        last_at = now()
    where g.request_count < v_global_limit
  returning g.request_count into v_count;

  if v_count is null then
    return query select false, 'global_budget'::text, v_retry;
    return;
  end if;

  return query select true, 'ok'::text, 0;
end;
$$;

-- anon must never reach this: an absent Authorization header is exactly the
-- attack, and denying EXECUTE is what turns it into a hard refusal.
revoke all on function public.consume_payday_ai_quota(text) from public;
revoke all on function public.consume_payday_ai_quota(text) from anon;
grant execute on function public.consume_payday_ai_quota(text) to authenticated;

comment on function public.consume_payday_ai_quota(text) is
  'Authenticates and meters one AI proxy call for auth.uid(). Granted only to '
  'authenticated, so calling it at all proves a verified JWT — which is why '
  'the Vercel proxy needs no service-role key. Records counts only, never '
  'receipt or prompt content.';
