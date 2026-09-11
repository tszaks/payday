-- Account deletion, required by App Review Guideline 5.1.1(v): an app that
-- supports account creation must let people delete that account from inside
-- the app. Payday gates its entire UI behind Sign in with Apple and had no
-- way to sign out, let alone delete, which is a straightforward rejection.
--
-- Every user-owned table references auth.users(id) ON DELETE CASCADE, so
-- removing the auth row removes everything:
--
--   tip_entries, paycheck_records, user_settings, migration_receipts,
--   payday_agent_api_keys, payday_agent_audit_log, payday_agent_idempotency
--       -> direct cascading user_id
--   payday_agent_rate_limits
--       -> cascades transitively through payday_agent_api_keys(key_id)
--   payday_agent_rejected_requests
--       -> intentionally untouched: it has no user_id column at all. It logs
--          method, path, status, and error for rejected agent requests with
--          nothing tying a row to a person, so there is no per-user data in
--          it to erase.
--
-- Deleting from auth.users needs privileges the authenticated role does not
-- have, so this is the one SECURITY DEFINER function in the schema. Every
-- other function here is security invoker, and this one is deliberately as
-- narrow as possible: it takes no arguments, so a caller cannot name a
-- victim, and it reads the subject solely from auth.uid().

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  v_user_id := (select auth.uid());

  -- No session, no subject. Without this an unauthenticated caller would
  -- reach `delete ... where id is null`, which deletes nothing, but failing
  -- loudly is the correct answer and keeps the contract honest.
  if v_user_id is null then
    raise exception 'delete_my_account requires an authenticated session'
      using errcode = '28000';
  end if;

  delete from auth.users where id = v_user_id;
end;
$$;

-- anon must never reach this, and it is not a service-role utility either.
revoke all on function public.delete_my_account() from public;
revoke all on function public.delete_my_account() from anon;
grant execute on function public.delete_my_account() to authenticated;

comment on function public.delete_my_account() is
  'Deletes the calling user''s auth row, cascading every Payday table that '
  'references it. Satisfies App Review Guideline 5.1.1(v). Takes no '
  'arguments so the subject can only ever be auth.uid().';
