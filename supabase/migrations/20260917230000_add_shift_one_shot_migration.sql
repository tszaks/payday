-- PR 2, slice S5: the one-shot migration, the counters, and rollback.
--
-- The trigger (S4) catches live legacy writes. THIS FILE IS THE ONLY RECOVERY
-- FOR WHAT THE TRIGGER NEVER SAW: rows that existed before the trigger was
-- deployed, rows loaded while session_replication_role was 'replica', rows
-- written during a deliberately disabled-trigger window, and every group in
-- private.shift_fold_backlog. Without it those rows are invisible to the new
-- build forever, and it is also what makes "no lockout" safe, because it is
-- re-runnable and bounded.
--
-- FIVE RULES DOMINATE THIS FILE.
--
-- 1. ONE `unmigrated` EXPRESSION. private.unmigrated_legacy_rows is the only
--    place the predicate is spelled. The one-shot's work set and
--    public.payday_unmigrated_tip_row_count() are both that function plus the
--    backlog, so the count the client loops on and the predicate the one-shot
--    acts on are the same expression BY CONSTRUCTION. An earlier draft had a
--    gin-containment count next to a four-armed predicate; MEASURED in the
--    state of the deriver's failing sequence (closed shift, its one legacy row
--    tombstoned, provenance still naming it) the containment reading returned
--    0 while the predicate returned 1. Reading 0 the client never re-invokes
--    and the group is silently never reconciled; reading 1 it loops forever.
--    The difference decided the blast radius of a P0.
--
-- 2. THE CONSERVATION CHECK RECORDS. IT NEVER RAISES. There is no p_strict
--    anywhere in PR 2. A raise on this path aborts the CALLER's transaction,
--    and S4 already paid for that lesson: anything that can abort is an app
--    that goes dark for a shipped 1.0 build. A failure stamps
--    conservation_failed_at plus the orphans / dupes / in / out / touched
--    detail and COMMITS.
--
-- 3. IT IS BOUNDED AND MAKES PARTIAL FORWARD PROGRESS. p_max_groups caps the
--    touched set at the OLDEST p_max_groups groups, backlog first by
--    queued_at, then unmigrated by min(client_updated_at). The first draft had
--    no budget, no batching and no partial commit: a multi-year account got
--    one all-or-nothing attempt under a 60 second timeout, and if it ever
--    exceeded that the whole RPC rolled back, the count was unchanged, and the
--    client repeated it identically forever with no state in which the account
--    advanced. remaining_group_count is written every run so progress is a
--    number rather than a retry.
--
-- 4. ROLLBACK TAKES NO ARGUMENT. `alter table ... disable trigger` is GLOBAL.
--    A per-account rollback signature disables conversion for EVERYBODY while
--    stamping rollback_at for one account, after which every other converted
--    account reads null from payday_shift_rollback_at(), keeps treating
--    public.shifts as authoritative, and keeps having 1.0 devices write
--    tip_entries that nothing folds. The unsafe operation is not expressible.
--    Per-account REPAIR is a separate artifact that touches no trigger.
--
-- 5. public.shifts IS DERIVED. public.tip_entries is never rewritten by the
--    new build, so it is the entire reversibility artifact and nothing on the
--    legacy side is unrecoverable. What rollback can and cannot restore is
--    written out in full on public.rollback_shift_migration() below, because a
--    rollback story that lives only in a design document is not a rollback
--    story.

-- ---------------------------------------------------------------------------
-- The conservation DETAIL columns.
--
-- shift_migration_state already carries the two money sides (source_ and
-- shift_non_wage_cents) and conservation_failed_at. These three carry the rest
-- of the detail the check produces, so a flagged account can be read without
-- re-running anything:
--
--   touched  how many group keys this invocation derived
--   orphans  captured live legacy rows that NO shift claims afterwards
--   dupes    captured live legacy rows claimed by MORE THAN ONE shift
--
-- orphans and dupes together are the PARTITION half of the check: every
-- captured source row is claimed by exactly one shift, live or deleted. It is
-- never `count(source rows) = count(shifts)` -- public.update_tip_entry
-- accepts shift_id, so an agent may already have moved a row, and an account
-- with zero legacy rows must pass trivially.
-- ---------------------------------------------------------------------------

alter table public.shift_migration_state
  add column if not exists conservation_touched_count integer,
  add column if not exists conservation_orphan_count integer,
  add column if not exists conservation_duplicate_claim_count integer;

comment on column public.shift_migration_state.conservation_touched_count is
  'Group keys the last invocation derived. With p_max_groups it is a budget '
  'measurement, not an account total.';
comment on column public.shift_migration_state.conservation_orphan_count is
  'Captured live legacy rows that no shift claims after the derive. Zero by '
  'construction: arm 1 writes provenance unconditionally, with no WHERE on '
  'its ON CONFLICT. A non-zero value means an upsert was silently skipped, '
  'which is the exact failure the ON CONFLICT lint exists to prevent.';
comment on column public.shift_migration_state.conservation_duplicate_claim_count is
  'Captured live legacy rows claimed by MORE THAN ONE shift. A one-row '
  'scalar, never null. MEASURED: the earlier form (count(*) from a subquery '
  'with GROUP BY ... HAVING count(*) > 1) returns one arbitrary group''s '
  'OCCURRENCE count and NULL when there are no duplicates, which is why every '
  'real raise printed dupes=<NULL> and read as "the check did not run". It '
  'silently disabled half the check for a whole review round.';
