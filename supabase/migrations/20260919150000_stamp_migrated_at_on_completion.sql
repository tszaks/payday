-- Stamp `migrated_at` when the one-shot COMPLETES, not when it writes rows.
--
-- WHY: a brand-new account never flipped to the records engine. Measured:
-- both branches of the only writer of `migrated_at` required `v_wrote > 0`,
-- and `v_wrote` is `private.derive_shifts`' `wrote_count`. An account with
-- no legacy rows converts nothing, so the stamp stayed null,
-- `ShiftReadAuthority.isAuthoritative` stayed false forever, and all eleven
-- flip-gated call sites took the legacy branch -- INCLUDING the three
-- writers, so such an account logs `tip_entries` indefinitely and the
-- records engine never activates for it.
--
-- Not a money bug: the legacy arm computes correctly and the fold still
-- produces `shifts` for the API. It is a structural blocker -- deleting the
-- legacy arm would strand every new install permanently rather than until
-- its first sync.
--
-- WHY NOT the two obvious alternatives:
--
--   Stamp without running. Fabricates history in the one column a reader
--   will trust to mean "the one-shot completed here".
--
--   Teach `isAuthoritative` that an empty legacy set is ready.
--   `payday_unmigrated_tip_row_count()` returns 0 to an UNAUTHENTICATED
--   caller -- it reads `auth.uid()` and returns 0 when null -- so "verified
--   empty" and "failed read" are the same value. That teaches the predicate
--   to accept a refused read, and an account with real legacy rows would
--   flip BEFORE conversion and show its owner an incomplete picture of
--   their own money.
--
-- This stamps because the function RAN TO COMPLETION. The column's meaning
-- becomes "the one-shot has completed for this account", which a new
-- account satisfies honestly rather than by exemption.
--
-- SAFETY: this cannot flip an account early. `migrated_at` is one of four
-- conditions, and `v_remaining` is computed AFTER the derive as unmigrated
-- groups UNION the fold backlog. A partially converted account is still
-- held by `remaining > 0`; a failed one by `conservation_failed_at`. What
-- changes is that the stamp stops doubling as a readiness proxy and becomes
-- a fact about execution.
--
-- The guarantee that a partial conversion is not authoritative used to be
-- made TWICE (missing stamp, and remaining > 0) and is now made once, so it
-- gets a named test rather than an assumption:
-- `aPartiallyConvertedAccountIsNotAuthoritative`.
--
-- `coalesce(st.migrated_at, ...)` is retained on the conflict path, so the
-- instant still never moves on a re-run -- the property the original
-- header was written to protect.

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

  -- -------------------------------------------------------------------------
  -- THE ROLLBACK GUARD, AND THE MEASURED FAILURE IT CLOSES.
  --
  -- rollback_shift_migration's rule 1 says the three triggers are disabled in
  -- the SAME TRANSACTION as the tombstoning so that "the re-converter cannot
  -- race the rollback". The triggers are not the only re-converter: THIS
  -- FUNCTION is granted to authenticated and the client calls it whenever
  -- payday_unmigrated_tip_row_count() is positive, which a 1.0 write during
  -- the rollback window makes positive. MEASURED: with rollback_at set, a 1.0
  -- device wrote one new night ($33.00), the trigger correctly folded nothing,
  -- and the client's own documented loop (count = 1, then one call here)
  -- produced a LIVE source='migration' artifact with rollback_at still set --
  -- "an account half rolled back with no record of which half", which is the
  -- exact harm rule 1 claims the same-transaction disable prevents.
  --
  -- THE GUARD IS ON THE JWT-BEARING CALLER ONLY, and that is the whole point.
  -- The client must stop converting; the OPERATOR must not, because
  -- repair_shift_migration is the forward half of the reversal and the runbook
  -- runs it BEFORE clearing rollback_at (clearing it first would point every
  -- client at a public.shifts that is still all tombstones). An operator in
  -- psql has no JWT at all and service_role is not an end user, so the test is
  -- exactly the two claims this function already captured for its authority
  -- check -- no new role test, no new GUC.
  --
  -- It returns the same null-shaped no-op as a deleted account rather than
  -- raising: a raise on this path aborts the caller's transaction, and Rule 2
  -- of this file is that nothing on the RPC path raises.
  -- -------------------------------------------------------------------------
  if v_claim_uid is not null
     and v_claim_role <> 'service_role'
     and exists (select 1 from public.shift_migration_state st
                  where st.user_id = v_uid and st.rollback_at is not null) then
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
    statement_timestamp(),   -- see header: stamped on COMPLETION, not on work done
    v_src_rows, v_shift_count, v_in, v_out,
    v_native, v_edited, v_in_closed,
    v_dup_dates_count, v_dup_dates, v_remaining,
    v_unconverted,
    case when v_failed then statement_timestamp() else null end,
    v_touched, v_orphans, v_dupes, now())
  on conflict (user_id) do update set
    migrated_at = coalesce(st.migrated_at, statement_timestamp()),
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
