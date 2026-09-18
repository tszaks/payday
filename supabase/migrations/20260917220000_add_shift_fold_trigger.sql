-- PR 2, slice S4: the on-arrival trigger.
--
-- THE RULE THAT DOMINATES THIS FILE: private.fold_legacy_writes() runs inside
-- the shipped Payday 1.0 build's OWN write transaction, and 1.0 contains no
-- handling for a rejected write. So THE FOLD NEVER RAISES AND NEVER REJECTS.
-- Anything it can fail on becomes an app that goes dark and a device that can
-- never sync again. Everything odd-looking below follows from that one rule:
--
--   * the five-arm exception block, because plpgsql's `when others` does NOT
--     catch 57014 query_canceled (what statement_timeout raises) or
--     assert_failure -- measured, and 57014 is the abort class most likely to
--     hit a 500-row 1.0 batch;
--   * every money value clamped in the deriver rather than validated by a
--     CHECK, and every constraint on public.shifts satisfiable BY
--     CONSTRUCTION from any row public.tip_entries can legally hold;
--   * pg_try_advisory_xact_lock, never the blocking one, because blocking
--     would put an old build's write behind a possibly long migration and
--     into a client-side timeout, which is itself a rejected write;
--   * the reserved 40/10 work budget, because a first sign-in or a
--     checkpoint-loss re-push touches hundreds of groups in one transaction
--     and a timeout means 1.0 retries the identical batch forever;
--   * the account-deletion no-op, because Payday was rejected once over
--     Guideline 5.1.1(v) and an arm that wrote public.shifts during the
--     auth.users cascade would FAIL account deletion.
--
-- The arms themselves (1, 2a, 2b, 3, 4a, 4b) live in private.derive_shifts,
-- the single deriver, which the one-shot calls identically. This file is the
-- delivery mechanism: which accounts, which group keys, which lock, how much
-- work per statement, and what happens when any of it aborts.

-- ---------------------------------------------------------------------------
-- The backlog writer. ONE spelling, because every insert into the backlog
-- must be `on conflict (user_id, group_key) do nothing` in sorted key order.
--
-- Without the ON CONFLICT clause, two concurrent 1.0 writes that both miss
-- the try-lock -- three sessions on one account, or one device retrying while
-- the agent writes, which is the exact population the lock exists for --
-- insert the same key, one waits on the other's uncommitted index entry, and
-- then raises 23505 on commit. The fold's `unique_violation` arm swallows
-- that, which means the keys are dropped from the failing session entirely.
-- With the clause the waiter still waits (ON CONFLICT DO NOTHING waits for a
-- concurrent uncommitted duplicate and then does nothing) but nothing raises
-- and nothing is dropped; the wait is bounded by the other 1.0 statement's
-- transaction, and scripts/db-test-race.sh measures and prints it
-- (two_sessions_queueing_the_same_group_neither_block_nor_raise).
--
-- The auth.users guard is not decoration. private.shift_fold_backlog carries
-- a cascading user_id FK, and this function is also called from the fold's
-- exception handler, which may hold keys for an account whose auth.users row
-- has already gone (measured: during public.delete_my_account()'s cascade the
-- auth.users row is ALREADY invisible and public.shifts has ALREADY been
-- cascaded away by the time the tip_entries DELETE trigger fires). An
-- unguarded insert there would raise 23503 INSIDE the handler, which is
-- exactly the uncatchable abort this whole file exists to prevent.
-- ---------------------------------------------------------------------------

create or replace function private.queue_fold_backlog(
  p_user_id uuid, p_keys uuid[])
returns void language sql security definer set search_path = '' as $$
  insert into private.shift_fold_backlog (user_id, group_key)
  select p_user_id, k
  from unnest(coalesce(p_keys, '{}'::uuid[])) as k
  where k is not null
    and exists (select 1 from auth.users u where u.id = p_user_id)
  order by k
  on conflict (user_id, group_key) do nothing;
$$;

comment on function private.queue_fold_backlog(uuid, uuid[]) is
  'The only writer of private.shift_fold_backlog on the fold path: on conflict '
  'do nothing, in sorted key order, guarded by the auth.users FK so it is safe '
  'to call from the fold''s exception handler and during an account cascade.';