comment on column public.shift_migration_state.source_non_wage_cents is
  'The "in" side of the INVOCATION-SCOPED conservation check from the last '
  'run, not an account total. An account-wide "in" side would need a second '
  'copy of the deriver''s grouping rule, and account-wide conservation is '
  'permanently unsatisfiable anyway once one native shift, one post-conversion '
  'edit or one deletion exists (measured: orphans=0 in=4500 out=11500).';
comment on column public.shift_migration_state.shift_non_wage_cents is
  'The "out" side of the same invocation-scoped check. Closed shifts are '
  'excluded from BOTH sides, so equality is a real invariant rather than an '
  'aspiration.';
comment on column public.shift_migration_state.unconverted_legacy_cents is
  'Account-wide sum of public.shifts.unconverted_legacy_cents: the magnitude '
  'of the latest legacy disagreement per shift, which the single deriver '
  'maintains as an absolute assignment (never accumulated). Deleted shifts '
  'included, because "$20.00 from an older device arrived for a shift you '
  'deleted" is exactly this number. The per-shift audit trail is '
  'public.shift_legacy_conflicts; this column is read from public.shifts so '
  'that the displayed total cannot drift from the live rows.';

-- ---------------------------------------------------------------------------
-- THE ONE `unmigrated` EXPRESSION.
--
-- A membership-only predicate cannot see an EDIT or a TOMBSTONE of a row
-- already named by legacy_entry_ids, so deleted money would stay in the shift
-- forever and a correction would never land. Two measured miss sequences:
--
--   * a live row folded by device A then tombstoned by device B stays named
--     and its $60 lives in the shift forever;
--   * a $50 to $40 correction of an already-folded row never applies.
--
-- The four arms are therefore: never folded; folded then tombstoned; folded
-- with no watermark; folded and then written above the watermark.
--
-- DELETED shifts are included in `named` on purpose: a tombstoned conversion
-- artifact still claims its source rows, and the whole point of arms 2 to 4 is
-- to notice that the claim has gone stale.
--
-- THIS PREDICATE TERMINATES ONLY BECAUSE THE DERIVER'S ARM 2a RELEASES
-- PROVENANCE UNCONDITIONALLY. With the first draft's gated arm 2, a closed or
-- deleted shift kept naming rows it no longer derived from, so arms 2 and 4
-- were satisfied PERMANENTLY, the count never reached zero, and the client
-- re-invoked the one-shot on every sync forever. Nothing else in PR 2 clears
-- legacy_entry_ids.
--
-- CAVEAT TO CARRY: public.upsert_tip_entries writes
-- client_updated_at = least(row.client_updated_at, statement_timestamp())
-- (20260904134500) with no >= guard, so a BACKWARD-CLOCKED device can write a
-- row whose client_updated_at is BELOW an already-stamped watermark. The
-- trigger catches that write directly; this predicate would not. That is a
-- second, independent reason both mechanisms have to exist.
--
-- `select distinct` is not cosmetic. A row claimed by two shifts (which is
-- exactly what the duplicate half of the conservation check exists to find)
-- joins twice, and without the dedup the client-facing COUNT would report 2
-- rows of work for 1 row. group_key and client_updated_at are functionally
-- determined by the entry id, so the dedup is precisely one row per entry.
-- ---------------------------------------------------------------------------

create or replace function private.unmigrated_legacy_rows(p_user_id uuid)
returns table (entry_id uuid, group_key uuid, client_updated_at timestamptz)
language sql stable set search_path = '' as $$
  with named as (
    select s.id as shift_id,
           s.legacy_source_max_updated_at,
           unnest(s.legacy_entry_ids) as entry_id
    from public.shifts s
    where s.user_id = p_user_id
  )
  select distinct
         e.id,
         private.legacy_group_key(e.shift_id, e.work_date),
         e.client_updated_at
  from public.tip_entries e
  left join named n on n.entry_id = e.id
  where e.user_id = p_user_id
    and ( (n.entry_id is null and e.deleted_at is null)
       or (n.entry_id is not null
           and ( e.deleted_at is not null
              or n.legacy_source_max_updated_at is null
              or e.client_updated_at > n.legacy_source_max_updated_at)));
$$;

comment on function private.unmigrated_legacy_rows(uuid) is
  'THE `unmigrated` predicate, spelled exactly once. The one-shot''s work set '
  'and public.payday_unmigrated_tip_row_count() are both this function plus '
  'this account''s backlog, so the count the client loops on and the predicate '
  'the one-shot acts on cannot disagree. Four arms: never folded; folded then '
  'tombstoned; folded with a null watermark; folded then written above the '
  'watermark. It terminates only because the deriver''s arm 2a releases '
  'provenance unconditionally.';

-- ---------------------------------------------------------------------------
-- The companion count: the predicate plus this account's backlog size.
--
-- Definer, and it captures the subject FIRST, because a security-invoker RPC
-- calling into schema private fails 42501 (schema private has no usage grant
-- to authenticated).
--
-- The BACKLOG TERM is load-bearing and was measured, not reasoned. Under
-- pg_try_advisory_xact_lock the loser of the race does not overwrite and does
-- not block: it QUEUES its group and returns, so its money is committed in
-- public.tip_entries and named by NO shift until the backlog drains. That
-- under-count is the reason this count, the reader's first-switch predicate
-- and the explicit drain step in the sync pass all exist.
-- ---------------------------------------------------------------------------

