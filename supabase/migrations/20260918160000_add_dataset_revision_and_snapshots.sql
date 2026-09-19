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
-- WHY THIS IS A DEFERRED CONSTRAINT TRIGGER. Read before changing it.
--
-- The first version of this migration used STATEMENT-level AFTER triggers
-- that bumped inside the writing transaction. It was merged as 0f4f1bc and
-- REVERTED as c93489d, because it WEDGED `scripts/db-test-race.sh`
-- indefinitely -- 45+ minutes in CI and past 900s locally, against a healthy
-- baseline of 11.7 seconds. CI's step breakdown put it exactly here: the
-- migration applied, all 28 single-session assertions passed, and
-- "SQL concurrency tests" never returned.
--
-- The cause was not "a shared row". It was WHEN the row was locked.
--
-- A deadlock needs a transaction to HOLD lock A while WAITING for lock B,
-- with another transaction holding B and wanting A. Bumping inside the
-- statement meant a writer took the watermark row lock EARLY and then kept
-- it for the rest of the transaction while going on to acquire shift row
-- locks and the fold's advisory lock (`payday:shiftmig`). That makes the
-- watermark a permanent "held" edge in every write's lock graph, on all
-- three money tables at once, and cycles become available immediately.
--
-- Worse than a deadlock, which Postgres at least detects and breaks: the
-- race suite's own helpers time out in 30s and exit, so a HANG rather than a
-- FAILURE meant a session was blocked in `wait "$BPID"` with no timeout --
-- a background write that never returned.
--
-- That is a PRODUCTION defect, not a test artefact. "The fold never rejects
-- and never blocks a shipped 1.0 build's write" is the rule the entire PR 2
-- shape was chosen to hold, and a 1.0 client's write could block behind
-- another session's watermark update.
--
-- DEFERRABLE INITIALLY DEFERRED fixes it structurally rather than by
-- tuning. The trigger fires at COMMIT, after every other lock this
-- transaction will ever take has already been acquired and released-on-commit.
-- So the watermark is always acquired LAST, and a lock acquired last can
-- never be the held edge of a cycle -- there is nothing afterwards to wait
-- for. Two writers for the same user still serialise, but for the microseconds
-- between the deferred trigger and COMMIT, not for the lifetime of the
-- transaction. The race suite holds a transaction open for 6 seconds on
-- purpose; under a deferred trigger that session holds no watermark lock at
-- all during those 6 seconds.
--
-- The cost, stated rather than hidden: `CREATE CONSTRAINT TRIGGER` is
-- FOR EACH ROW only -- statement-level is not available for deferrable
-- triggers -- so the statement-level batching of the first version is gone.
-- A transaction-local guard replaces it: the first row to fire records a
-- flag with `set_config(..., is_local => true)`, which Postgres discards at
-- transaction end, and the remaining rows return immediately. One bump per
-- user per transaction either way, which is what a change DETECTOR needs;
-- 500 rows is not more changed than 1.
-- ---------------------------------------------------------------------------

create or replace function private.bump_revision_row()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid;
  v_key text;
begin
  v_uid := case when tg_op = 'DELETE' then old.user_id else new.user_id end;
  if v_uid is null then
    return null;
  end if;

  -- One bump per user per transaction. `is_local => true` scopes the flag to
  -- the transaction, so it cannot leak into the next statement on a pooled
  -- connection -- which a session-level GUC absolutely would, and would then
  -- silently suppress a real bump for the next request on that connection.
  v_key := 'payday.revbump_' || replace(v_uid::text, '-', '');
  if coalesce(current_setting(v_key, true), '') = '1' then
    return null;
  end if;
  perform set_config(v_key, '1', true);

  -- ACCOUNT DELETION. Deleting an `auth.users` row cascades to the user's
  -- shifts; without this the trigger records a bump for a user whose parent
  -- row is already gone and the foreign key aborts the deletion with 23503.
  -- Measured: every other SQL suite failed on it, including
  -- `delete_my_account_still_succeeds_with_the_fold_installed`.
  if not exists (select 1 from auth.users au where au.id = v_uid) then
    return null;
  end if;

  insert into public.dataset_revisions as d (user_id, revision, updated_at)
  values (v_uid, 1, now())
  -- The UPSERT, not an UPDATE. `update ... where user_id = $1` silently
  -- affects zero rows for a user who has never synced settings, which is the
  -- hole that made `user_settings.dataset_revision` unusable.
  on conflict (user_id) do update
    set revision = d.revision + 1, updated_at = now();

  return null;
end $$;

-- `from public, anon, ...` -- and the `public` is load-bearing, not noise.
-- PostgreSQL grants EXECUTE on every new function to the PUBLIC pseudo-role
-- by default, and revoking from `anon` does NOT remove a grant held by
-- PUBLIC that `anon` merely inherits.
revoke all on function private.bump_revision_row() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- LOAD-BEARING ASSUMPTION: ONE USER PER WRITE TRANSACTION.
--
-- The deferral argument above covers ONE watermark row. It does not cover
-- two. Deferred triggers are FOR EACH ROW and fire at commit once per touched
-- row IN TOUCH ORDER, so a transaction writing for users (A, B) racing one
-- writing for (B, A) acquires two watermark rows in opposite orders and a
-- cycle is constructible again.
--
-- No such write path exists today. Every write into `shifts`,
-- `paycheck_records` and `user_settings` is scoped to `auth.uid()`; nothing
-- takes a user_id array or loops users. So this is an ASSUMPTION the design
-- rests on, not a defect -- and the first multi-user backfill someone writes
-- later would violate it silently, which is why it is written here and
-- asserted in `scripts/db-test-race.sh` rather than left to be rediscovered.
--
-- MEASURED, because "deadlock" and "hang" are different severities and only
-- one of them is what 0f4f1bc actually did: two transactions writing (A,B)
-- and (B,A) produce `ERROR: deadlock detected` in about 3 seconds.
-- PostgreSQL detects and breaks it, one side gets 40P01 and can retry. It
-- does NOT wedge. So violating this assumption degrades to a retryable error
-- rather than to the indefinite block that caused the revert.
--
-- `aTwoUserTransactionTerminatesRatherThanWedging` asserts the property that
-- matters -- that it finishes -- rather than that it deadlocks, so a future
-- change making it genuinely safe does not fail the test.
-- ---------------------------------------------------------------------------

-- Every table whose contents can change a number the engine computes. If a
-- future table joins that set it needs its trigger here, and
-- `theWatermarkCoversEveryMoneyBearingTable` is what will notice it does not.
do $$
declare t text;
begin
  foreach t in array array['shifts', 'paycheck_records', 'user_settings'] loop
    execute format(
      'create constraint trigger %I after insert or update or delete on public.%I '
      'deferrable initially deferred '
      'for each row execute function private.bump_revision_row()',
      t || '_bump_revision', t);
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