-- ---------------------------------------------------------------------------
-- What every arm of the exception block does: RECORD the abort and QUEUE the
-- keys. Queueing is not optional and was the single largest hole in the first
-- draft of this design: a handler that recorded and returned silently DROPPED
-- the work, so the group was never converted, payday_unmigrated_tip_row_count()
-- stayed positive forever, and the only recovery was the one-shot, which
-- reproduced the identical abort. One bad receipt scan on one night took the
-- account dark permanently.
--
-- It takes the WHOLE per-account key map, not just the account being folded
-- when the abort hit. Catching an exception in plpgsql rolls the implicit
-- subtransaction back, so every account's writes in this invocation are gone,
-- including accounts the loop had already finished. Re-deriving a group that
-- was in fact already correct is free (private.derive_shifts is idempotent on
-- the same key by construction), whereas dropping a key is permanent.
--
-- The message is bounded: SQLERRM for 22P02 and 22003 embeds the offending
-- value out of the user's receipt payload, and there is no reason to store an
-- unbounded blob per abort.
-- ---------------------------------------------------------------------------

create or replace function private.record_fold_abort(
  p_map jsonb, p_sqlstate text, p_message text)
returns void language plpgsql security definer set search_path = '' as $$
declare m record;
begin
  for m in
    select x.user_id, x.keys
    from jsonb_to_recordset(coalesce(p_map, '[]'::jsonb)) as x(user_id uuid, keys uuid[])
    order by x.user_id
  loop
    insert into private.shift_fold_failures (user_id, group_keys, sqlstate, message)
    select m.user_id, coalesce(m.keys, '{}'::uuid[]),
           coalesce(p_sqlstate, 'XX000'), left(coalesce(p_message, ''), 2000)
    from auth.users u where u.id = m.user_id;

    perform private.queue_fold_backlog(m.user_id, m.keys);
  end loop;
end;
$$;

comment on function private.record_fold_abort(jsonb, text, text) is
  'Every arm of the fold''s exception block calls exactly this: one bounded '
  'failure row per account plus the same keys queued into the backlog, then '
  'the fold returns. No retry, no re-derive, no second pass -- catching 57014 '
  'does NOT re-arm the timer (measured: 2 seconds of further work inside the '
  'handler after a 500 ms timeout completed and committed), so the handler is '
  'unbounded and must stay two bounded inserts wide.';

-- ---------------------------------------------------------------------------
-- The account-level bookkeeping the fold owns.
--
-- last_legacy_write_at is the one fact that could ever end the transition:
-- whether any 1.0 build is still writing public.tip_entries. It is stamped
-- only when the stored value is older than an hour, so the write rate is
-- bounded no matter how chatty a device is.
--
-- bulk_legacy_rewrite_at is stamped ONCE (coalesce), when an invocation
-- touches more than 50 groups or reopens more than 5 tombstones. That is the
-- defence against one device's cleared defaults rewriting months of shifts:
-- PaydaySyncState.changedIDs returns every local id when `acknowledged` is
-- empty, so a 1.0 device that loses its checkpoint mass-re-pushes its whole
-- history, and Data health shows a banner instead of the rewrite being
-- invisible.
--
-- This function is called ONLY while the caller holds the per-account
-- advisory lock, and that is load-bearing rather than tidy. It writes one row
-- per account, so two concurrent legacy writes on one account would take a
-- ROW lock on it, and the one that lost the try-lock -- the session whose
-- whole point is to return immediately -- would then wait behind the winner's
-- entire fold transaction. That is precisely the "a 1.0 write blocked behind
-- another 1.0 write" shape the try-lock exists to prevent, reintroduced by a
-- bookkeeping UPDATE. Measured in scripts/db-test-race.sh
-- (theLoserOfTheTryLockDoesNotBlockOnTheWinnersTransaction).
-- ---------------------------------------------------------------------------

create or replace function private.note_legacy_write(
  p_user_id uuid, p_touched_groups integer, p_reopened_tombstones integer,
  p_conservation_failed boolean)