create or replace function public.payday_unmigrated_tip_row_count()
returns integer language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid;
begin
  v_uid := (select auth.uid());
  if v_uid is null then
    return 0;
  end if;
  return (select count(*) from private.unmigrated_legacy_rows(v_uid))
       + (select count(*) from private.shift_fold_backlog b where b.user_id = v_uid);
end;
$$;

comment on function public.payday_unmigrated_tip_row_count() is
  'Literally private.unmigrated_legacy_rows plus this account''s backlog size. '
  'The client calls the one-shot at most ONCE per synchronize pass, only when '
  'this is positive, and never in a loop inside one pass: PaydayCloudGate '
  'already wraps synchronize in `while outcome.requiresFollowUpSync`, so an '
  'in-pass loop on a non-decreasing count would be a hot loop of definer calls '
  'that never reaches the checkpoint write and never surfaces, because the '
  '.ready path swallows and backs off. requiresFollowUpSync is set only when '
  'remaining_group_count STRICTLY DECREASED.';

-- ---------------------------------------------------------------------------
-- THE ONE-SHOT.
--
-- ON `set statement_timeout = '60s'`, MEASURED AND WRITTEN DOWN BECAUSE IT IS
-- NOT WHAT IT LOOKS LIKE. PostgreSQL arms the statement timer ONCE, at the
-- start of each top-level statement. A function-level SET clause changes the
-- GUC after that timer is already armed and does NOT re-arm it. Measured on
-- this schema's own cluster: a plpgsql function declared
-- `set statement_timeout = '300ms'` slept the whole 1.5 s and was never
-- cancelled, with and without a 5 s session timeout, and an in-body
-- `set local statement_timeout` behaved identically. So on the PostgREST path,
-- where `select public.migrate_tip_entries_to_shifts(...)` IS the top-level
-- statement, the real ceiling is whatever the calling role already had (on
-- Supabase, authenticated carries a role-level statement_timeout in single
-- digit seconds) and this clause can neither raise nor lower it. It ships
-- anyway, as the declaration of intent for any future non-top-level caller,
-- and the bound that actually holds is p_max_groups.
--
-- WHY THERE IS NO EXCEPTION HANDLER HERE, unlike the fold. This function does
-- not run inside a shipped 1.0 build's transaction, so an abort costs a sync
-- pass rather than a write. And it needs no backlog of its own: its work set
-- is RECOMPUTED from data by the predicate above, not read from a queue, so a
-- rollback loses no work at all. A handler that swallowed the abort would
-- instead commit an audit row reporting progress that did not happen, and
-- remaining_group_count is the one number the client's follow-up decision is
-- made on.
--
-- ONE INVOCATION PER SYNCHRONIZE PASS. The loop is ACROSS passes, with visible
-- progress, never inside one.
-- ---------------------------------------------------------------------------

create or replace function public.migrate_tip_entries_to_shifts(
  p_user_id uuid default null,
  p_max_groups integer default 200)
returns public.shift_migration_state
language plpgsql security definer
set search_path = ''
set statement_timeout = '60s'
as $fn$
declare
  v_uid uuid;
  v_claim_uid uuid;
  v_claim_role text;
  v_budget integer;
  v_backlog uuid[];        -- the reserved oldest backlog keys, spent first
  v_fresh uuid[];          -- unmigrated group keys the budget still affords
  v_keys uuid[];           -- v_backlog union v_fresh: what the deriver is given
  v_source_ids uuid[];     -- every live legacy row id in those groups, captured
  v_touched integer := 0;
  v_wrote integer := 0;
  v_in bigint := 0;
  v_out bigint := 0;
  v_dupes bigint := 0;
  v_orphans bigint := 0;
  v_failed boolean;
  v_remaining integer := 0;
  v_src_rows integer := 0;
  v_shift_count integer := 0;
  v_native integer := 0;
  v_edited integer := 0;
  v_in_closed integer := 0;
  v_unconverted bigint := 0;
  v_dup_dates_count integer := 0;
  v_dup_dates date[] := '{}';
  v_state public.shift_migration_state;
