-- PR 6, group 2.14, part 1: the server-issued watermark and the snapshot it
-- stamps.
--
-- Design 3 makes the app the only thing that does money math and the server a
-- place that stores the answer. For that to be safe the server must be able to
-- say "the dataset you computed from is the dataset I still hold", and it must
-- say it with a number the DEVICE CANNOT MINT. Two devices disagreeing about
-- the clock is the whole reason this is a server watermark rather than a
-- timestamp.
--
-- ============================================================================
-- DESIGN CORRECTION: the watermark is its own table, NOT a user_settings column
-- ============================================================================
--
-- PAYDAYCORE_PLAN.md:188 says `user_settings.dataset_revision bigint not null
-- default 0`, incremented by a trigger that "extends touch_versioned_row".
-- Both halves are wrong, and the first one silently.
--
-- MEASURED, not reasoned:
--
--   * `public.shifts.user_id` references `auth.users(id)`, not
--     `public.user_settings`. So a shift for a user with NO settings row is
--     representable.
--   * A `user_settings` row is created only by `import_user_settings` /
--     `upsert_user_settings` -- a settings sync. Nothing creates one at
--     signup.
--
-- Put the watermark on `user_settings` and the bump is `update ... where
-- user_id = $1`, which affects ZERO ROWS when that row is absent. The revision
-- stays 0 while shifts change underneath it, a snapshot stamped 0 stays
-- "current" forever, and `/v1/summary` serves a stale total while reporting
-- `stale: false`. That is precisely the class of defect PaydayCore exists to
-- remove: two surfaces disagreeing, with the wrong one claiming confidence.
--
-- The second half is a plain category error: `touch_versioned_row` is a BEFORE
-- UPDATE trigger that bumps the version of THE ROW BEING UPDATED. The watermark
-- has to move when a DIFFERENT table changes, so there is nothing to extend.
--
-- `public.dataset_revisions` removes both problems rather than guarding
-- against them. The bump is an UPSERT, so it cannot miss a user who has no
-- row yet; and the table carries no `version` trigger, so a cross-table bump
-- cannot recurse into `touch_versioned_row` or be double counted by it.
--
-- ============================================================================

create table public.dataset_revisions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  -- Monotonic per user, and meaningful only by comparison. Nothing should read
  -- its magnitude: it counts STATEMENTS that touched the user's money-bearing
  -- data, not shifts, not edits, not anything a person would recognise. The
  -- only valid operations are equality against a stamp and ordering against
  -- another revision. (Same trap as `shift_migration_state.remaining_group_count`,
  -- which was nearly rendered to users as a shift count.)
  revision bigint not null default 0 check (revision >= 0),
  updated_at timestamptz not null default now()
);

comment on table public.dataset_revisions is
  'Server-issued watermark per user. Bumped by any statement touching that '
  'user''s shifts, paycheck_records or user_settings. A device stamps an '
  'uploaded snapshot with the revision it computed from; the server accepts '
  'the snapshot only while that revision is still current.';
comment on column public.dataset_revisions.revision is
  'Compare it, never render it. Counts statements, not shifts.';

alter table public.dataset_revisions enable row level security;
create policy dataset_revisions_read_own on public.dataset_revisions
  for select to authenticated using ((select auth.uid()) = user_id);
revoke all on table public.dataset_revisions from anon, authenticated;
grant select on table public.dataset_revisions to authenticated;

-- ---------------------------------------------------------------------------
-- The bump.
--
-- STATEMENT level with transition tables, not row level, and the reason is
-- `import_shifts`: a bulk insert of 200 rows under a row-level trigger issues
-- 200 updates to the same watermark row, each taking the same lock. One bump
-- per statement per user is both cheaper and more honest -- the revision is a
-- change detector, and 200 is not more changed than 1.
--
-- Two functions rather than one, because a trigger can only reference the
-- transition tables its own definition declares: an INSERT trigger has no OLD
-- TABLE, and referencing one that was not declared is an error rather than an
-- empty set.
-- ---------------------------------------------------------------------------

