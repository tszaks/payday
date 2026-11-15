-- Narrow three grants around `shift_migration_state` to what their callers use.
--
-- Nothing here changes an answer the app sees. The app reads the view as
-- `authenticated`, and the view only ever passes the caller's own id to
-- `payday_nothing_unconverted`: `l.user_id` from ledger rows that
-- `sms_read_own` limits to the caller, or `auth.uid()` itself.

-- ------------------------------------------- 1. payday_nothing_unconverted
-- A definer granted to `authenticated` is an RPC
-- (`/rest/v1/rpc/payday_nothing_unconverted`), so without a check any account
-- could name another account, read one bit about it, and make the server scan
-- that account's `tip_entries` and `shifts` on demand.
--
-- Same three legal callers as `migrate_tip_entries_to_shifts`: the account
-- itself; service_role, naming any account; and an operator in psql with no
-- JWT at all, naming any account. Anyone else naming another account gets
-- FALSE, not a raise: the function is evaluated inside the view, where a
-- raise would fail the whole read, and false is the view's fail-closed
-- answer ("not authoritative"). The identity test comes first, so a refused
-- call does no scan.
--
-- `is not distinct from` rather than `=`, so a caller with no `sub` reads
-- false, never NULL.
create or replace function public.payday_nothing_unconverted(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null
     and (p_user_id is not distinct from (select auth.uid())
          or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '')
             = 'service_role'
          or (coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = ''
              and (select auth.uid()) is null))
     and not exists (select 1 from private.unmigrated_legacy_rows(p_user_id))
     and not exists (select 1 from private.shift_fold_backlog b where b.user_id = p_user_id)
     and not exists (select 1 from private.shift_fold_failures f where f.user_id = p_user_id);
$$;

revoke all on function public.payday_nothing_unconverted(uuid) from public, anon;
grant execute on function public.payday_nothing_unconverted(uuid) to authenticated;

-- --------------------------------------------------- 2. the view's grants
-- The view kept Supabase's default ALL for `authenticated`. Writes fail today
-- only because a UNION ALL view is not auto-updatable; that is a property of
-- its shape, and the grant should say read-only by itself.
revoke all on public.shift_migration_state from authenticated;
grant select on public.shift_migration_state to authenticated;

-- ---------------------------------------------- 3. payday_legacy_shift_id
-- Pure (an md5 of a date), so nothing leaks, but it is the only function in
-- `public` still callable without a session. Its one caller is
-- `private.legacy_group_key`, which runs only inside definer functions owned
-- by `postgres` (no client role has USAGE on `private`), so no client role
-- needs it.
revoke execute on function public.payday_legacy_shift_id(date) from public, anon, authenticated;