begin
  -- -------------------------------------------------------------------------
  -- The subject, captured into a local FIRST. A security-invoker RPC calling
  -- into schema private fails 42501, so this is a definer, and a definer that
  -- read auth.uid() again later would be reading it under a different set of
  -- assumptions every time.
  --
  -- A non-service-role caller may only name ITSELF. The three legal callers
  -- are: the client, passing nothing; service_role, naming an account; and an
  -- operator in psql with no JWT at all, naming an account. An authenticated
  -- caller naming somebody else is 42501, and that raise is not a conservation
  -- raise -- it happens before any work and rejects an unauthorized call.
  -- -------------------------------------------------------------------------
  v_claim_uid := (select auth.uid());
  v_claim_role := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');

  v_uid := coalesce(p_user_id, v_claim_uid);
  if v_uid is null then
    raise exception 'migrate_tip_entries_to_shifts: no subject'
      using errcode = '22023';
  end if;
  if p_user_id is not null
     and p_user_id is distinct from v_claim_uid
     and v_claim_role <> 'service_role'
     and not (v_claim_role = '' and v_claim_uid is null) then
    raise exception 'migrate_tip_entries_to_shifts: may not name another account'
      using errcode = '42501';
  end if;

  -- An account that no longer exists gets a no-op with a defined shape rather
  -- than a raise or an FK violation. The one-shot must never be the thing that
  -- fails a deletion or a raced sign-out.
  if not exists (select 1 from auth.users u where u.id = v_uid) then
    return null::public.shift_migration_state;
  end if;

  -- greatest(1, ...) so every invocation makes forward progress. A budget of
  -- zero would report "nothing changed" forever and the client's
  -- strictly-decreasing follow-up rule would stall the account permanently.
  v_budget := greatest(1, coalesce(p_max_groups, 200));

  -- -------------------------------------------------------------------------
  -- The BLOCKING advisory lock on the shared per-account key. All three
  -- writers take this key -- the fold (try), the one-shot and (in S6)
  -- private.write_shifts (both blocking) -- so their writes are serialized per
  -- account and no two can deadlock. Blocking is correct here and wrong in the
  -- fold: this call is not inside a 1.0 build's write.
  -- -------------------------------------------------------------------------
  perform pg_advisory_xact_lock(
    pg_catalog.hashtextextended('payday:shiftmig:' || v_uid::text, 0));

  -- -------------------------------------------------------------------------
  -- The work set: the OLDEST v_budget groups, backlog first by queued_at, then
  -- unmigrated by min(client_updated_at). Oldest-first is what makes a
  -- multi-year account converge from one end instead of thrashing.
  -- -------------------------------------------------------------------------
  v_backlog := array(
    select b.group_key
    from private.shift_fold_backlog b
    where b.user_id = v_uid
    order by b.queued_at, b.group_key
    limit v_budget);

  v_fresh := array(
    select u.group_key
    from private.unmigrated_legacy_rows(v_uid) u
    where not (u.group_key = any(v_backlog))
    group by u.group_key
    order by min(u.client_updated_at), u.group_key
    limit greatest(0, v_budget - cardinality(v_backlog)));

  v_keys := array(
    select distinct k from unnest(v_backlog || v_fresh) as k
    where k is not null order by k);

  -- -------------------------------------------------------------------------
  -- Captured BEFORE the derive, in one statement: every live legacy row id in
  -- the touched groups. This is exactly the deriver's own `source` set. A row
  -- that commits mid-transaction is simply not in it and is left for the next
  -- invocation; the shared lock makes that window empty in practice, and the
  -- SCOPING is what still matters.
  -- -------------------------------------------------------------------------
  v_source_ids := array(
    select e.id
    from public.tip_entries e
    where e.user_id = v_uid
      and private.legacy_group_key(e.shift_id, e.work_date) = any(v_keys)
      and e.deleted_at is null
    order by e.id);

  -- -------------------------------------------------------------------------
  -- THE SINGLE DERIVER. Same body, same group key, same gratuity rule, same
  -- `source` value ('migration') as the on-arrival trigger, which is why the
  -- two cannot disagree. It returns the two money sides of the scoped
  -- conservation check; it raises nothing of its own and records nothing.
  -- -------------------------------------------------------------------------
  select d.touched_count, d.wrote_count, d.source_cents, d.shift_cents
    into v_touched, v_wrote, v_in, v_out
  from private.derive_shifts(v_uid, v_keys) d;

  -- -------------------------------------------------------------------------
  -- ONE STRUCTURAL RULE, PAID FOR IN S4: a mutation and its assertion are
  -- never in the same statement. One SELECT has one snapshot, so an inline
  -- subquery reading a table a volatile function mutated earlier in the SAME
  -- statement still sees the pre-statement value. Everything below therefore
  -- reads in its own statement, after the derive.
  -- -------------------------------------------------------------------------

  -- THE DUPLICATE COUNT MUST BE A ONE-ROW SCALAR. Deleted shifts are INCLUDED
  -- on purpose: a tombstoned artifact that still claims a live row is a
  -- stranded claim, and finding it is the point.
  --
  -- ON THE SPELLING OF THESE TWO SCANS, MEASURED RATHER THAN REASONED. The
  -- obvious optimisation is to hand them to shifts_legacy_entry_ids_idx (gin)
  -- by writing `s.legacy_entry_ids && v_source_ids` here and
  -- `s.legacy_entry_ids @> array[e.id]` below, both of which are exactly
  -- equivalent. On a 12,000-row / 6,001-group account -- a real multi-year
  -- Payday shape -- that made the one-shot SLOWER, not faster: the last pass
  -- went from 138.9 ms to 209.4 ms and every pass after the fifth regressed.
  -- The planner prefers a plain scan of one account's shifts, and the bitmap
  -- machinery around a correlated gin probe costs more than it saves at this
  -- table width. So the straightforward spelling ships, with the number that
  -- decided it written down so the next reader does not redo the experiment.
  select count(*) into v_dupes from (
    select eid from (
      select unnest(s.legacy_entry_ids) as eid
      from public.shifts s where s.user_id = v_uid
    ) u
    where eid = any(v_source_ids)
    group by eid having count(*) > 1) d;

  -- The other half of the partition: a captured live row that NO shift claims.
  select count(*) into v_orphans
  from public.tip_entries e
  where e.user_id = v_uid
    and e.id = any(v_source_ids)
    and not exists (
      select 1 from public.shifts s
      where s.user_id = v_uid and e.id = any(s.legacy_entry_ids));

  -- RECORDED, NEVER RAISED. payday.migration_test_conservation is the only way
  -- to reach this branch from a test: with the closed-shift exclusion in place
  -- the money halves cannot be unequal after a correct derive (arm 1 rewrites
  -- every open shift's money from the same grouped row both sides are computed
  -- from, and every shift either side excludes is excluded by both), so the
  -- forced flag is what proves the recording path commits instead of raising.
  -- Same hook shape as the fold's payday.fold_test_abort, and it touches no
  -- money: it sets the flag and nothing else.
  v_failed := v_in <> v_out or v_dupes > 0 or v_orphans > 0
    or coalesce(current_setting('payday.migration_test_conservation', true), '') = 'fail';

  -- -------------------------------------------------------------------------
  -- The drained backlog keys, deleted in the SAME transaction, so they roll
  -- back with a failed derive. Exactly the keys read into v_backlog: a
  -- concurrent fold that lost the try-lock can insert a NEW backlog row while
  -- this transaction holds the lock, and deleting a key whose row this
  -- invocation's snapshot never saw would hide that row until the predicate
  -- found it again.
  -- -------------------------------------------------------------------------
  delete from private.shift_fold_backlog b
  where b.user_id = v_uid and b.group_key = any(v_backlog);

  -- Progress as a number, measured AFTER the derive: groups that still need
  -- work. The client's follow-up is gated on this STRICTLY DECREASING.
  select count(*) into v_remaining from (
    select u.group_key from private.unmigrated_legacy_rows(v_uid) u
    union
    select b.group_key from private.shift_fold_backlog b where b.user_id = v_uid) x;

  -- -------------------------------------------------------------------------
  -- The account-wide INFORMATIONAL counters. Never a raise condition, and they
  -- are expected to disagree: a native post-conversion shift has money in no
  -- source sum, an edit moves only the shift side (the new build never
  -- rewrites tip_entries), a post-conversion deletion removes money from the
  -- shift side while its sources stay live, and every trigger conversion is
  -- another legal reason, forever. Recorded every run, displayed in Data
  -- health. The real check is the invocation-scoped one above.
  -- -------------------------------------------------------------------------
  select count(*) into v_src_rows
  from public.tip_entries e where e.user_id = v_uid and e.deleted_at is null;

  select count(*) into v_shift_count
  from public.shifts s where s.user_id = v_uid and s.deleted_at is null;

  -- A shift with no provenance is natively authored. array_length of '{}' is
  -- NULL, not 0, which is why this reads `is null`.
  select count(*) into v_native
  from public.shifts s
  where s.user_id = v_uid and s.deleted_at is null
    and array_length(s.legacy_entry_ids, 1) is null;

  -- native_modified_at, NOT `converted_at < client_updated_at`. The deriver
  -- writes converted_at unconditionally while client_updated_at sits inside
  -- the open-to-fold CASE and is PRESERVED on a closed shift, so the moment
  -- the headline case occurs -- the user edits Jul 4, then an old phone pushes
  -- one unsynced $20 cash tip for Jul 4 -- converted_at jumps above
  -- client_updated_at and the edited shift drops out of this count and out of
  -- the rollback dump that uses the same comparison. native_modified_at is
  -- written only by a native write, so it is the right predicate for both.
  select count(*) into v_edited
  from public.shifts s
  where s.user_id = v_uid and s.deleted_at is null
    and s.native_modified_at is not null;

  select count(*) into v_in_closed
  from public.tip_entries e
  where e.user_id = v_uid and e.deleted_at is null
    and exists (
      select 1 from public.shifts s
      where s.user_id = v_uid and e.id = any(s.legacy_entry_ids)
        and (s.native_modified_at is not null or s.deleted_at is not null));

  select coalesce(sum(s.unconverted_legacy_cents)::bigint, 0) into v_unconverted
  from public.shifts s where s.user_id = v_uid;

  -- SAME-DAY DUPLICATION IS REPORTED, NOT PREVENTED. A post-conversion native
  -- shift is keyed by a random uuid because the product supports lunch and
  -- dinner on one date, while a folded legacy group keys on
  -- payday_legacy_shift_id(work_date). The ids differ, both rows are legal
  -- under the composite key, and the night is counted twice. An old build can
  -- produce that any week for years, and refusing to commit would wedge the
  -- fold, so it is a standing surface: account-wide on this path, scoped to
  -- the touched dates on the trigger path.
  select count(*), coalesce(array_agg(distinct d.work_date), '{}')
    into v_dup_dates_count, v_dup_dates
  from (select s.work_date from public.shifts s
        where s.user_id = v_uid and s.deleted_at is null
        group by s.work_date, coalesce(s.shift_period, '')
        having count(*) > 1
           and count(*) filter (where array_length(s.legacy_entry_ids, 1) > 0) > 0
           and count(*) filter (where array_length(s.legacy_entry_ids, 1) is null) > 0) d;

  -- -------------------------------------------------------------------------
  -- The audit row.
  --
  -- migrated_at RECORDS THE FIRST CONVERSION INSTANT AND MUST NOT MOVE ON A
  -- RE-RUN. Measured: a second call with nothing unmigrated moved it from
  -- 15:38:00.45385 to 15:38:00.491464. Not rare -- the client re-invokes
  -- whenever the count is positive, and a reinstalled device meeting an
  -- already-converted server lands here exactly. Written as an explicit CASE
  -- so the next reader sees the rule rather than a missing line.
  --
  -- rollback_at is likewise NEVER overwritten, and conservation_failed_at is
  -- never cleared: it is a history, and Data health renders it.
  -- -------------------------------------------------------------------------
  insert into public.shift_migration_state as st (
    user_id, migrated_at, source_row_count, shift_count,
    source_non_wage_cents, shift_non_wage_cents,
    native_shift_count, edited_since_conversion_count, rows_in_closed_shifts,
    duplicate_work_date_count, duplicate_work_dates, remaining_group_count,
    unconverted_legacy_cents, conservation_failed_at,
    conservation_touched_count, conservation_orphan_count,
    conservation_duplicate_claim_count, last_run_at)
  values (
    v_uid,
    case when v_wrote > 0 then statement_timestamp() else null end,
    v_src_rows, v_shift_count, v_in, v_out,
    v_native, v_edited, v_in_closed,
    v_dup_dates_count, v_dup_dates, v_remaining,
    v_unconverted,
    case when v_failed then statement_timestamp() else null end,
    v_touched, v_orphans, v_dupes, now())
  on conflict (user_id) do update set
    migrated_at = case when v_wrote > 0
                       then coalesce(st.migrated_at, statement_timestamp())
                       else st.migrated_at end,
    source_row_count = excluded.source_row_count,
    shift_count = excluded.shift_count,
    source_non_wage_cents = excluded.source_non_wage_cents,
    shift_non_wage_cents = excluded.shift_non_wage_cents,
    native_shift_count = excluded.native_shift_count,
    edited_since_conversion_count = excluded.edited_since_conversion_count,
    rows_in_closed_shifts = excluded.rows_in_closed_shifts,
    duplicate_work_date_count = excluded.duplicate_work_date_count,
    duplicate_work_dates = excluded.duplicate_work_dates,
    remaining_group_count = excluded.remaining_group_count,
    unconverted_legacy_cents = excluded.unconverted_legacy_cents,
    conservation_failed_at =
      coalesce(excluded.conservation_failed_at, st.conservation_failed_at),
    conservation_touched_count = excluded.conservation_touched_count,
    conservation_orphan_count = excluded.conservation_orphan_count,
    conservation_duplicate_claim_count = excluded.conservation_duplicate_claim_count,
    last_run_at = excluded.last_run_at
  returning st.* into v_state;

  return v_state;
