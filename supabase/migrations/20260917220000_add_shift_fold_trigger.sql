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
--   * private.record_fold_abort's OWN nested exception blocks and its own
--     bounded lock_timeout, because the handler is the one place nothing
--     catches anything, and a handler that can raise or hang is a rejected
--     1.0 write by a longer route. MEASURED on a pristine PG 17.11 cluster
--     with the unmodified previous version of this file, twice:
--       - lock_timeout RE-ARMS on every lock acquisition, so a 1.0 write that
--         caught 55P03 in the main body raised 55P03 again INSIDE
--         record_fold_abort's `on conflict do nothing` and escaped: "canceling
--         statement due to lock timeout / while inserting index tuple (0,1) in
--         relation shift_fold_backlog", ROLLBACK, and the outer 1.0 row did
--         not land (tip rows 2, the writer's row 0, failure rows 0, backlog 1);
--       - statement_timeout does NOT re-arm, which is worse and not better: a
--         1.0 write that caught 57014 in the main body then waited in
--         record_fold_abort on another session's uncommitted duplicate index
--         entry with NO timer armed at all, and was still waiting 15 minutes
--         later. A 1.0 write that never returns is a client-side timeout,
--         which is a rejected write;
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
-- THAT PARAGRAPH IS TRUE ONLY IN THE MAIN BODY, and an earlier version of
-- this file declared it safe everywhere. In the main body a timeout during
-- the wait is caught by `when query_canceled`. In the fold's exception
-- handler nothing catches anything, so the same wait was both a raise (with
-- lock_timeout, which re-arms) and an unbounded hang (with statement_timeout,
-- which does not). Both are measured in the file header and both are now
-- contained inside private.record_fold_abort rather than by this function,
-- which still waits exactly as described above. This function is therefore
-- allowed to raise and allowed to wait; every caller on an abort path wraps
-- it.
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
-- WHICH KEYS MAY BE QUEUED. Two questions, deliberately answered separately
-- and then OR-ed, because each one alone is wrong in a different direction.
--
-- THE BUG THIS EXISTS TO FIX. The overflow used to be queued
-- UNCONDITIONALLY, and the printed invariant "with these triggers installed
-- the steady state is exactly 0" was false because of it. MEASURED on
-- Postgres 17.11 with all migrations applied: 30 identical 500-row /
-- 250-group upsert_tip_entries statements, each its own transaction. By pass
-- 21 all 250 groups were converted, the money was exact to the cent and no
-- legacy row was unnamed -- and the backlog sat at exactly 200 on every pass
-- from 1 to 30. The mechanism is arithmetic, not a race: a statement touching
-- 250 sorted keys spends 40 on the first 40 and 10 on the oldest backlog
-- entries, then queues keys 41..250, which INCLUDES the 10 it just drained.
-- The delete below removes them; the overflow above puts them straight back.
-- Net progress per statement: zero, forever. Since S5 defines
-- payday_unmigrated_tip_row_count() as the predicate PLUS the backlog, that
-- pins the watchdog at a permanent non-zero on an account that is completely
-- and correctly converted, which saturates the alert §4.8 and §6.2 rest on
-- and blocks the reader's first switch for as long as a device keeps
-- re-pushing. Defect 12 of the design (line 1871) names exactly this shape.
--
-- 1. DID THIS STATEMENT CHANGE THE GROUP'S CONTENT (p_changed, computed in
--    the fold from the transition tables). This arm has no false negatives
--    for the current statement and it is what makes the invariant reachable:
--    a repeated identical upsert changes nothing but `version` and
--    `updated_at`, so it queues nothing and the backlog drains 10 per
--    statement to zero.
--
-- 2. DOES THE SHIFT ROW ALREADY AGREE WITH THE GROUP'S LIVE SOURCES
--    (private.unconverged_group_keys). This is the `unmigrated` expression,
--    and it is the ONE spelling S5 must build payday_unmigrated_tip_row_count()
--    and the reader's first-switch predicate on, because a count and a queue
--    that disagree about what "converted" means will disagree about when the
--    transition is over.
--
-- WHY BOTH. Arm 2 alone would silently drop a money update, which is the one
-- outcome worse than a saturated alert. `client_updated_at` is the DEVICE's
-- clock: TipEntry.touch() is the only thing that advances it, and the shipped
-- model's own documentation says under-calling it is survivable precisely
-- because "the upload set is chosen by a content fingerprint, not by this
-- clock, so a missed bump still uploads". So a row can arrive with a changed
-- amount, the same id and the same client_updated_at, which arm 2 cannot see
-- and arm 1 always can. Arm 1 alone would be enough for the current
-- statement but has nothing to say about a key whose earlier queue entry was
-- lost -- the microsecond delete race named below, or record_fold_abort
-- dropping a queue entry -- which is exactly what arm 2 recovers. A false
-- POSITIVE from either arm costs one backlog row and one idempotent
-- re-derive; a false negative costs money. The OR is the safe direction.
--
-- Deliberately NOT in arm 2, and named rather than left to be rediscovered:
-- converted_at and unconverted_legacy_cents. Arm 1 of the deriver rewrites
-- both on every pass, so including either would make every key permanently
-- unconverged and reinstate the pinned backlog in a new spelling. A closed
-- shift's unconverted_legacy_cents can therefore go stale after a NATIVE
-- edit -- but a native edit never fires this trigger at all, so that
-- staleness is identical before and after this change and belongs to S6.
-- ---------------------------------------------------------------------------

