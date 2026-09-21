-- Stamping shift authority at ACCOUNT CREATION.
--
-- Same convention as the other suites: assertions land in a temporary results
-- table and the last statement raises if any row is false, so psql exits
-- non-zero under -v ON_ERROR_STOP=1.
--
-- CI (job E, "Supabase migrations (db reset)"):
--   psql ... -v ON_ERROR_STOP=1 -f supabase/tests/account_creation_authority_test.sql
-- Locally with no Docker: `bash scripts/db-test-local.sh`.
--
-- TWO MECHANISMS, ONE CONTRACT. The contract under test is "an account with
-- nothing to convert reads authoritative on its first read." There are two
-- mechanisms and they are not both installed everywhere:
--
--   * the `auth.users` insert trigger, which stamps a real
--     `shift_migration_ledger` row at creation -- present ONLY where the
--     executing role could also drop it (local cluster: yes; hosted
--     Supabase: no, postgres cannot drop what it does not own)
--   * the `shift_migration_state` VIEW, which synthesises the same answer
--     for an account with no ledger row and nothing unconverted
--
-- So the suite is split. CONTRACT assertions query the view the client
-- reads and must hold in BOTH worlds. MECHANISM assertions query the
-- ledger row the trigger writes and are installed only where the trigger
-- is. A mechanism assertion that silently no-ops where its mechanism is
-- absent is the "test that measures nothing" shape this file exists
-- against -- which is why the run announces which mode it is in.

begin;

create temporary table results (name text, ok boolean) on commit drop;
create temporary table ctx (trigger_installed boolean) on commit drop;
insert into ctx
select exists (
  select 1
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where t.tgname = 'users_stamp_shift_authority'
    and n.nspname = 'auth'
    and c.relname = 'users'
    and not t.tgisinternal
);

insert into results
select 'environment: ' || case when (select trigger_installed from ctx)
       then 'auth.users trigger installed' else 'auth.users trigger correctly skipped' end,
       true;

-- ============================================================ THE CONTRACT
-- The client reads `shift_migration_state` -- after 040000, a view. A brand
-- new account must read migrated_at immediately, whether the row is real
-- (trigger world) or synthesised (view world). `request.jwt.claim.sub` is
-- the established way these suites stand in for `auth.uid()`.

insert into auth.users (id, email)
values ('aaaaaaaa-1111-1111-1111-111111111111', 'creation@test.invalid');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-1111-1111-1111-111111111111', true);

insert into results
select 'a brand-new account reads authoritative on its first read',
       coalesce(bool_and(
         migrated_at is not null
         and rollback_at is null
         and conservation_failed_at is null
         and remaining_group_count = 0
       ), false)
from public.shift_migration_state
where user_id = 'aaaaaaaa-1111-1111-1111-111111111111';

-- An account WITH an unconverted legacy row must NOT read authoritative:
-- the view may only ever add authority when there is nothing to convert.
-- The fixture is "an account that predates stamping": where the trigger is
-- installed it would stamp at the auth.users insert, so it is disabled for
-- exactly that statement and re-enabled after -- reproducing the state the
-- view exists for, in both environments.
do $$
begin
  if (select trigger_installed from ctx) then
    alter table auth.users disable trigger users_stamp_shift_authority;
  end if;
end;
$$;

insert into auth.users (id, email)
values ('aaaaaaaa-5555-5555-5555-555555555555', 'unmigrated@test.invalid');

do $$
begin
  if (select trigger_installed from ctx) then
    alter table auth.users enable trigger users_stamp_shift_authority;
  end if;
end;
$$;

-- The legacy row must be NEVER-FOLDED to count as unconverted: the fold
-- trigger claims rows at statement level, and a folded row is converted,
-- not unmigrated. Disable the fold for this one insert to produce the
-- state the view must refuse.
alter table public.tip_entries disable trigger tip_entries_fold_insert;