end;
$fn$;

comment on function public.migrate_tip_entries_to_shifts(uuid, integer) is
  'The one-shot: the ONLY recovery for legacy rows the on-arrival trigger '
  'never saw (pre-deploy rows, replica-mode loads, disabled-trigger windows, '
  'and the backlog). Bounded by p_max_groups, oldest groups first, backlog '
  'before unmigrated, with partial forward progress and '
  'remaining_group_count written every run. Idempotent: two calls over the '
  'same state produce byte-identical rows, and migrated_at never moves after '
  'the first conversion. Conservation is RECORDED, never raised. Calls '
  'private.derive_shifts, the single deriver, so it cannot disagree with the '
  'trigger. Takes the BLOCKING pg_advisory_xact_lock on payday:shiftmig:<uid>. '
  'No exception handler on purpose: its work set is recomputed from data by '
  'private.unmigrated_legacy_rows rather than read from a queue, so an abort '
  'loses no work, and a swallowed abort would commit an audit row reporting '
  'progress that did not happen. MEASURED on a 12,000-row / 6,001-group '
  'account: 31 passes of 200 converge 5801 remaining to 0, per-pass wall clock '
  '43.9 ms rising to 138.9 ms as public.shifts fills, and '
  'payday_unmigrated_tip_row_count() on the converged account is 3.1 ms.';

