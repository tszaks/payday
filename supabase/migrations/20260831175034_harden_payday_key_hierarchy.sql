create or replace function private.validate_payday_agent_key_parent()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_parent public.payday_agent_api_keys%rowtype;
  v_active_count integer;
begin
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));

  select count(*) into v_active_count
  from public.payday_agent_api_keys
  where user_id = new.user_id and revoked_at is null;

  if v_active_count >= 25 then
    raise exception 'active Payday agent key limit reached';
  end if;

  if new.created_by_key_id is null then
    return new;
  end if;

  select * into v_parent
  from public.payday_agent_api_keys
  where id = new.created_by_key_id
    and user_id = new.user_id
  for key share;

  if not found
    or v_parent.revoked_at is not null
    or (v_parent.expires_at is not null and v_parent.expires_at <= now()) then
    raise exception 'Payday agent key parent is not active';
  end if;

  if not new.scopes <@ v_parent.scopes then
    raise exception 'Payday agent key scopes exceed parent';
  end if;

  if new.rate_limit_per_minute > v_parent.rate_limit_per_minute then
    raise exception 'Payday agent key rate limit exceeds parent';
  end if;

  if v_parent.expires_at is not null
    and (new.expires_at is null or new.expires_at > v_parent.expires_at) then
    raise exception 'Payday agent key expiry exceeds parent';
  end if;

  if v_parent.created_by_key_id is not null and new.expires_at is null then
    raise exception 'delegated Payday admin keys must create expiring children';
  end if;

  return new;
end;
$$;

revoke all on function private.validate_payday_agent_key_parent()
  from public, anon, authenticated;

create trigger payday_agent_api_keys_validate_parent
before insert on public.payday_agent_api_keys
for each row execute function private.validate_payday_agent_key_parent();

create or replace function public.revoke_payday_agent_key_tree(
  p_user_id uuid,
  p_key_id uuid
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
      and key.revoked_at is null
    union all
    select child.id
    from public.payday_agent_api_keys as child
    join descendants as parent on child.created_by_key_id = parent.id
    where child.user_id = p_user_id
  ), updated as (
    update public.payday_agent_api_keys as key
    set revoked_at = v_revoked_at
    where key.user_id = p_user_id
      and key.id in (select descendants.id from descendants)
      and key.revoked_at is null
    returning key.id, key.name, key.revoked_at
  )
  select updated.id, updated.name, updated.revoked_at from updated;
end;
$$;

revoke all on function public.revoke_payday_agent_key_tree(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.revoke_payday_agent_key_tree(uuid, uuid)
  to service_role;