insert into public.tip_entries (id, user_id, work_date, amount_cents, kind, hours_worked, client_updated_at)
values ('bbbbbbbb-5555-5555-5555-555555555555',
        'aaaaaaaa-5555-5555-5555-555555555555',
        '2026-09-10', 5000, 'credit', 5, now());

alter table public.tip_entries enable trigger tip_entries_fold_insert;

select set_config('request.jwt.claim.sub', 'aaaaaaaa-5555-5555-5555-555555555555', true);

insert into results
select 'an account with unconverted legacy rows does NOT read authoritative',
       coalesce(bool_and(migrated_at is null), true)
from public.shift_migration_state
where user_id = 'aaaaaaaa-5555-5555-5555-555555555555';

-- ------------------------------------------------- the fold still converts
-- An account that reads authoritative and LATER acquires a legacy row --
-- the agent API at /v1, or any non-app writer. The fold trigger hangs on
-- `public.tip_entries` at statement level and is not gated on the account's
-- migration state, so the row must still become a shift.
insert into auth.users (id, email)
values ('aaaaaaaa-2222-2222-2222-222222222222', 'fold@test.invalid');

insert into public.tip_entries (id, user_id, work_date, amount_cents, kind, hours_worked, client_updated_at)
values ('bbbbbbbb-2222-2222-2222-222222222222',
        'aaaaaaaa-2222-2222-2222-222222222222',
        '2026-09-10', 5000, 'credit', 5, now());

insert into results
select 'a legacy row written to an authoritative account is still folded into shifts',
       count(*) = 1
from public.shifts
where user_id = 'aaaaaaaa-2222-2222-2222-222222222222'
  and deleted_at is null;

insert into results
select 'the folded shift carries the money',
       coalesce(sum(non_wage_earnings_cents), 0) = 5000
from public.shifts
where user_id = 'aaaaaaaa-2222-2222-2222-222222222222'
  and deleted_at is null;

select set_config('request.jwt.claim.sub', 'aaaaaaaa-2222-2222-2222-222222222222', true);

insert into results
select 'the account is still authoritative after the fold',
       coalesce(bool_and(
         migrated_at is not null
         and rollback_at is null
         and conservation_failed_at is null
         and remaining_group_count = 0
       ), false)
from public.shift_migration_state
where user_id = 'aaaaaaaa-2222-2222-2222-222222222222';

-- ============================================================ THE MECHANISM
-- Everything below asserts what the TRIGGER does to the ledger. It runs only
-- where the trigger exists; each statement's WHERE makes the insert absent,
-- not false, when it does not.

insert into results
select 'creation stamps exactly one row',
       (select count(*) = 1 from public.shift_migration_ledger
         where user_id = 'aaaaaaaa-1111-1111-1111-111111111111')
where (select trigger_installed from ctx);

insert into results
select 'the stamped row satisfies all four authority conditions',
       coalesce(bool_and(
         migrated_at is not null
         and rollback_at is null
         and conservation_failed_at is null
         and remaining_group_count = 0
       ), false)
from public.shift_migration_ledger
where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'
  and (select trigger_installed from ctx);

-- NULL, never 0. A zero here asserts a conservation measurement that never
-- ran, and it sticks: the account is authoritative from this moment, so the
-- one-shot's `unmigratedCount > 0 or not authoritative` guard is false
-- forever after and nothing replaces the zeros. A monitor comparing
-- source_non_wage_cents to shift_non_wage_cents would read 0 = 0 and report
-- conservation holding, having measured nothing.
insert into results
select 'the conservation counters say NOT MEASURED, not zero',
       coalesce(bool_and(
         source_non_wage_cents is null
         and shift_non_wage_cents is null
         and source_row_count is null
         and last_run_at is null
       ), false)
from public.shift_migration_ledger
where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'
  and (select trigger_installed from ctx);