-- ---------------------------------------------------------------------------
-- PER-ACCOUNT REPAIR. A separate artifact, deliberately, so that "fix this one
-- account" and "roll everybody back" are not the same call with a different
-- argument. It touches no trigger and is idempotent.
--
-- IT PRESENTS EVERY LEGACY GROUP KEY, NOT ONLY THE UNMIGRATED ONES, AND THAT
-- DIFFERENCE WAS MEASURED, NOT REASONED. An earlier version of this function
-- was `select public.migrate_tip_entries_to_shifts(p_user_id, 1000000)` and
-- nothing else. Executed against a ROLLED BACK account it converted NOTHING:
-- rollback tombstones the artifacts but leaves legacy_entry_ids and
-- legacy_source_max_updated_at intact, so every arm of the `unmigrated`
-- predicate is correctly false -- the rows are live, named, and at or below
-- their watermark -- and the one-shot has genuinely nothing to catch up on.
-- Re-converting a rolled-back account is not catching up, it is RE-DERIVING,
-- and the deriver's un-delete arm only reopens a 'converted' tombstone for a
-- key it was actually given. So repair hands it the keys, through the backlog,
-- which is already the "these keys need work" channel; it adds no second copy
-- of anything and no second grouping rule.
--
-- Groups whose every legacy row is tombstoned are deliberately NOT presented:
-- their artifact is already tombstoned and leaving it that way is correct.
-- ---------------------------------------------------------------------------

create or replace function public.repair_shift_migration(p_user_id uuid)
returns public.shift_migration_state
language plpgsql security definer set search_path = '' as $$
begin
  perform private.queue_fold_backlog(p_user_id, array(
    select distinct private.legacy_group_key(e.shift_id, e.work_date)
    from public.tip_entries e
    where e.user_id = p_user_id and e.deleted_at is null));

  return public.migrate_tip_entries_to_shifts(p_user_id, 1000000);
end;
$$;