create or replace function private.bump_dataset_revision(p_user_ids uuid[])
returns void language sql security definer set search_path = '' as $$
  insert into public.dataset_revisions as d (user_id, revision, updated_at)
  select distinct u, 1, now() from unnest(p_user_ids) as u
  where u is not null
    -- ACCOUNT DELETION. Without this clause the migration BREAKS
    -- `delete_my_account` outright, and it does so the first time anyone
    -- deletes an account rather than under some rare interleaving.
    --
    -- Deleting an `auth.users` row cascades to that user's shifts. The AFTER
    -- DELETE statement trigger below then fires and tries to record a bump
    -- for a user whose parent row is already gone, and the foreign key
    -- rejects it with 23503 -- aborting the whole deletion. Measured, not
    -- predicted: every other SQL suite in this directory failed on this the
    -- first time the migration ran locally, including
    -- `delete_my_account_still_succeeds_with_the_fold_installed`.
    --
    -- Skipping is the right answer rather than merely the working one. A
    -- watermark exists so a device can ask "is the dataset I computed from
    -- still the one you hold"; for a deleted account there is no dataset and
    -- no device left to ask. `dataset_revisions` is itself `on delete
    -- cascade`, so the row goes with the user regardless.
    and exists (select 1 from auth.users au where au.id = u)
  -- The UPSERT is the other half. `update ... where user_id = $1` is what
  -- silently does nothing for a user who has never synced settings.
  on conflict (user_id) do update
    set revision = d.revision + 1, updated_at = now();
$$;

create or replace function private.bump_revision_from_new()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.bump_dataset_revision(array(select distinct user_id from new_rows));
  return null;
end $$;

create or replace function private.bump_revision_from_old()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.bump_dataset_revision(array(select distinct user_id from old_rows));
  return null;
end $$;

-- `from public, anon, ...` -- and the `public` is load-bearing, not noise.
-- PostgreSQL grants EXECUTE on every new function to the PUBLIC pseudo-role
-- by default, and revoking from `anon` does NOT remove a grant held by
-- PUBLIC that `anon` merely inherits. Written without it first; the suite's
-- `anonHasNoExecuteOnTheSnapshotRpc` and `theBumpIsNotCallableByAClient`
-- both failed, which is the only reason this comment exists rather than a
-- reachable private bump on a shipped schema.
revoke all on function private.bump_dataset_revision(uuid[]) from public, anon, authenticated;
revoke all on function private.bump_revision_from_new() from public, anon, authenticated;
revoke all on function private.bump_revision_from_old() from public, anon, authenticated;