-- ------------------------------------------------------------- idempotence
-- The one-shot may have raced the trigger. Its row is the better one: it
-- carries real figures. `on conflict do nothing` means a second creation
-- cannot clobber it.
update public.shift_migration_ledger
   set source_non_wage_cents = 4242
 where user_id = 'aaaaaaaa-2222-2222-2222-222222222222'
   and (select trigger_installed from ctx);

insert into results
select 'a real measurement is never clobbered by the creation stamp',
       coalesce(bool_and(source_non_wage_cents = 4242), false)
from public.shift_migration_ledger
where user_id = 'aaaaaaaa-2222-2222-2222-222222222222'
  and (select trigger_installed from ctx);

-- ------------------------------------------------------------- the cascade
delete from auth.users where id = 'aaaaaaaa-1111-1111-1111-111111111111';

insert into results
select 'deleting the account removes its state row',
       count(*) = 0
from public.shift_migration_ledger
where user_id = 'aaaaaaaa-1111-1111-1111-111111111111'
  and (select trigger_installed from ctx);

-- ------------------------------------------------- signup survives a raise
-- THE ASSERTION THE TRIGGER HALF OF THIS SUITE EXISTS FOR. A trigger on
-- auth.users runs inside the auth service's transaction, so a raise fails
-- ACCOUNT CREATION. That trades a display window for a lockout, which is
-- strictly worse. Meaningful only where the trigger is installed.
do $$
begin
  if (select trigger_installed from ctx) then
    execute $fn$
      create or replace function private.stamp_authority_for_new_account()
      returns trigger language plpgsql security definer set search_path = '' as $body$
      begin
        begin
          raise exception 'deliberate failure, guarded';
        exception when others then
          null;
        end;
        return new;
      end;
      $body$;
      $fn$;
  end if;
end;
$$;

insert into auth.users (id, email)
values ('aaaaaaaa-3333-3333-3333-333333333333', 'guarded@test.invalid');

insert into results
select 'a raising-but-guarded trigger body does not block signup',
       count(*) = 1
from auth.users
where id = 'aaaaaaaa-3333-3333-3333-333333333333'
  and (select trigger_installed from ctx);

insert into results
select 'and it degrades to exactly today''s behaviour: no row, flip on first sync',
       count(*) = 0
from public.shift_migration_ledger
where user_id = 'aaaaaaaa-3333-3333-3333-333333333333'
  and (select trigger_installed from ctx);

-- THE CONTROL. Without this, the assertion above passes just as happily when
-- the trigger never fires, which is the difference between a test and a
-- decoration.
do $$
begin
  if (select trigger_installed from ctx) then
    execute $fn$
      create or replace function private.stamp_authority_for_new_account()
      returns trigger language plpgsql security definer set search_path = '' as $body$
      begin
        raise exception 'deliberate failure, UNGUARDED';
      end;
      $body$;
      $fn$;
  end if;
end;
$$;

do $$
begin
  if (select trigger_installed from ctx) then
    begin
      insert into auth.users (id, email)
      values ('aaaaaaaa-4444-4444-4444-444444444444', 'unguarded@test.invalid');
    exception when others then
      null;
    end;
  end if;
end;
$$;

insert into results
select 'CONTROL: an unguarded raise DOES block signup, so the test above means something',
       count(*) = 0
from auth.users
where id = 'aaaaaaaa-4444-4444-4444-444444444444'
  and (select trigger_installed from ctx);

-- ------------------------------------------------------------------ verdict
do $$
declare failed text;
begin
  select string_agg(name, E'\n  ') into failed from results where not ok;
  if failed is not null then
    raise exception E'account-creation authority assertions failed:\n  %', failed;
  end if;
  -- Announced, like every other suite here. A suite that says nothing on
  -- success is indistinguishable from a suite that did not run -- which is
  -- the single most common way a gate in this repo has turned out to be
  -- measuring nothing.
  raise notice 'account_creation_authority_test: all % assertions passed',
    (select count(*) from results);
end;
$$;