comment on function public.repair_shift_migration(uuid) is
  'One account, every legacy group key re-presented through the backlog, '
  'unbounded budget, no trigger touched. The operator path for "this account '
  'is behind" and the forward half of a rollback reversal. A plain '
  'migrate_tip_entries_to_shifts run cannot do it: after a rollback the '
  'artifacts still carry provenance at an up-to-date watermark, so the '
  'unmigrated predicate correctly reports nothing to do (measured). NOT '
  'granted to authenticated or service_role -- it names an account, so it is '
  'run as the owner from the SQL editor.';

-- ---------------------------------------------------------------------------
-- ROLLBACK.
--
-- WHAT public.shifts IS. It is DERIVED. public.tip_entries is the legacy write
-- surface, every shipped 1.0 build still writes it, and the new build NEVER
-- rewrites it. That single rule is the entire reversibility artifact.
--
-- IS ROLLBACK SIMPLY "STOP READING shifts"? Almost, and that is the point of
-- this shape: there is no lockout to undo. But three things are not automatic,
-- and skipping any one leaves an account worse off than before:
--
--   1. THE TRIGGERS MUST BE DISABLED IN THE SAME TRANSACTION AS THE
--      TOMBSTONING, or the next legacy write from any 1.0 device re-converts
--      its group and partially un-rolls the rollback, leaving an account half
--      rolled back with no record of which half.
--   2. THE CLIENT MUST BE WALKED BACK DELIBERATELY. A device that cannot be
--      downgraded reads public.shifts, so tombstoning the artifacts without
--      telling it leaves it rendering an EMPTY HISTORY while intact TipEntry
--      rows sit unreadable on disk. public.payday_shift_rollback_at() is how
--      it is told; clearing shiftsAreAuthoritativeAt is what returns the
--      reader to the legacy leg.
--   3. A NATIVELY AUTHORED SHIFT HAS NO LEGACY REPRESENTATION, so rollback
--      HIDES it rather than destroying it.
--
-- WHAT ROLLBACK RESTORES
--
--   * Every cent any 1.0 build ever wrote. tip_entries was never rewritten, so
--     the old build's own screens read exactly what they read before PR 2.
--   * No later conversion: the three triggers are off, so the re-converter
--     cannot race the rollback.
--   * No derived history on the new build: every artifact (source =
--     'migration' with provenance) is tombstoned.
--   * Every account's client returns to the legacy read leg, because EVERY
--     shift_migration_state row is stamped in the same transaction.
--
-- WHAT ROLLBACK CANNOT RESTORE, AND THE COMPENSATING ACTION
--
--   * A POST-CONVERSION DELETION RESURRECTS. The user deleted a shift on the
--     new build; that queues legacy tombstones, but the flush can legitimately
--     have written none of them, and an Undo may have re-pushed them. Tombstone
--     the artifacts and the legacy rows are still LIVE, so the old build shows
--     a night the user deleted. COMPENSATING ACTION, BEFORE calling this
--     function: run public.soft_delete_tip_entries over the legacy_entry_ids of
--     every shift with deleted_reason = 'user' and assert its RETURN SET equals
--     the requested set. This function does not do it for you, because doing it
--     silently would be a destructive write to the one table that is the
--     reversibility artifact.
--   * A POST-CONVERSION EDIT REVERTS in the old build's display. R1 means
--     tip_entries was never rewritten, so the pre-edit values are what a 1.0
--     device shows. COMPENSATING ACTION, BEFORE calling this function: dump
--     `select * from public.shifts where native_modified_at is not null`. NOT
--     `converted_at < client_updated_at` -- see the edited_since_conversion_count
--     comment above for the measured reason that comparison silently omits
--     exactly the shifts most likely to need recovery.
--   * A NATIVELY AUTHORED SHIFT BECOMES INVISIBLE to a legacy reader, by
--     design: it has no tip_entries representation. COMPENSATING ACTION: dump
--     `select * from public.shifts where array_length(legacy_entry_ids,1) is
--     null and deleted_at is null`.
--   * A shift the fold tombstoned as 'converted' whose sources were later
--     un-deleted is tombstoned again. Nothing is needed: the legacy rows are
--     live, so the old build shows the night.
--
-- WHAT IS UNRECOVERABLE
--
--   NOTHING ON THE LEGACY SIDE, and nothing at all is hard-deleted here except
--   private.shift_fold_backlog, which is a pure work queue and is redundant
--   with the predicate: every reason a key is queued (a lost try-lock, a budget
--   overflow, a swallowed abort) leaves its rows either unnamed or named with a
--   stale watermark, which is precisely what private.unmigrated_legacy_rows
--   finds. So even that deletion loses no work.
--
--   Every row this function touches on the shift side is SOFT-deleted, so the
--   natively authored shifts and the post-conversion edits are hidden, not
--   destroyed, and both dumps above can be taken after the fact from the
--   tombstoned rows. The one thing that would be unrecoverable is a hard
--   delete of public.shifts, which is why this function does not contain one.
--
-- TWO OPERATIONAL FACTS
--
--   * `alter table ... disable trigger` takes ACCESS EXCLUSIVE on
--     public.tip_entries. Rollback therefore BLOCKS EVERY DEVICE'S WRITES on
--     the app's only legacy write table for its duration, and queues behind any
--     open transaction on it.
--   * RE-ENABLING IS AN EXPLICIT SEPARATE OPERATOR STEP, and it is THREE
--     statements, not one, because the triggers saw nothing at all while they
--     were off, the backlog was emptied, and every client is still being told
--     to stay on the legacy leg:
--
--       alter table public.tip_entries enable trigger tip_entries_fold_insert;
--       alter table public.tip_entries enable trigger tip_entries_fold_update;
--       alter table public.tip_entries enable trigger tip_entries_fold_delete;
--       select public.repair_shift_migration(id) from auth.users;
--       update public.shift_migration_state set rollback_at = null;
--
--     public.repair_shift_migration, NOT migrate_tip_entries_to_shifts: see the
--     measured reason on that function. And the rollback_at clear is not
--     optional -- while it is set, every client keeps clearing its shift state
--     on every sync, so a re-converted account would be re-derived on the
--     server and read by nobody.
--
-- `source = 'migration'` PLUS legacy_entry_ids IS THE ONLY SAFE ROLLBACK
-- QUERY, which is why that source value is load-bearing: writing 'device' there
-- would leave no way to tell a conversion artifact from a shift the user
-- authored.
-- ---------------------------------------------------------------------------

