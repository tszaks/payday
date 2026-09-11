-- Financial records synchronize deletions as tombstones. Direct table deletes
-- would bypass every device's conflict and restoration logic.
drop policy if exists tip_entries_delete_own on public.tip_entries;
drop policy if exists paycheck_records_delete_own on public.paycheck_records;
drop policy if exists user_settings_delete_own on public.user_settings;

revoke delete on table public.tip_entries from authenticated;
revoke delete on table public.paycheck_records from authenticated;
revoke delete on table public.user_settings from authenticated;

create index if not exists payday_agent_audit_log_requested_at_idx
  on public.payday_agent_audit_log (requested_at);

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
  -- Bounded global cleanup also covers credentials that are no longer used.
  delete from public.payday_agent_rate_limits
  where ctid in (
    select ctid from public.payday_agent_rate_limits
    where window_start < v_window - interval '10 minutes'
    limit 500
  );

  delete from public.payday_agent_idempotency
  where ctid in (
    select ctid from public.payday_agent_idempotency
    where expires_at <= now()
    limit 500
  );

  delete from public.payday_agent_audit_log
  where id in (
    select id from public.payday_agent_audit_log
    where requested_at < now() - interval '180 days'
    order by requested_at
    limit 500
  );

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
