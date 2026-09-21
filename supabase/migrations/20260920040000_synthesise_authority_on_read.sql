-- Close the first-run authority window on the READ path, where it reaches
-- users who already have the app.
--
-- ## Why not a trigger on auth.users
--
-- The previous attempt (#133, closed) stamped a row from a trigger on
-- `auth.users`. Measured on production: that table is owned by
-- `supabase_auth_admin`, `postgres` is not a superuser and cannot `SET ROLE`
-- to it. We hold the TRIGGER privilege, which is enough to CREATE, and not
-- ownership, which is what DROP requires. Installable and not removable, in
-- the live signup path. Everything here lives in `public`, which we own.
--
-- ## Why the read path and not the client
--
-- The window harms people downloading from the App Store right now, and what
-- they get is 1.0. A client change ships through review and reaches them
-- last. `PaydaySyncService.swift:211` reads
-- `.from("shift_migration_state")`, and PostgREST resolves that against a
-- VIEW exactly as against a table -- so the existing binary gets the
-- synthesised answer with no build. Reversibility and reach are different
-- axes; this is the only option with both.
--
-- ## The base table is renamed to a NON-SUPERSTRING name, deliberately
--
-- `shift_migration_ledger`, not `shift_migration_state_rows`. The obvious
-- name contains the view's name as a substring, which poisons the
-- verification gate below: a function correctly referencing the base table
-- would match `like '%shift_migration_state%'` and then need an exclusion
-- clause to suppress it -- and that exclusion would also suppress any OTHER
-- reference the same function makes to the bare name. A function reading the
-- base table in one statement and the view in another would pass a gate
-- built to catch exactly that. Choosing a name that cannot collide deletes
-- the problem instead of computing around it.

-- --------------------------------------------------------------- 1. rename
alter table public.shift_migration_state rename to shift_migration_ledger;

-- ------------------------------------------------------------ 2. repoint
-- Every function whose body names the old relation is regenerated against
-- the new one. Done by rewriting `pg_get_functiondef` rather than by hand:
-- there are 44 textual references across 7 migrations and a hand-transcribed
-- list is the thing the gate below exists to distrust.
--
-- Safe because `search_path = ''` is set on all of them, so every reference
-- is schema-qualified and explicit -- there is no unqualified name that could
-- resolve somewhere unexpected, which is what makes a textual rewrite
-- trustworthy here rather than reckless.
do $$
declare
  fn record;
  src text;
begin
  for fn in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and p.prosrc like '%shift_migration_state%'
  loop
    src := pg_get_functiondef(fn.oid);
    src := replace(src, 'shift_migration_state', 'shift_migration_ledger');
    execute src;
  end loop;
end;
$$;

-- ------------------------------------------------- 2b. the derived predicate
-- `shift_fold_failures` is keyed on `id` alone, so an `exists` by user_id
-- would sequential-scan it on EVERY sync read. Indexed here rather than
-- dropped from the predicate: a failure is exactly the case that must read
-- NOT authoritative, so leaving it out to save a scan would remove the
-- fail-closed branch.
create index if not exists shift_fold_failures_user_idx
  on private.shift_fold_failures (user_id);

-- Takes the user id as an ARGUMENT rather than reading `auth.uid()`.
-- `payday_unmigrated_tip_row_count()` returns 0 for a null uid, so an
-- unauthenticated caller and a genuinely-empty account are the same value --
-- and a false zero here would read as "nothing outstanding, trust shifts".
-- Passing the id in removes that case instead of guarding it.
create or replace function public.payday_nothing_unconverted(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null
     and not exists (select 1 from private.unmigrated_legacy_rows(p_user_id))
     and not exists (select 1 from private.shift_fold_backlog b where b.user_id = p_user_id)
     and not exists (select 1 from private.shift_fold_failures f where f.user_id = p_user_id);
$$;

revoke all on function public.payday_nothing_unconverted(uuid) from public, anon;
grant execute on function public.payday_nothing_unconverted(uuid) to authenticated;

-- --------------------------------------------------------------- 3. view
-- EXACTLY the five columns the client reads
-- (`RemoteShiftMigrationState.columns`), and deliberately not one more.
--
-- The narrow view is the safer one and the asymmetry is on READERS. A
-- server-side reader wanting a conservation counter gets
-- `column "..." does not exist` -- loud. Were every column exposed, that same
-- reader would silently receive a synthesised row with NULL counters and
-- carry on. For WRITERS the width makes no difference: the fold swallows
-- either failure identically into `private.shift_fold_failures`. A loud
-- failure is one of the few still available here.
--
-- `security_invoker = on` is load-bearing and DEMONSTRATED, not assumed:
-- without it a read by user A returns BOTH accounts' rows, because the view
-- would evaluate `sms_read_own` as its owner. That is a cross-account read,
-- categorically worse than the window being closed.
--
-- ## The view answers a DERIVED question, and that is the point
--
-- `migrated_at` records "the conversion pass completed for this account."
-- The client is asking something else: "should I trust `shifts`?" Those are
-- different questions, and the second is derived from the first plus current
-- state. Answering it where it is read keeps ONE recorded fact with ONE
-- writer.
--
-- **`migrated_at` keeps exactly one writer: the one-shot.** Nothing here
-- writes it and nothing new should. The rejected alternative was to have the
-- fold stamp it too, which would make one column mean both "the conversion
-- completed" and "a live legacy write was folded" -- two facts in one column,
-- read by every conservation check. Compare the note at
-- `PaydaySyncState.swift:710`: a field meaning "these agreed at an instant"
-- is only correct if exactly one place decides when that instant was.
--
-- ## Why deriving is also MORE correct
--
-- A fold that FAILS leaves a backlog row, so the account reads NOT
-- authoritative -- which is right, because something did not convert and
-- `shifts` is incomplete. Had the fold stamped `migrated_at` instead, the
-- stamp would already be written and the account would read authoritative
-- over incomplete data. Authority tracks the invariant rather than an event
-- that happened once.
--
-- ## Fails closed
--
-- Every branch of `nothing_unconverted` must be provably empty. Anything
-- undetermined leaves `migrated_at` as recorded -- NULL for a fold-written
-- row -- so the account reads NOT authoritative. The inconclusive answer is
-- never "trust shifts".
create view public.shift_migration_state
with (security_invoker = on) as
  select
    l.user_id,
    -- Derived, never written back. Only ever ADDS authority to a row with
    -- nothing outstanding; it cannot remove a recorded rollback or
    -- conservation failure, which pass through untouched below.
    --
    -- SHORT-CIRCUITED ON `migrated_at is not null`, and that is a
    -- correctness-preserving optimisation rather than a cosmetic one. A row
    -- that already carries a stamp needs nothing derived, so the predicate
    -- is not called at all for it. MEASURED: evaluating it unconditionally
    -- cost 778 shared buffers against 2 for the base table, on a nearly
    -- empty database, for a query the client runs on EVERY sync. With the
    -- short-circuit the expensive branch runs only for rows with no stamp --
    -- new accounts and fold-written rows -- which are the small-data cases
    -- by construction.
    case when l.migrated_at is not null then l.migrated_at
         when public.payday_nothing_unconverted(l.user_id) then now()
         else null end                                         as migrated_at,
    l.rollback_at,
    l.conservation_failed_at,
    case when l.remaining_group_count = 0 then 0
         when l.migrated_at is not null then coalesce(l.remaining_group_count, 1)
         when public.payday_nothing_unconverted(l.user_id) then 0
         else coalesce(l.remaining_group_count, 1) end         as remaining_group_count
  from public.shift_migration_ledger l
  union all
  -- The account with no ledger row at all: a new signup. Derived from
  -- `auth.uid()` and NOT by scanning `auth.users`, which `authenticated`
  -- cannot read under `security_invoker`.
  select (select auth.uid()), now(), null::timestamptz, null::timestamptz, 0
   where (select auth.uid()) is not null
     and not exists (select 1 from public.shift_migration_ledger l
                      where l.user_id = (select auth.uid()))
     and public.payday_nothing_unconverted((select auth.uid()));

revoke all on public.shift_migration_state from public, anon;
grant select on public.shift_migration_state to authenticated;

-- ---------------------------------------------------------------- 4. gate
-- The assertion that makes the repointing above a fact rather than a claim.
--
-- No exclusion clause, because the new name cannot contain the old one. That
-- is the entire reason for the rename choice: a gate with an exception is a
-- gate with a place to be wrong, and this one is checking my own
-- thoroughness, which is exactly what should not be taken on trust.
--
-- Covers functions, RLS policy expressions and other views. Runs in the SAME
-- transaction as the rename, so a miss rolls the whole thing back rather than
-- leaving a half-repointed database.
do $$
declare
  offenders text;
begin
  select string_agg(what, E'\n  ') into offenders from (
    select 'function ' || n.nspname || '.' || p.proname as what
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private')
       and p.prosrc like '%shift_migration_state%'
    union all
    select 'policy ' || pol.polname || ' on ' || pol.polrelid::regclass::text
      from pg_policy pol
     where coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') like '%shift_migration_state%'
        or coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') like '%shift_migration_state%'
    union all
    select 'view ' || schemaname || '.' || viewname
      from pg_views
     where schemaname in ('public', 'private')
       and viewname <> 'shift_migration_state'
       and definition like '%shift_migration_state%'
  ) s;

  if offenders is not null then
    raise exception E'these still reference the old relation name after the rename:\n  %', offenders;
  end if;
end;
$$;