create or replace function public.rollback_shift_migration()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_tombstoned integer := 0;
begin
  -- Global, and in the same transaction as the tombstoning.
  alter table public.tip_entries disable trigger tip_entries_fold_insert;
  alter table public.tip_entries disable trigger tip_entries_fold_update;
  alter table public.tip_entries disable trigger tip_entries_fold_delete;

  update public.shifts
     set deleted_at = coalesce(deleted_at, statement_timestamp()),
         deleted_reason = coalesce(deleted_reason, 'converted')
   where source = 'migration' and array_length(legacy_entry_ids, 1) > 0;
  get diagnostics v_tombstoned = row_count;

  delete from private.shift_fold_backlog;

  -- EVERY row, same transaction. rollback_at is never overwritten.
  update public.shift_migration_state
     set rollback_at = coalesce(rollback_at, statement_timestamp());

  return v_tombstoned;
end;
$$;

comment on function public.rollback_shift_migration() is
  'NO ARGUMENT, because `alter table ... disable trigger` is GLOBAL and a '
  'per-account signature would disable conversion for everybody while stamping '
  'rollback_at for one account, leaving every other converted account reading '
  'null from payday_shift_rollback_at(), still treating public.shifts as '
  'authoritative, and still taking 1.0 writes that nothing folds. Takes ACCESS '
  'EXCLUSIVE on public.tip_entries, so it blocks every device''s writes for its '
  'duration. Re-enabling the three triggers is a separate operator step and '
  'must be followed by one migrate_tip_entries_to_shifts run per account. '
  'Returns the number of conversion artifacts tombstoned. Nothing on the legacy '
  'side is unrecoverable: tip_entries is never rewritten by the new build, and '
  'the full "what this restores, what it cannot, and what is unrecoverable" '
  'account is in the comment block above this function in the migration file. '
  'Per-account repair is public.repair_shift_migration.';

-- ---------------------------------------------------------------------------
-- The stamp every client reads, at the TOP of synchronize, from one call site,
-- pinned to a single definition by scripts/design-lint.sh.
--
-- A 1.0 device reads nothing about rollback and simply keeps writing, which is
-- correct: with the triggers disabled its writes land in tip_entries and are
-- read by its own screens, exactly as before PR 2.
-- ---------------------------------------------------------------------------

create or replace function public.payday_shift_rollback_at()
returns timestamptz language sql stable security definer set search_path = '' as $$
  select st.rollback_at
  from public.shift_migration_state st
  where st.user_id = (select auth.uid());
$$;

comment on function public.payday_shift_rollback_at() is
  'Non-null means the conversion was rolled back. On a non-null value the '
  'client clears shiftIDs, shiftServerCursor, shiftClientUpdatedAt, '
  'shiftServerAckedIDs, shiftWriteAttempts, pendingShiftRestores and '
  'shiftsAreAuthoritativeAt, stops pushing shifts, and deletes every local '
  'ShiftRecord and every durable ShiftTombstone -- otherwise a later '
  're-forward-migration meets a stale cache. Clearing '
  'shiftsAreAuthoritativeAt is what returns the reader to the legacy leg.';

-- ---------------------------------------------------------------------------
-- Grants. Supabase's default privileges grant EXECUTE on every new function in
-- schema public to anon, authenticated and service_role, so the revoke is what
-- makes the grant mean something.
--
-- rollback_shift_migration is revoked from EVERYBODY, service_role included. It
-- is a global kill switch that takes ACCESS EXCLUSIVE on the app's only legacy
-- write table; it is run as the owner, from the SQL editor, by a person who has
-- read the comment above it. repair_shift_migration likewise, because it names
-- an account.
-- ---------------------------------------------------------------------------

revoke all on function public.migrate_tip_entries_to_shifts(uuid, integer)
  from public, anon;
grant execute on function public.migrate_tip_entries_to_shifts(uuid, integer)
  to authenticated;

revoke all on function public.payday_unmigrated_tip_row_count() from public, anon;
grant execute on function public.payday_unmigrated_tip_row_count() to authenticated;

revoke all on function public.payday_shift_rollback_at() from public, anon;
grant execute on function public.payday_shift_rollback_at() to authenticated;

revoke all on function public.rollback_shift_migration()
  from public, anon, authenticated, service_role;
revoke all on function public.repair_shift_migration(uuid)
  from public, anon, authenticated, service_role;