-- The content of one legacy row, MINUS the three server-owned bookkeeping
-- columns. Subtractive on purpose: private.touch_versioned_row() bumps
-- `version` and `updated_at` on EVERY update, so a plain `old is distinct
-- from new` is always true and would answer "changed" to a no-op re-push,
-- while an explicit include-list is a second spelling of "what the deriver
-- reads" that drifts silently the day a column is added. Removing three named
-- columns means a new column is automatically compared, which is the safe
-- direction: comparing a column the deriver ignores costs a re-derive;
-- missing one it reads costs money.
--
-- STABLE, not IMMUTABLE: to_jsonb renders timestamptz in the session
-- TimeZone. Both sides of every comparison are rendered inside one statement,
-- so the comparison is still exact.
create or replace function private.legacy_row_content(e public.tip_entries)
returns jsonb language sql stable set search_path = '' as $$
  select to_jsonb(e) - 'updated_at' - 'version' - 'created_at';
$$;

comment on function private.legacy_row_content(public.tip_entries) is
  'One legacy row''s content for change detection: every column except '
  'updated_at, version and created_at, which private.touch_versioned_row() '
  'rewrites on every UPDATE. Spelled as a subtraction so a column added later '
  'is compared by default.';

-- The `unmigrated` expression. A group key has work iff deriving it would
-- change public.shifts, judged only on the provenance columns the deriver
-- writes unconditionally:
--
--   live rows exist  -> a shift row must exist, name exactly those ids, carry
--                       their max(client_updated_at) as the watermark, and not
--                       still be a fold-set tombstone on an untouched shift
--                       (arm 3 would reopen it);
--   no live rows     -> any shift row must hold no provenance (arm 2a has
--                       released it) and must already be closed or tombstoned
--                       (arm 2b has released the money). No shift row at all
--                       is converged: there is nothing for any arm to act on.
--
-- legacy_entry_ids and legacy_source_max_updated_at are written by arm 1 with
-- NO `where` clause, so they converge on closed and natively deleted shifts
-- too, which is what lets one predicate cover the whole population.
--
-- S5 OWNS THE CONSUMERS, THIS FILE OWNS THE SPELLING. Two things must be
-- built on this function and not re-derived: payday_unmigrated_tip_row_count()
-- (count the tip rows whose key is returned here, and filter the backlog
-- term through it too, so a stale backlog row cannot pin the count), and the
-- reader's first-switch predicate.
create or replace function private.unconverged_group_keys(
  p_user_id uuid, p_keys uuid[])