-- Every table whose contents can change a number the engine computes. If a
-- future table joins that set, it needs its three triggers here, and the
-- `theWatermarkCoversEveryMoneyBearingTable` assertion in the test suite is
-- what will notice that it does not.
do $$
declare t text;
begin
  foreach t in array array['shifts', 'paycheck_records', 'user_settings'] loop
    execute format(
      'create trigger %I after insert on public.%I '
      'referencing new table as new_rows for each statement '
      'execute function private.bump_revision_from_new()', t || '_bump_revision_ins', t);
    execute format(
      'create trigger %I after update on public.%I '
      'referencing new table as new_rows for each statement '
      'execute function private.bump_revision_from_new()', t || '_bump_revision_upd', t);
    execute format(
      'create trigger %I after delete on public.%I '
      'referencing old table as old_rows for each statement '
      'execute function private.bump_revision_from_old()', t || '_bump_revision_del', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- The snapshot.
-- ---------------------------------------------------------------------------

create table public.earnings_snapshots (
  user_id uuid primary key references auth.users(id) on delete cascade,
  dataset_revision bigint not null check (dataset_revision >= 0),
  engine_version integer not null check (engine_version >= 1),
  manifest_digest text not null check (manifest_digest <> ''),
  as_of date not null,
  -- `jsonb_typeof` FIRST. A CHECK that casts a jsonb field aborts the statement
  -- uncatchably when the value is the wrong type, which is not a constraint
  -- violation the caller can handle -- measured on Postgres 17.11 during the
  -- PR 2 rounds and recorded in PAYDAYCORE_GOAL.md.
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  uploaded_at timestamptz not null default now()
);

comment on table public.earnings_snapshots is
  'One row per user: the engine''s own answer, computed on device by '
  'PaydayCore and accepted only against a current dataset_revision. The '
  'server does no money math; /v1/summary reads this payload.';

alter table public.earnings_snapshots enable row level security;
create policy earnings_snapshots_read_own on public.earnings_snapshots
  for select to authenticated using ((select auth.uid()) = user_id);
revoke all on table public.earnings_snapshots from anon, authenticated;
grant select on table public.earnings_snapshots to authenticated;

-- ---------------------------------------------------------------------------
-- The acceptance rule.
--
-- SECURITY DEFINER with `auth.uid()` captured FIRST: a security-invoker
-- function reaching into schema `private` fails 42501, and capturing the uid
-- before any other work is what keeps the definer from acting on a caller it
-- has not identified.
--
-- Returns text rather than raising, because `stale_input` is an ORDINARY
-- outcome -- the device simply has not finished syncing -- and an exception
-- would make the uploader's happy path indistinguishable from a real error.
-- ---------------------------------------------------------------------------

create or replace function public.upsert_earnings_snapshot(
  p_dataset_revision bigint,
  p_engine_version integer,
  p_as_of date,
  p_manifest_digest text,
  p_payload jsonb
) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_current bigint;
  v_existing_revision bigint;
  v_existing_engine integer;
begin
  v_uid := (select auth.uid());
  if v_uid is null then
    return 'stale_input';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or p_manifest_digest is null or p_manifest_digest = ''
     or p_engine_version is null or p_engine_version < 1
     or p_as_of is null or p_dataset_revision is null then
    return 'stale_input';
  end if;

  -- A user with no watermark row has had nothing bumped, so their current
  -- revision is 0. Only a snapshot stamped 0 can match, which is correct: it
  -- is the only dataset that has existed.
  v_current := coalesce(
    (select d.revision from public.dataset_revisions d where d.user_id = v_uid), 0);

  -- CONDITION 1: the dataset the device computed from is the one still held.
  -- This is the whole point, and it is an equality rather than a `>=`: a
  -- device that is BEHIND has stale inputs, and a device claiming to be AHEAD
  -- of the server has a number the server never issued.
  if p_dataset_revision <> v_current then
    return 'stale_input';
  end if;

  select s.dataset_revision, s.engine_version
    into v_existing_revision, v_existing_engine
    from public.earnings_snapshots s where s.user_id = v_uid;

  -- CONDITION 2: never move the stored answer backwards. Monotonicity comes
  -- from the SERVER's revision, never from a device clock, because two devices
  -- with skewed clocks would otherwise take turns overwriting each other.
  if v_existing_revision is not null
     and not (p_dataset_revision > v_existing_revision
              or (p_dataset_revision = v_existing_revision
                  and p_engine_version >= v_existing_engine)) then
    return 'stale_input';
  end if;

  insert into public.earnings_snapshots as e
    (user_id, dataset_revision, engine_version, manifest_digest, as_of, payload, uploaded_at)
  values (v_uid, p_dataset_revision, p_engine_version, p_manifest_digest, p_as_of, p_payload, now())
  on conflict (user_id) do update
    set dataset_revision = excluded.dataset_revision,
        engine_version   = excluded.engine_version,
        manifest_digest  = excluded.manifest_digest,
        as_of            = excluded.as_of,
        payload          = excluded.payload,
        uploaded_at      = now();

  -- NOTE: this INSERT does NOT bump the watermark, and must not. The snapshot
  -- is a statement ABOUT the dataset, not a part of it. A snapshot table with
  -- a bump trigger would invalidate every upload the instant it landed.
  return 'accepted';
end $$;

revoke all on function public.upsert_earnings_snapshot(bigint, integer, date, text, jsonb)
  from public, anon;
grant execute on function public.upsert_earnings_snapshot(bigint, integer, date, text, jsonb)
  to authenticated;

-- The reader the device needs before it can upload: what revision am I at?
create or replace function public.payday_dataset_revision()
returns bigint language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select d.revision from public.dataset_revisions d where d.user_id = (select auth.uid())), 0);
$$;

revoke all on function public.payday_dataset_revision() from public, anon;
grant execute on function public.payday_dataset_revision() to authenticated;
