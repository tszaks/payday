drop index if exists public.payday_agent_rate_limits_expiry_idx;
drop index if exists public.payday_agent_idempotency_expiry_idx;

create index if not exists payday_agent_api_keys_created_by_idx
  on public.payday_agent_api_keys (created_by_key_id)
  where created_by_key_id is not null;

create index if not exists payday_agent_idempotency_key_expiry_idx
  on public.payday_agent_idempotency (key_id, expires_at);

create index if not exists payday_agent_idempotency_user_idx
  on public.payday_agent_idempotency (user_id);

create policy payday_agent_api_keys_service_role
on public.payday_agent_api_keys for all to service_role
using (true) with check (true);

create policy payday_agent_rate_limits_service_role
on public.payday_agent_rate_limits for all to service_role
using (true) with check (true);

create policy payday_agent_idempotency_service_role
on public.payday_agent_idempotency for all to service_role
using (true) with check (true);

create policy payday_agent_audit_log_service_role
on public.payday_agent_audit_log for all to service_role
using (true) with check (true);