returns uuid[] language sql stable security definer set search_path = '' as $$
  with k as (
    select distinct x as group_key
    from unnest(coalesce(p_keys, '{}'::uuid[])) as x
    where x is not null),
  live as (
    select k.group_key,
           array_agg(distinct e.id order by e.id)
             filter (where e.id is not null) as live_ids,
           max(e.client_updated_at) as live_max
    from k
    left join public.tip_entries e
      on e.user_id = p_user_id
     and e.deleted_at is null
     and private.legacy_group_key(e.shift_id, e.work_date) = k.group_key
    group by k.group_key)
  select coalesce(array_agg(l.group_key order by l.group_key), '{}'::uuid[])
  from live l
  left join public.shifts s on s.user_id = p_user_id and s.id = l.group_key
  where case when l.live_ids is not null then
               s.id is null
               or coalesce(s.legacy_entry_ids, '{}'::uuid[]) <> l.live_ids
               or s.legacy_source_max_updated_at is distinct from l.live_max
               or (s.deleted_at is not null
                   and s.deleted_reason = 'converted'
                   and s.native_modified_at is null)
             else
               s.id is not null
               and (coalesce(array_length(s.legacy_entry_ids, 1), 0) > 0
                    or private.shift_is_open_to_fold(s))
        end;
$$;

comment on function private.unconverged_group_keys(uuid, uuid[]) is
  'The `unmigrated` predicate, as keys: the group keys whose shift row does '
  'not already agree with their live tip_entries rows on provenance ids, the '
  'source watermark and the fold''s own tombstone. The ONE spelling -- S5''s '
  'payday_unmigrated_tip_row_count() and the reader''s first-switch predicate '
  'must both be built on it, because a count and a queue that disagree about '
  '"converted" disagree about when the transition ends.';

-- What a fold may queue out of a set of touched keys. One spelling, two call
-- sites (the try-lock loser and the budget overflow), so the two cannot
-- drift.
--
-- `as materialized` IS LOAD-BEARING AND WAS MEASURED, not styled. PostgreSQL
-- 12 and later inline a non-recursive CTE referenced once, and inlining this
-- one puts private.unconverged_group_keys inside a per-row predicate: on a
-- 2000-row account with a 200-key overflow that is 200 evaluations of a 1.4 ms
-- query. MEASURED on PG 17.11: 271 ms inlined against 1.4 ms for the same
-- query run alone, which took a 500-row re-push of a shipped 1.0 build from
-- 11 ms to 370 ms -- a 30x regression on the exact statement shape the work
-- budget exists to keep away from a timeout. With `as materialized` it is
-- evaluated once. The jsonb content comparison the fold hands in as p_changed
-- is not the expensive half and never was: 500 calls to
-- private.legacy_row_content measure 0.14 ms in total.
create or replace function private.fold_keys_to_queue(
  p_user_id uuid, p_keys uuid[], p_changed uuid[])
returns uuid[] language sql stable security definer set search_path = '' as $$
  with u as materialized (
    select private.unconverged_group_keys(p_user_id, p_keys) as ks)
  select coalesce(array_agg(distinct k order by k), '{}'::uuid[])
  from unnest(coalesce(p_keys, '{}'::uuid[])) as k cross join u
  where k is not null
    and (k = any(coalesce(p_changed, '{}'::uuid[])) or k = any(u.ks));
$$;