returns void language sql security definer set search_path = '' as $$
  insert into public.shift_migration_state as st (
    user_id, last_legacy_write_at, bulk_legacy_rewrite_at, conservation_failed_at)
  select p_user_id, statement_timestamp(),
         case when coalesce(p_touched_groups, 0) > 50
                or coalesce(p_reopened_tombstones, 0) > 5
              then statement_timestamp() else null end,
         case when p_conservation_failed then statement_timestamp() else null end
  from auth.users u where u.id = p_user_id
  on conflict (user_id) do update set
    last_legacy_write_at = case
      when st.last_legacy_write_at is null
        or st.last_legacy_write_at < statement_timestamp() - interval '1 hour'
      then statement_timestamp() else st.last_legacy_write_at end,
    bulk_legacy_rewrite_at =
      coalesce(st.bulk_legacy_rewrite_at, excluded.bulk_legacy_rewrite_at),
    conservation_failed_at =
      coalesce(excluded.conservation_failed_at, st.conservation_failed_at);
$$;

comment on function private.note_legacy_write(uuid, integer, integer, boolean) is
  'last_legacy_write_at (at most hourly), bulk_legacy_rewrite_at (once, over '
  '50 groups or over 5 reopened tombstones) and conservation_failed_at. '
  'Called only while holding the per-account advisory lock, so two 1.0 writes '
  'never contend on this row. S5 owns the account-wide conservation DETAIL '
  'columns and the duplicate detector; the fold stamps the flag only.';

-- ---------------------------------------------------------------------------
-- The fold.
-- ---------------------------------------------------------------------------

create or replace function private.fold_legacy_writes()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare
  v_pairs jsonb;
  v_map jsonb;
  v_uid uuid;
  v_keys uuid[];        -- every group key this statement touched, sorted
  v_fresh uuid[];       -- the touched keys this statement can afford
  v_drain uuid[];       -- the reserved oldest backlog keys
  v_spend uuid[];       -- v_fresh union v_drain: what the deriver is given
  v_overflow uuid[];    -- touched keys beyond the budget, queued not folded
  v_queued_before uuid[]; -- touched keys already backlogged BEFORE the derive
  v_tombstones uuid[];  -- 'converted' tombstones in v_spend BEFORE the derive
  v_reopened integer;
  v_in bigint;
  v_out bigint;
  v_test text;
