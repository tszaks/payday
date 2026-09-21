-- Stamp shift authority when the account is CREATED, not when its first sync
-- finishes converting nothing.
--
-- ## The window this closes
--
-- Read authority is `shift_migration_state.migrated_at`, fetched by the
-- device's `applyShiftAuthorityLeg` and applied locally. A brand-new account
-- has no row at all until its first sync runs
-- `migrate_tip_entries_to_shifts`, which converts zero groups, completes, and
-- stamps on completion. So authority arrives one round-trip late, and in that
-- gap the account is on the legacy arm: it writes `tip_entries` and reads the
-- legacy path.
--
-- That gap is only harmless while the legacy READ arm still exists. It is the
-- single reason the flip's eleven `else` branches cannot be deleted, and it
-- is a real first-run exposure: a user who reaches the log sheet before the
-- first round-trip completes -- a slow network, a cold launch on cellular, a
-- sync that fails once and retries, not merely airplane mode -- logs their
-- first ever shift onto a path that a later deletion would stop rendering.
--
-- At account creation the server is not judging anything. It is writing the
-- `auth.users` row, so "this account has zero legacy rows" is a fact about
-- the statement in flight, not an inference from local emptiness. That is why
-- this is a row and not a predicate: the earlier sketch had the DEVICE decide
-- from local state, which would stamp authoritative over an unmigrated
-- account after a reinstall or a restore-from-backup, a silent data-visibility
-- bug strictly worse than the window it closed.
--
-- ## Why this function cannot be allowed to raise
--
-- A trigger on `auth.users` runs inside the auth service's own transaction.
-- If it raises, ACCOUNT CREATION FAILS. That would trade a first-run display
-- window for a first-run signup failure, which is strictly worse: one shows
-- the wrong thing, the other locks the person out of the product entirely,
-- and it would land on the same onboarding flow that already drew a
-- Guideline 4 rejection.
--
-- So the body swallows everything. On any error it returns normally and the
-- account is created with no row -- which is exactly today's behaviour, where
-- the one-shot creates and stamps the row on the first sync. The change is
-- strictly additive: at worst it does nothing, at best it closes the window.
--
-- This is FAIL-SAFE, deliberately, and not fail-closed. Elsewhere in this
-- system the safe direction is to refuse (a failed authority read returns
-- `.unknown` rather than promoting). Here the safe direction is to let the
-- person in and flip late.
--
-- ## Scope
--
-- New accounts only, plus a one-time backfill of existing accounts that have
-- never held a legacy row. An account WITH legacy rows is untouched: its
-- authority is the conversion's to grant, and stamping it here would claim a
-- conversion that has not run.

-- ---------------------------------------------------------------- function
create or replace function private.stamp_authority_for_new_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    -- `on conflict do nothing`: the one-shot may have raced us, and its row
    -- is the better one -- it carries real conservation figures. Ours only
    -- has to exist early enough to be read.
    -- ONLY the four columns that decide authority, plus the key. The
    -- conservation counters are deliberately left NULL and NOT zeroed.
    --
    -- Zeroing them asserts a measurement that never happened. Worse, it
    -- sticks: once this row exists the account is authoritative, so
    -- `unmigratedCount > 0 || !authoritative` is false on every later sync
    -- and the one-shot never runs to replace them. A monitoring query
    -- comparing source_non_wage_cents to shift_non_wage_cents would then
    -- read 0 = 0 and report conservation holding, having measured nothing.
    -- Caught in the local smoke: an account stamped here and then given a
    -- legacy row through the fold showed src=0 shift=0 while actually
    -- holding 5000c.
    --
    -- NULL means "not measured". Zero means "measured, and it was zero".
    -- The client reads only user_id, migrated_at, rollback_at,
    -- conservation_failed_at and remaining_group_count
    -- (`RemoteShiftMigrationState.columns`), so leaving the rest NULL costs
    -- it nothing.
    --
    -- `remaining_group_count = 0` IS honest here: at account creation there
    -- are provably no groups left to convert. `last_run_at` stays NULL
    -- because the one-shot has not run.
    insert into public.shift_migration_state (
      user_id, migrated_at, remaining_group_count
    )
    values (new.id, now(), 0)
    on conflict (user_id) do nothing;
  exception when others then
    -- Deliberately swallowed. See the header: raising here fails the signup.
    -- There is no logging because a RAISE NOTICE inside the auth transaction
    -- is noise in someone else's logs, and the observable consequence of
    -- this failing is simply that the account flips on its first sync like
    -- it does today.
    null;
  end;
  return new;
end;
$$;

revoke all on function private.stamp_authority_for_new_account() from public, anon, authenticated;

-- The trigger is created ONLY where the executing role could also drop it.
-- Measured on hosted Supabase (see the runbook): `postgres` holds TRIGGER on
-- `auth.users` but not ownership, so CREATE succeeds and DROP fails -- an
-- installable, unremovable trigger inside the live signup transaction. On the
-- local cluster `postgres` owns `auth.users`, so the trigger exists there and
-- the tests still exercise it. This guard is what makes the file safe under a
-- bulk `db push`: where it cannot be rolled back, it does not exist.
do $$
declare
  can_drop boolean;
begin
  select (select rolsuper from pg_roles where rolname = current_user)
      or pg_has_role(current_user, c.relowner, 'member')
    into can_drop
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'auth' and c.relname = 'users';

  if coalesce(can_drop, false) then
    drop trigger if exists users_stamp_shift_authority on auth.users;
    execute 'create trigger users_stamp_shift_authority
               after insert on auth.users
               for each row execute function private.stamp_authority_for_new_account()';
  else
    raise notice 'users_stamp_shift_authority not created: % cannot drop triggers on auth.users', current_user;
  end if;
end;
$$;

-- ---------------------------------------------------------------- backfill
-- Existing accounts that have never held a legacy row. Same fact, same
-- certainty: zero `tip_entries` means there is nothing a conversion could
-- convert, so authority is not being claimed ahead of work.
--
-- An account WITH legacy rows is deliberately excluded even if they are all
-- soft-deleted, because `deleted_at` is a client-visible state and the fold
-- still reasons about those rows. Let the one-shot own those.
insert into public.shift_migration_state (
  user_id, migrated_at, remaining_group_count
)
select u.id, now(), 0
from auth.users u
where not exists (select 1 from public.shift_migration_state s where s.user_id = u.id)
  and not exists (select 1 from public.tip_entries t where t.user_id = u.id)
on conflict (user_id) do nothing;
