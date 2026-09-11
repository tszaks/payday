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
  delete from public.payday_agent_rate_limits
  where key_id = p_key_id
    and window_start < v_window - interval '10 minutes';

  delete from public.payday_agent_idempotency
  where key_id = p_key_id
    and expires_at <= now();

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
