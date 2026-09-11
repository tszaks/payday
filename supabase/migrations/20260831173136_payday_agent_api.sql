create table public.payday_agent_api_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 100),
  token_prefix text not null check (char_length(token_prefix) between 12 and 32),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  scopes text[] not null,
  rate_limit_per_minute integer not null default 60
    check (rate_limit_per_minute between 1 and 600),
  created_by_key_id uuid references public.payday_agent_api_keys(id) on delete set null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  check (cardinality(scopes) > 0),
  check (scopes <@ array['read', 'write', 'delete', 'admin']::text[]),
  check (expires_at is null or expires_at > created_at)
);

comment on table public.payday_agent_api_keys is
  'Hashed, revocable credentials for the Payday REST and MCP APIs. Plaintext tokens are never stored.';

create unique index payday_agent_api_keys_user_name_active_idx
  on public.payday_agent_api_keys (user_id, lower(name))
  where revoked_at is null;

create index payday_agent_api_keys_user_created_idx
  on public.payday_agent_api_keys (user_id, created_at desc);

create table public.payday_agent_rate_limits (
  key_id uuid not null references public.payday_agent_api_keys(id) on delete cascade,
  window_start timestamptz not null,
  request_count integer not null default 1 check (request_count > 0),
  primary key (key_id, window_start)
);

create index payday_agent_rate_limits_expiry_idx
  on public.payday_agent_rate_limits (window_start);

create table public.payday_agent_idempotency (
  key_id uuid not null references public.payday_agent_api_keys(id) on delete cascade,
  idempotency_key text not null check (char_length(idempotency_key) between 8 and 200),
  user_id uuid not null references auth.users(id) on delete cascade,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  state text not null default 'in_progress' check (state in ('in_progress', 'completed')),
  status_code integer check (status_code is null or status_code between 200 and 599),
  response_body jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  expires_at timestamptz not null default (now() + interval '24 hours'),
  primary key (key_id, idempotency_key),
  check (
    (state = 'in_progress' and status_code is null and response_body is null and completed_at is null)
    or
    (state = 'completed' and status_code is not null and response_body is not null and completed_at is not null)
  )
);

create index payday_agent_idempotency_expiry_idx
  on public.payday_agent_idempotency (expires_at);

create table public.payday_agent_audit_log (
  id bigint generated always as identity primary key,
  request_id uuid not null unique,
  key_id uuid references public.payday_agent_api_keys(id) on delete set null,
  user_id uuid not null references auth.users(id) on delete cascade,
  requested_at timestamptz not null default now(),
  method text not null check (char_length(method) between 1 and 12),
  path text not null check (char_length(path) between 1 and 500),
  operation text not null check (char_length(operation) between 1 and 100),
  status_code integer not null check (status_code between 100 and 599),
  duration_ms integer not null check (duration_ms >= 0),
  idempotency_key text,
  error_code text,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object')
);

create index payday_agent_audit_log_user_requested_idx
  on public.payday_agent_audit_log (user_id, requested_at desc);

create index payday_agent_audit_log_key_requested_idx
  on public.payday_agent_audit_log (key_id, requested_at desc);

alter table public.payday_agent_api_keys enable row level security;
alter table public.payday_agent_rate_limits enable row level security;
alter table public.payday_agent_idempotency enable row level security;
alter table public.payday_agent_audit_log enable row level security;

revoke all on table public.payday_agent_api_keys from public, anon, authenticated;
revoke all on table public.payday_agent_rate_limits from public, anon, authenticated;
revoke all on table public.payday_agent_idempotency from public, anon, authenticated;
revoke all on table public.payday_agent_audit_log from public, anon, authenticated;
revoke all on sequence public.payday_agent_audit_log_id_seq from public, anon, authenticated;

grant select, insert, update on table public.payday_agent_api_keys to service_role;
grant select, insert, update, delete on table public.payday_agent_rate_limits to service_role;
grant select, insert, update, delete on table public.payday_agent_idempotency to service_role;
grant select, insert on table public.payday_agent_audit_log to service_role;
grant usage, select on sequence public.payday_agent_audit_log_id_seq to service_role;

create or replace function public.consume_payday_agent_rate_limit(p_key_id uuid)
returns table (allowed boolean, retry_after_seconds integer)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_limit integer;
  v_window timestamptz := date_trunc('minute', now());
  v_count integer;
begin
  select rate_limit_per_minute
    into v_limit
  from public.payday_agent_api_keys
  where id = p_key_id
    and revoked_at is null
    and (expires_at is null or expires_at > now());

  if not found then
    return query select false, 60;
    return;
  end if;

  insert into public.payday_agent_rate_limits (key_id, window_start, request_count)
  values (p_key_id, v_window, 1)
  on conflict (key_id, window_start) do update
    set request_count = public.payday_agent_rate_limits.request_count + 1
    where public.payday_agent_rate_limits.request_count < v_limit
  returning request_count into v_count;

  if v_count is null then
    return query select false, greatest(1, 60 - extract(second from now())::integer);
  else
    return query select true, 0;
  end if;
end;
$$;

revoke all on function public.consume_payday_agent_rate_limit(uuid)
  from public, anon, authenticated;
grant execute on function public.consume_payday_agent_rate_limit(uuid)
  to service_role;

-- Trigger functions never need to be directly callable through the Data API.
revoke execute on function private.touch_versioned_row()
  from public, anon, authenticated;