begin
  -- -------------------------------------------------------------------------
  -- THE TOUCHED SET: old keys UNION new keys.
  --
  -- An UPDATE that moves a row between groups must recompute the OLD group
  -- too, and there are three live producers of a key change:
  -- upsert_tip_entries updates shift_id and work_date unconditionally with no
  -- staleness guard; RemoteTipEntry.workDate is computed in the device's
  -- CURRENT zone at push time, so a relocated 1.0 device re-pushes the same
  -- row under the adjacent civil day; and the agent's update_tip_entry
  -- accepts shift_id. Recompute only the new key and the old shift keeps the
  -- money while the new one gains it: double-counted money with nothing to
  -- detect it.
  --
  -- THE ACCOUNT COMES FROM THE ROWS, NEVER FROM auth.uid(). The agent API
  -- writes tip_entries by direct table access with the service-role client,
  -- for which auth.uid() is null, so scoping by it would write user_id null
  -- (a NOT NULL violation, i.e. a rejected write) or fold nowhere. Nothing
  -- here branches on the caller's role at all, which is why the measured fact
  -- that `current_user` inside a security definer body is the OWNER rather
  -- than the caller cannot bite: there is no role test to get wrong.
  --
  -- Three triggers over one function, branching on TG_OP, because `after
  -- insert or update ... referencing new table as nt` fails with "transition
  -- tables cannot be specified for triggers with more than one event" and an
  -- OLD TABLE is invalid for INSERT. Each branch names ONLY the transition
  -- tables its own trigger declares. Measured on PG 17.11: transition tables
  -- resolve fine under `set search_path = ''` (they are ephemeral named
  -- relations, matched by name ahead of the search path) and the shared
  -- function's cached plans are reused across the INSERT and UPDATE triggers
  -- without error.
  -- -------------------------------------------------------------------------
  if TG_OP = 'INSERT' then
    v_pairs := (select coalesce(jsonb_agg(distinct jsonb_build_object(
                         'u', n.user_id,
                         'k', private.legacy_group_key(n.shift_id, n.work_date))), '[]'::jsonb)
                from new_rows n);
  elsif TG_OP = 'UPDATE' then
    v_pairs := (select coalesce(jsonb_agg(distinct jsonb_build_object('u', r.u, 'k', r.k)), '[]'::jsonb)
                from (select n.user_id as u, private.legacy_group_key(n.shift_id, n.work_date) as k
                        from new_rows n
                      union
                      select o.user_id, private.legacy_group_key(o.shift_id, o.work_date)
                        from old_rows o) r);
  else
    v_pairs := (select coalesce(jsonb_agg(distinct jsonb_build_object(
                         'u', o.user_id,
                         'k', private.legacy_group_key(o.shift_id, o.work_date))), '[]'::jsonb)
                from old_rows o);
  end if;

  -- One residual window, named: an abort DURING this key computation leaves
  -- v_map null, so the handler has no keys to record or queue. Nothing here
  -- can raise on its own -- the group key is an immutable function of two
  -- NOT NULL columns -- so the only candidate is a statement_timeout landing
  -- inside a transition-table scan, and the recovery is the same surface every
  -- other miss uses: the rows stay in public.tip_entries named by no shift, so
  -- the `unmigrated` predicate still counts them and the client's one-shot
  -- converts them. The 1.0 write commits either way, which is the rule that
  -- matters.
  v_map := (
    select coalesce(jsonb_agg(jsonb_build_object('user_id', g.u, 'keys', g.keys) order by g.u),
                    '[]'::jsonb)
    from (select p.u, array_agg(distinct p.k order by p.k) as keys
          from jsonb_to_recordset(v_pairs) as p(u uuid, k uuid)
          where p.u is not null and p.k is not null
          group by p.u) g);

  -- One iteration per account. A single statement normally touches one, but
  -- the agent's service-role client can legally write rows of several
  -- accounts at once, and folding those into whichever account auth.uid()
  -- happens to name would move money between people.
  for v_uid, v_keys in
    select m.user_id, m.keys
    from jsonb_to_recordset(v_map) as m(user_id uuid, keys uuid[])
    order by m.user_id
  loop
    -- -----------------------------------------------------------------------
    -- THE ACCOUNT-DELETION NO-OP, first, before anything can write.
    --
    -- public.delete_my_account() deletes the auth.users row and every Payday
    -- table cascades. MEASURED on PG 17.11 with a probe trigger in this exact
    -- shape: by the time the cascade's DELETE on public.tip_entries fires its
    -- statement trigger, the auth.users row is already invisible AND
    -- public.shifts has already been emptied for that account. So a fold that
    -- ran here would re-insert a shifts row for a user that no longer exists,
    -- raise 23503, and -- because the handler's own insert into
    -- private.shift_fold_failures carries the same FK -- raise a second time
    -- INSIDE the handler and fail account deletion. That is the Guideline
    -- 5.1.1(v) requirement Payday was rejected over once already.
    --
    -- `continue`, not `return`, so a multi-account statement still folds the
    -- accounts that do exist. For the cascade itself the two are identical:
    -- it only ever carries one account's rows.
    -- -----------------------------------------------------------------------
    if not exists (select 1 from auth.users u where u.id = v_uid) then
      continue;
    end if;

    -- -----------------------------------------------------------------------
    -- THE TRY-LOCK. The first statement of this account's work, and
    -- NON-BLOCKING.
    --
    -- MEASURED with the fold installed and no per-group lock: session A
    -- inserts a $50.00 cash row and holds its transaction open, session B
    -- inserts the $20.00 credit row of the same shift and commits, and the
    -- result is cash = 0, credit = 2000, provenance length 1, with the cash
    -- row named by no shift at all. At READ COMMITTED B's recompute took its
    -- snapshot before A committed, so `excluded` described only B's row and
    -- `do update` overwrote A's. Two devices on one account, or one device
    -- retrying while the agent writes: mainline, not exotic.
    --
    -- Three writers take the same per-account key -- this fold with
    -- pg_try_advisory_xact_lock, and the one-shot and private.write_shifts
    -- with the blocking pg_advisory_xact_lock -- so no two can interleave and
    -- a deadlock between them is unrepresentable.
    --
    -- On failure it does not block and does not raise: it queues the touched
    -- keys and returns, which leaves the authoritative read surface
    -- UNDER-counted until the backlog drains. Measured, both variants, in
    -- scripts/db-test-race.sh. Three things contain the under-count and all
    -- three are load-bearing: the reader's first-switch predicate rejects the
    -- switch while any local TipEntry id is unnamed, payday_unmigrated_tip_
    -- row_count() counts the backlog, and the drain is an explicit numbered
    -- step in the sync pass.
    --
    -- pg_try_advisory_xact_lock and hashtextextended stay unqualified under
    -- `set search_path = ''`: pg_catalog is always searched first.
    -- -----------------------------------------------------------------------
    if not pg_try_advisory_xact_lock(
             hashtextextended('payday:shiftmig:' || v_uid::text, 0)) then
      perform private.queue_fold_backlog(v_uid, v_keys);
      continue;
    end if;

    -- -----------------------------------------------------------------------
    -- THE WORK BUDGET: 50 groups per statement, SPLIT and RESERVED, never a
    -- remainder.
    --
    --   40 for the touched keys (freshness first);
    --   10 for the oldest backlog entries by queued_at;
    --   the 10 roll into the touched keys only when the backlog is empty.
    --
    -- The reservation is what makes progress guaranteed, and the first
    -- draft's "spend any leftover budget" yielded exactly zero leftover in
    -- the case that creates the backlog. MEASURED, one shipped-shaped
    -- upsert_tip_entries of 500 rows across 250 groups (PaydaySyncService
    -- sends batchSize = 500): tip_entries 500 rows / shifts written 50 /
    -- backlog 200 / fold failures 0. A second identical batch folded 50 fresh
    -- groups and drained ZERO. So at batchSize = 500 a device re-pushing its
    -- whole history never drained a single backlog entry -- precisely the
    -- first sign-in and checkpoint-loss re-push the budget exists for. With
    -- the reservation every legacy write drains at least 10.
    -- -----------------------------------------------------------------------
    v_fresh := v_keys[1:40];
    v_drain := array(
      select b.group_key from private.shift_fold_backlog b
       where b.user_id = v_uid
         and not (b.group_key = any(v_fresh))
       order by b.queued_at, b.group_key
       limit 10);
    if cardinality(v_drain) = 0 then
      v_fresh := v_keys[1:50];
    end if;
    v_overflow := v_keys[cardinality(v_fresh) + 1 : cardinality(v_keys)];
    v_spend := array(select distinct k from unnest(v_fresh || v_drain) as k order by k);

    -- Which of the TOUCHED keys already had a backlog row before this fold
    -- derived anything, read here and not after. Only these, plus the reserved
    -- drain set, may be deleted below.
    --
    -- A session that LOSES the try-lock queues its keys and COMMITS while this
    -- fold is still running, and at READ COMMITTED the derive below took its
    -- snapshot when its own statement began. So a key queued by that session
    -- after the derive's snapshot names a legacy row this fold did not see: if
    -- the delete were `= any(v_spend)` it would remove that queue entry on the
    -- strength of a conversion that never included the row, and the money
    -- would sit in public.tip_entries named by no shift with nothing queued to
    -- fix it. Deleting only what was demonstrably queued BEFORE the derive
    -- costs one indexed read and closes that.
    --
    -- Residual, named rather than papered over: a key that was ALREADY in the
    -- backlog when this fold started and is re-queued by such a session is
    -- still deleted, because `on conflict do nothing` leaves the same row
    -- untouched and there is nothing in it to tell the two apart. That window
    -- is microseconds wide and recovers through the same surface every other
    -- miss does -- the row is named by no shift, so the `unmigrated` predicate
    -- and payday_unmigrated_tip_row_count() still see it and the client's
    -- one-shot converts it. Closing it would mean the backlog insert taking a
    -- row lock (`on conflict do update set queued_at = ...`), which is exactly
    -- the 1.0-write-behind-a-1.0-write the `do nothing` exists to prevent.
    v_queued_before := array(
      select b.group_key from private.shift_fold_backlog b
       where b.user_id = v_uid and b.group_key = any(v_fresh)
       order by b.group_key);

    -- -----------------------------------------------------------------------
    -- The two forced-abort hooks of the S-gate. 57014 and assert_failure are
    -- the two classes `when others` cannot catch, and 57014 is the one an
    -- untrapped occurrence of makes permanent: PaydaySyncService retries the
    -- identical 500-row payload, so one untrapped timeout is permanent
    -- darkness for that device. Neither class can be provoked from outside
    -- the fold at a chosen moment, so the hooks are the only way the named
    -- arms are ever exercised, and an unexercised exception arm is a claim
    -- rather than a measurement.
    --
    -- Safe by construction: both outcomes are what this function's own
    -- handler is built to swallow, so the worst a GUC left set can do is what
    -- the tests assert -- the 1.0 write still commits, a failures row is
    -- recorded and the keys are queued. Nothing here can reject a write.
    -- -----------------------------------------------------------------------
    v_test := coalesce(current_setting('payday.fold_test_abort', true), '');
    if v_test = 'sleep' then
      perform pg_sleep(3);
    elsif v_test = 'assert' then
      assert false, 'payday.fold_test_abort = assert';
    end if;

    -- -----------------------------------------------------------------------
    -- Which of this account's 'converted' tombstones exist BEFORE the derive,
    -- so bulk_legacy_rewrite_at can count how many the un-delete arm reopened
    -- without a second spelling of any rule. Arm 3 reopens only a tombstone
    -- the fold itself set, on a shift no human has touched, whose group has
    -- live source rows again; comparing this list against deleted_at after
    -- the derive measures exactly that, and arm 2b's new tombstones cannot
    -- contaminate it because a group cannot both have and lack live rows.
    -- -----------------------------------------------------------------------
    v_tombstones := array(
      select s.id from public.shifts s
       where s.user_id = v_uid and s.id = any(v_spend)
         and s.deleted_reason = 'converted' and s.deleted_at is not null
       order by s.id);

    -- -----------------------------------------------------------------------
    -- ONE call to the single deriver, over the fresh keys and the reserved
    -- backlog keys TOGETHER, so there is one evaluation of `grouped` and one
    -- snapshot. Arms 1, 2a, 2b, 3, 4a and 4b are inside it, shared verbatim
    -- with the one-shot, which is why the trigger and the one-shot cannot
    -- disagree about grouping, receipt arithmetic, tip-out or hours.
    -- -----------------------------------------------------------------------
    select d.source_cents, d.shift_cents into v_in, v_out
      from private.derive_shifts(v_uid, v_spend) d;

    select count(*) into v_reopened
      from public.shifts s
     where s.user_id = v_uid and s.id = any(v_tombstones) and s.deleted_at is null;

    -- Queue the touched keys the budget could not afford.
    perform private.queue_fold_backlog(v_uid, v_overflow);

    -- DELETE the drained keys. This rolls back with a failed derive, so
    -- nothing is lost; without it the backlog grew monotonically and
    -- re-folded the same groups forever. Scoped to what was queued before the
    -- derive, for the reason above.
    delete from private.shift_fold_backlog b
     where b.user_id = v_uid
       and b.group_key = any(v_drain || v_queued_before);

    -- Conservation RECORDS, it never raises, on either path. Committing a
    -- wrong number that Data health flags is strictly better than a dark app.
    perform private.note_legacy_write(
      v_uid, cardinality(v_keys), v_reopened, v_in <> v_out);
  end loop;

  return null;

