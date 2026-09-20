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
-- WHAT THIS SUITE IS FOR. The trigger exists to close a first-run window: a
-- new account had no `shift_migration_state` row until its first sync ran the
-- one-shot, so read authority arrived a round-trip late and the account spent
-- that gap on the legacy arm. The two properties that make the fix safe are
-- both easy to assert and were both nearly reasoned about instead:
--
--   1. The trigger CANNOT fail signup. It runs inside the auth transaction.
--   2. It records only what it measured. The conservation counters stay NULL.
--
-- Property 1 needs a CONTROL, and that is the whole reason this file exists
-- rather than a comment. "The account was still created" passes trivially if
-- the trigger never fired at all, so the suite also installs an UNGUARDED
-- raise and asserts that one DOES block the insert. Without that, the
-- important assertion is indistinguishable from a no-op.

begin;

create temporary table results (name text, ok boolean) on commit drop;

-- ---------------------------------------------------------------- creation
insert into auth.users (id, email)
values ('aaaaaaaa-1111-1111-1111-111111111111', 'creation@test.invalid');

insert into results
select 'creation stamps exactly one row',
       count(*) = 1
from public.shift_migration_state
where user_id = 'aaaaaaaa-1111-1111-1111-111111111111';

insert into results
select 'the stamped row satisfies all four authority conditions',
       coalesce(bool_and(
         migrated_at is not null
         and rollback_at is null
         and conservation_failed_at is null
         and remaining_group_count = 0
       ), false)
from public.shift_migration_state
where user_id = 'aaaaaaaa-1111-1111-1111-111111111111';

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
from public.shift_migration_state
where user_id = 'aaaaaaaa-1111-1111-1111-111111111111';

-- ------------------------------------------------- the fold still converts
-- An account stamped at creation that LATER acquires a legacy row -- the
-- agent API at /v1, or any non-app writer. The fold trigger hangs on
-- `public.tip_entries` at statement level and is not gated on the account's
-- migration state, so the row must still become a shift. If it did not, this
-- trigger would have stranded money on a surface nothing reads.
insert into auth.users (id, email)
values ('aaaaaaaa-2222-2222-2222-222222222222', 'fold@test.invalid');

insert into public.tip_entries (id, user_id, work_date, amount_cents, kind, hours_worked, client_updated_at)
values ('bbbbbbbb-2222-2222-2222-222222222222',
        'aaaaaaaa-2222-2222-2222-222222222222',
        '2026-09-10', 5000, 'credit', 5, now());

insert into results
select 'a legacy row written to a stamped account is still folded into shifts',
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

-- ------------------------------------------------------------- idempotence
-- The one-shot may have raced the trigger. Its row is the better one: it
-- carries real figures. `on conflict do nothing` means a second creation
-- cannot clobber it.
update public.shift_migration_state
   set source_non_wage_cents = 4242
 where user_id = 'aaaaaaaa-2222-2222-2222-222222222222';

insert into results
select 'a real measurement is never clobbered by the creation stamp',
       coalesce(bool_and(source_non_wage_cents = 4242), false)
from public.shift_migration_state
where user_id = 'aaaaaaaa-2222-2222-2222-222222222222';

-- ------------------------------------------------------------- the cascade
delete from auth.users where id = 'aaaaaaaa-1111-1111-1111-111111111111';

insert into results
select 'deleting the account removes its state row',
       count(*) = 0
from public.shift_migration_state
where user_id = 'aaaaaaaa-1111-1111-1111-111111111111';

-- ------------------------------------------------- signup survives a raise
-- THE ASSERTION THIS SUITE EXISTS FOR. A trigger on auth.users runs inside
-- the auth service's transaction, so a raise fails ACCOUNT CREATION. That
-- trades a display window for a lockout, which is strictly worse.
create or replace function private.stamp_authority_for_new_account()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  begin
    raise exception 'deliberate failure, guarded';
  exception when others then
    null;
  end;
  return new;
end;
$fn$;

insert into auth.users (id, email)
values ('aaaaaaaa-3333-3333-3333-333333333333', 'guarded@test.invalid');

insert into results
select 'a raising-but-guarded trigger body does not block signup',
       count(*) = 1
from auth.users
where id = 'aaaaaaaa-3333-3333-3333-333333333333';

insert into results
select 'and it degrades to exactly today''s behaviour: no row, flip on first sync',
       count(*) = 0
from public.shift_migration_state
where user_id = 'aaaaaaaa-3333-3333-3333-333333333333';

-- THE CONTROL. Without this, the assertion above passes just as happily when
-- the trigger never fires, which is the difference between a test and a
-- decoration.
create or replace function private.stamp_authority_for_new_account()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  raise exception 'deliberate failure, UNGUARDED';
end;
$fn$;

do $$
begin
  begin
    insert into auth.users (id, email)
    values ('aaaaaaaa-4444-4444-4444-444444444444', 'unguarded@test.invalid');
  exception when others then
    null;
  end;
end;
$$;

insert into results
select 'CONTROL: an unguarded raise DOES block signup, so the test above means something',
       count(*) = 0
from auth.users
where id = 'aaaaaaaa-4444-4444-4444-444444444444';

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

rollback;