comment on function private.fold_keys_to_queue(uuid, uuid[], uuid[]) is
  'The keys out of p_keys worth queueing: the ones this statement actually '
  'changed, plus the ones whose shift row does not already agree with their '
  'sources. Queueing the rest unconditionally pinned the backlog at 200 on a '
  'fully converted account for 30 consecutive passes -- measured.';

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
--
-- THIS FUNCTION IS STRUCTURALLY UNABLE TO RAISE AND STRUCTURALLY UNABLE TO
-- WAIT, and neither property is decoration. It is called only from the fold's
-- exception handler, which is the one place in this file where nothing above
-- catches anything: a raise here propagates straight out of
-- upsert_tip_entries and rejects a shipped 1.0 build's write, and a hang here
-- is a client-side timeout, which is the same thing by a slower route. Both
-- were MEASURED on a pristine cluster against the previous version of this
-- function; the reproductions are recorded in the file header and are now
-- asserted by scripts/db-test-race.sh cases 6 and 7.
--
-- THREE nesting levels, each earning its place:
--
--  1. An OUTER guard around the whole loop, so an abort in the loop's own
--     driving query cannot escape either. It costs the honest way round: a
--     catch here rolls its subtransaction back and takes EVERY account's
--     failure row and queue entry with it, including the inner blocks that
--     had already succeeded. That trade is made deliberately and in one
--     direction only -- a lost failure row is recovered through the
--     `unmigrated` predicate and payday_unmigrated_tip_row_count(), the same
--     backstop this file already relies on for its named v_map-is-null
--     window, and a rejected 1.0 write is recovered by nothing.
--
--  2. TWO INDEPENDENT inner blocks per account, never one. MEASURED with a
--     single-block version: the queue call's 55P03 took the failure row down
--     with it in the same subtransaction rollback -- the 1.0 write committed
--     but failure_rows went to 0, so the abort was swallowed with no record
--     of it anywhere. Two blocks means a failed queue costs only the queue.
--
--  3. A bounded lock_timeout for the duration, because catching is not
--     enough on its own: statement_timeout does NOT re-arm after firing
--     (measured: 2 seconds of handler work completed after a 1 ms timeout),
--     so a handler entered through `when query_canceled` has NO timer left
--     and waits on a concurrent uncommitted duplicate for as long as that
--     transaction lives -- measured at over 15 minutes. 50 ms is the whole
--     budget the handler needs, and losing that queue entry is very nearly
--     free: a session holding an uncommitted duplicate index entry on
--     (user_id, group_key) is BY DEFINITION queueing that same key, so when
--     it commits the key is in the backlog anyway.
--
--     set_config(..., is_local := true) is transaction-scoped, so the restore
--     is belt AND braces: the explicit restore covers the success path, and a
--     subtransaction rollback reverts the GUC on its own if the outer guard
--     fires. Asserted in supabase/tests/shift_fold_test.sql -- a lock_timeout
--     left set on a 1.0 build's transaction would reject one of ITS later
--     statements, which is the same failure this whole file exists to avoid.
--
-- Every arm names query_canceled and assert_failure explicitly for the same
-- reason the outer block does: `when others` excludes both.
-- ---------------------------------------------------------------------------