-- ---------------------------------------------------------------------------
-- THE FIVE ARMS. Each one records AND queues, then returns.
--
-- `when others` is not sufficient and was the single largest hole in this
-- design's first draft. MEASURED on PG 17.11 in this exact trigger shape:
-- PL/pgSQL's OTHERS deliberately excludes QUERY_CANCELED and ASSERT_FAILURE,
-- and statement_timeout raises exactly 57014, so a `when others` handler
-- around a slow fold never fires -- the notice does not print and the
-- statement aborts with "canceling statement due to statement timeout". With
-- a named `when query_canceled` arm instead, the 1.0-shaped
-- upsert_tip_entries under `set statement_timeout = '500ms'` around a
-- 3-second fold returned its row, the legacy row COMMITTED, exactly one row
-- landed in private.shift_fold_failures with sqlstate 57014, and the backlog
-- got the keys.
--
-- deadlock_detected (40P01) and unique_violation (23505) are named too. Both
-- would be caught by OTHERS; naming them is free and it makes the two classes
-- the design reasons about explicitly -- the row-lock deadlock against a
-- native shift write, and the concurrent duplicate backlog insert -- visible
-- at the top of the handler instead of buried in a comment. No arm does
-- anything different: five arms, one body, because a handler that varied per
-- class is a handler that can be wrong per class.
--
-- No `raise` anywhere, in either path. The failures table and
-- conservation_failed_at are the reporting surface.
-- ---------------------------------------------------------------------------
exception
  when query_canceled then       -- 57014, statement_timeout. NOT caught by OTHERS.
    perform private.record_fold_abort(v_map, sqlstate, sqlerrm);
    return null;
  when assert_failure then       -- also NOT caught by OTHERS.
    perform private.record_fold_abort(v_map, sqlstate, sqlerrm);
    return null;
  when deadlock_detected then    -- 40P01
    perform private.record_fold_abort(v_map, sqlstate, sqlerrm);
    return null;
  when unique_violation then     -- 23505
    perform private.record_fold_abort(v_map, sqlstate, sqlerrm);
    return null;
  when others then               -- 22P02, 22003, check_violation, 23503, ...
    perform private.record_fold_abort(v_map, sqlstate, sqlerrm);
    return null;
