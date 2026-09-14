-- Bound the telemetry written by rejected, unauthenticated requests.
--
-- auditRejectedRequest performed one service-role INSERT per rejected request
-- into payday_agent_rejected_requests. That route has gateway JWT
-- verification deliberately disabled, and authenticate() throws BEFORE
-- consume_payday_agent_rate_limit can apply, so no caller limit stood between
-- an anonymous HTTP request and a privileged durable write. Any unauthenticated
-- caller could convert cheap requests into unbounded writes and permanent
-- storage growth, with no retention job to reclaim it (CWE-400, found by the
-- 2026-09-14 security review).
--
-- Rejections are now counted into per-minute buckets keyed only on bounded
-- dimensions, so sustained attack traffic collapses into a handful of rows per
-- minute rather than one row per request. Note that `route` is a closed
-- classification rather than the raw request path: the path is
-- attacker-controlled and unbounded, and keying on it would have reintroduced
-- exactly the same unbounded row growth in a new table.

create table if not exists public.payday_agent_rejected_request_counts (
  bucket_minute timestamptz not null,
  route text not null
    check (route in ('health', 'openapi', 'mcp', 'rest_v1', 'other')),
  error_code text not null check (char_length(error_code) between 1 and 64),
  status_code integer not null check (status_code between 400 and 599),
  authorization_present boolean not null,
  request_count bigint not null default 0 check (request_count >= 0),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (bucket_minute, route, error_code, status_code, authorization_present)
);

create index if not exists payday_agent_rejected_request_counts_bucket_idx
  on public.payday_agent_rejected_request_counts (bucket_minute desc);

alter table public.payday_agent_rejected_request_counts enable row level security;
revoke all on table public.payday_agent_rejected_request_counts
  from public, anon, authenticated;
grant select, insert, update, delete
  on table public.payday_agent_rejected_request_counts to service_role;

-- One bounded statement per rejection, plus at most one retention delete per
-- new bucket key rather than one per request.
create or replace function public.record_payday_rejected_request(
  p_route text,
  p_error_code text,
  p_status_code integer,
  p_authorization_present boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count bigint;
begin
  with upsert as (
    insert into public.payday_agent_rejected_request_counts as c (
      bucket_minute,
      route,
      error_code,
      status_code,
      authorization_present,
      request_count
    )
    values (
      date_trunc('minute', now()),
      case
        when p_route in ('health', 'openapi', 'mcp', 'rest_v1') then p_route
        else 'other'
      end,
      -- Clamped defensively. The caller generates these, but a future one
      -- must not be able to widen the key space.
      left(coalesce(nullif(p_error_code, ''), 'unknown'), 64),
      greatest(400, least(599, coalesce(p_status_code, 500))),
      coalesce(p_authorization_present, false),
      1
    )
    on conflict (bucket_minute, route, error_code, status_code, authorization_present)
    do update set
      request_count = c.request_count + 1,
      last_seen_at = now()
    returning c.request_count
  )
  select request_count into v_count from upsert;

  -- request_count = 1 means this bucket key is new, which happens at most
  -- once per minute per key. Retention therefore costs nothing per request.
  if v_count = 1 then
    delete from public.payday_agent_rejected_request_counts
      where bucket_minute < now() - interval '14 days';
  end if;
end;
$$;

revoke all on function public.record_payday_rejected_request(text, text, integer, boolean)
  from public, anon, authenticated;
grant execute on function public.record_payday_rejected_request(text, text, integer, boolean)
  to service_role;

-- The per-request table is write-only telemetry that nothing reads, and it is
-- the unbounded sink itself. Reclaim whatever it already holds and keep the
-- retention bound in place for it too.
delete from public.payday_agent_rejected_requests
  where requested_at < now() - interval '14 days';