create or replace function private.record_fold_abort(
  p_map jsonb, p_sqlstate text, p_message text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  m record;
  v_prev_lock_timeout text;
begin
  begin
    v_prev_lock_timeout := coalesce(current_setting('lock_timeout', true), '0');
    perform set_config('lock_timeout', '50ms', true);

    for m in
      select x.user_id, x.keys
      from jsonb_to_recordset(coalesce(p_map, '[]'::jsonb)) as x(user_id uuid, keys uuid[])
      order by x.user_id
    loop
      begin
        insert into private.shift_fold_failures (user_id, group_keys, sqlstate, message)
        select m.user_id, coalesce(m.keys, '{}'::uuid[]),
               coalesce(p_sqlstate, 'XX000'), left(coalesce(p_message, ''), 2000)
        from auth.users u where u.id = m.user_id;
      exception
        when query_canceled then null;
        when assert_failure then null;
        when others then null;
      end;

      begin
        perform private.queue_fold_backlog(m.user_id, m.keys);
      exception
        when query_canceled then null;
        when assert_failure then null;
        when others then null;
      end;
    end loop;

    perform set_config('lock_timeout', v_prev_lock_timeout, true);
  exception
    when query_canceled then null;
    when assert_failure then null;
    when others then null;
  end;
end;
$$;

comment on function private.record_fold_abort(jsonb, text, text) is
  'Every arm of the fold''s exception block calls exactly this: one bounded '
  'failure row per account plus the same keys queued into the backlog, then '
  'the fold returns. No retry, no re-derive, no second pass -- catching 57014 '
  'does NOT re-arm the timer (measured: 2 seconds of further work inside the '
  'handler after a 500 ms timeout completed and committed), so the handler is '
  'unbounded and must stay two bounded inserts wide. It cannot raise and it '
  'cannot wait: an outer guard, two independent blocks per account so a '
  'failed queue does not discard that account''s failure row, and a 50 ms '
  'lock_timeout restored on both paths. lock_timeout RE-ARMS, so without '
  'these the handler''s own `on conflict do nothing` raised out of the '
  'handler and rolled a shipped 1.0 build''s write back with zero failure '
  'rows recorded -- measured twice.';

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
  v_changed uuid[];     -- the touched keys whose CONTENT this statement changed
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
  --
  -- Each pair also carries `c`: did THIS statement change that row's content.
  -- An INSERT and a DELETE always did. An UPDATE is the case that matters and
  -- the only one that can answer "no": private.touch_versioned_row() bumps
  -- `version` and `updated_at` on every UPDATE, so the transition tables
  -- differ on every row even when the 1.0 build re-pushed a byte-identical
  -- payload, and private.legacy_row_content is what subtracts that noise. The
  -- rows are paired on `id`, the primary key, which no writer on this path
  -- ever changes; an id present on only one side is treated as changed so a
  -- writer that somehow did is still safe.
  --
  -- This costs one jsonb render per updated row and is computed in the same
  -- pass over the transition tables that the key set already needs, so it
  -- adds no scan. It is what makes private.fold_keys_to_queue able to say no.
  if TG_OP = 'INSERT' then
    v_pairs := (select coalesce(jsonb_agg(distinct jsonb_build_object(
                         'u', n.user_id,
                         'k', private.legacy_group_key(n.shift_id, n.work_date),
                         'c', true)), '[]'::jsonb)
                from new_rows n);
  elsif TG_OP = 'UPDATE' then
    v_pairs := (select coalesce(jsonb_agg(distinct jsonb_build_object(
                         'u', r.u, 'k', r.k, 'c', r.c)), '[]'::jsonb)
                from (select n.user_id as u,
                             private.legacy_group_key(n.shift_id, n.work_date) as k,
                             (o.id is null
                              or private.legacy_row_content(o)
                                 is distinct from private.legacy_row_content(n)) as c
                        from new_rows n
                        left join old_rows o
                          on o.id = n.id and o.user_id = n.user_id
                      union all
                      select o.user_id,
                             private.legacy_group_key(o.shift_id, o.work_date),
                             (n.id is null
                              or private.legacy_row_content(o)
                                 is distinct from private.legacy_row_content(n))
                        from old_rows o
                        left join new_rows n
                          on n.id = o.id and n.user_id = o.user_id) r);
  else
    v_pairs := (select coalesce(jsonb_agg(distinct jsonb_build_object(
                         'u', o.user_id,
                         'k', private.legacy_group_key(o.shift_id, o.work_date),
                         'c', true)), '[]'::jsonb)
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
  --
  -- `changed` is a strict subset of `keys`: a key is changed if ANY of its
  -- rows changed, which is what the FILTER over the per-row flag computes.
  -- private.record_fold_abort reads only user_id and keys out of this map;
  -- jsonb_to_recordset ignores the extra field.
  v_map := (
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', g.u, 'keys', g.keys, 'changed', g.changed) order by g.u),
                    '[]'::jsonb)
    from (select p.u,
                 array_agg(distinct p.k order by p.k) as keys,
                 coalesce(array_agg(distinct p.k order by p.k)
                            filter (where p.c), '{}'::uuid[]) as changed
          from jsonb_to_recordset(v_pairs) as p(u uuid, k uuid, c boolean)
          where p.u is not null and p.k is not null
          group by p.u) g);

  -- One iteration per account. A single statement normally touches one, but
  -- the agent's service-role client can legally write rows of several
  -- accounts at once, and folding those into whichever account auth.uid()
  -- happens to name would move money between people.
  for v_uid, v_keys, v_changed in
    select m.user_id, m.keys, m.changed
    from jsonb_to_recordset(v_map) as m(user_id uuid, keys uuid[], changed uuid[])
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
    --
    -- SCOPED, for the reason private.fold_keys_to_queue exists: a loser whose
    -- own write changed nothing and whose groups already agree with their
    -- sources has nothing to hand to a later statement, and queueing it
    -- anyway is how the backlog acquired a floor.
    if not pg_try_advisory_xact_lock(
             hashtextextended('payday:shiftmig:' || v_uid::text, 0)) then
      perform private.queue_fold_backlog(
        v_uid, private.fold_keys_to_queue(v_uid, v_keys, v_changed));
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
    --
    -- THE DRAIN RATE, MEASURED ON THE CASE THE BUDGET EXISTS FOR, and the
    -- number S7 must size its explicit drain step off: a checkpoint-loss
    -- re-push of 2000 rows across 1000 nights, sent as four 500-row pages
    -- (PaydaySyncService.swift:25), converts 200 of the 1000 groups and parks
    -- 800 keys, and it then takes 80 further ordinary one-group legacy writes
    -- before the backlog reaches 0 and the money agrees. For that whole window
    -- 80% of the account's history is absent from public.shifts, and a device
    -- retired right after the re-push never drains it through this trigger at
    -- all. S7's drain step must therefore be unbounded or per-account
    -- complete; another reserved slice of 10 would take 80 passes.
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
    v_spend := array(select distinct k from unnest(v_fresh || v_drain) as k order by k);

    -- The overflow is "touched but NOT derived", computed by subtracting
    -- v_spend rather than by slicing past v_fresh. The slice was not
    -- equivalent: the reserved drain keys live beyond the fresh window, so a
    -- statement touching more keys than the budget re-queued the ten it had
    -- just drained, the delete below removed them again, and net progress was
    -- exactly zero on every pass. Subtracting v_spend makes the overflow
    -- disjoint from what this fold derived, by construction.
    v_overflow := array(
      select k from unnest(v_keys) as k
       where not (k = any(v_spend))
       order by k);

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
    --
    -- That claim was FALSE until private.record_fold_abort got its own
    -- exception blocks and its own lock_timeout: with a re-arming lock_timeout
    -- and a concurrent uncommitted duplicate, the handler these hooks steer
    -- into raised out of the handler and rolled the 1.0 write back. The
    -- sentence above is now a property of record_fold_abort, not an
    -- assumption about it, and scripts/db-test-race.sh cases 6 and 7 are the
    -- measurement.
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

    -- Queue the touched keys the budget could not afford -- the ones that
    -- actually have work. Evaluated AFTER the derive on purpose: v_overflow is
    -- disjoint from v_spend, so the derive cannot have changed the answer for
    -- any key in it, and reading it here keeps one indexed pass instead of two.
    perform private.queue_fold_backlog(
      v_uid, private.fold_keys_to_queue(v_uid, v_overflow, v_changed));

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
--
-- That last sentence is an ASSERTION, not a hope, and it was FALSE until the
-- queue was scoped: with the overflow queued unconditionally the backlog sat
-- at exactly 200 on a completely converted account for 30 consecutive passes.
-- It is now measured by supabase/tests/shift_fold_test.sql
-- (theBacklogReachesZeroUnderRepeatedIdenticalFiveHundredRowBatches), which
-- replays the identical 500-row / 250-group batch and fails if the backlog
-- does not empty. Two conditions keep it true, both worth knowing before
-- editing anything above: every insert into the backlog must go through
-- private.fold_keys_to_queue, and the jsonb round-trip of
-- legacy_source_max_updated_at through the deriver's v_grouped must stay
-- lossless -- a rounded watermark would make every key permanently
-- unconverged, and that same assertion is what would catch it.
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