end;
$fn$;

comment on function private.fold_legacy_writes() is
  'The on-arrival trigger function. Runs inside a shipped 1.0 build''s write '
  'transaction and therefore NEVER raises and NEVER rejects: five exception '
  'arms, a non-blocking per-account lock, a reserved 40/10 work budget, and an '
  'account-deletion no-op. The conversion arms are in private.derive_shifts.';

-- ---------------------------------------------------------------------------
-- The three triggers.
--
-- STATEMENT-LEVEL, not row-level. A per-row AFTER trigger is correct
-- (measured: one multi-row INSERT of both rows of a group yields cash 5000,
-- credit 2000, two ids) but folds the same group once per row, and
-- PaydayRemoteRepository.batchSize = 500 makes that up to 500 recomputes
-- inside one old build's transaction. Timeout-proneness IS a rejected write.
--
-- AFTER, never BEFORE, so tip_entries_touch_version is undisturbed.
--
-- `insert ... on conflict do update` routes inserted rows to the INSERT
-- trigger and updated rows to the UPDATE trigger, so upsert_tip_entries is
-- fully covered by these three.
--
-- A trigger is the only construct that makes conversion a property of the
-- TABLE rather than of six call sites plus two RPCs: the agent API writes
-- tip_entries by direct table access with the service-role client, so RLS is
-- bypassed and no RPC predicate is ever on the call path.
--
-- These triggers do NOT fire on every path that can put a legacy row in the
-- table, and cannot be made to. session_replication_role = 'replica'
-- disables them, which is what pg_restore, logical replication and PITR use;
-- `alter table ... disable trigger` does the same; and rows present before
-- this migration deployed were never seen. All three are recoverable only
-- through the `unmigrated` predicate and payday_unmigrated_tip_row_count(),
-- which is the strongest argument for keeping both and alerting on a
-- sustained non-zero: with these triggers installed the steady state is
-- exactly 0.
-- ---------------------------------------------------------------------------

drop trigger if exists tip_entries_fold_insert on public.tip_entries;
drop trigger if exists tip_entries_fold_update on public.tip_entries;
drop trigger if exists tip_entries_fold_delete on public.tip_entries;

create trigger tip_entries_fold_insert after insert on public.tip_entries
  referencing new table as new_rows
  for each statement execute function private.fold_legacy_writes();

create trigger tip_entries_fold_update after update on public.tip_entries
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.fold_legacy_writes();

create trigger tip_entries_fold_delete after delete on public.tip_entries
  referencing old table as old_rows
  for each statement execute function private.fold_legacy_writes();
