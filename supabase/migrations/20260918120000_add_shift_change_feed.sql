-- PR 2 slice S8: the shift change feed, and the cursor fence it exists for.
--
-- CORRECTION TO S6. S6 shipped the shift read path as an ordinary PostgREST
-- table select with the same `(updated_at, id)` keyset cursor the tip leg
-- uses, and I explicitly declined to return a server timestamp with each
-- page, on the grounds that a timestamp read in a SEPARATE statement from the
-- page is not a safe fence. That half was right. The conclusion was wrong: I
-- treated it as interchangeable with the snapshot design's `dataset_revision`
-- watermark, and they solve different problems. This is the missing half.
--
-- WHAT THE PLAIN KEYSET CURSOR GETS WRONG, and why it is fatal here and only
-- here. `updated_at` is written by private.touch_shift_row() as `now()`,
-- which in Postgres is the TRANSACTION timestamp, not the commit time. The
-- fold runs in an AFTER-STATEMENT trigger at the end of a 1.0 device's batch
-- transaction, and that batch is up to 500 rows plus as many as 50 groups of
-- fold work, so it can be open for seconds. Then:
--
--   10:00:00.000  T1 begins; folds shift S, stamping updated_at = 10:00:00.000
--   10:00:01.500  T2 pulls deltas. S is uncommitted and INVISIBLE. T2 sees an
--                 unrelated row at 10:00:01.500 and advances its cursor there.
--   10:00:02.000  T1 commits. S is now visible, stamped 10:00:00.000.
--   forever after every delta filters updated_at > 10:00:01.500, so S is
--                 NEVER RETURNED AGAIN, on any device.
--
-- On the tip leg that hazard is pre-existing and survivable. On the shift leg
-- it is fatal, for three reasons that have to be taken together:
--
--   * `public.shifts` is the ONLY read surface on that leg, so there is no
--     second path by which the row arrives;
--   * the writer is a THIRD PARTY (another device's 1.0 build), so the
--     post-push readback over the ids THIS device wrote never covers it; and
--   * shiftCacheRequiresBaseline compares ID SETS only, so a shift that is
--     present but stale never forces a re-baseline.
--
-- The PR 2 build would then show the pre-fold number for that shift
-- indefinitely, with nothing anywhere indicating a problem.
--
-- THE FIX, and why it must be an RPC rather than two requests. The fence is
--
--     cursor = min(max(updated_at) among pulled rows, server_now - 300s)
--
-- and it is only sound if `server_now` is the snapshot time of the very read
-- that produced the rows. Read it in a separate statement and it is a
-- different snapshot: a transaction can commit between the two reads with an
-- `updated_at` earlier than the timestamp, and the client would advance past
-- it. So the page and the timestamp are returned together, by one statement,
-- which is the whole reason this function exists at all.
--
-- 300 seconds is the window, from PaydaySyncState.shiftCursorSafetyWindow.
-- Rows inside it are re-pulled next pass, which costs nothing: reconciling a
-- shift is idempotent and the volume is one account's recent shifts.

create or replace function public.fetch_shift_changes(
  p_after_updated_at timestamptz default null,
  p_after_id uuid default null,
  p_limit integer default 1000
)
returns jsonb
language sql
stable
-- INVOKER, not definer. This only reads public.shifts, never schema private,
-- so there is no 42501 to wrap around -- and invoker means the shifts_select_own
-- RLS policy is the thing deciding what comes back, rather than a definer
-- function that has to re-implement that decision correctly.
security invoker
set search_path = ''
as $$
  with bounds as (
    -- Both of these are read inside the same statement as the page below, so
    -- `server_now` IS that page's snapshot time. This is the correction.
    select statement_timestamp() as server_now, (select auth.uid()) as uid
  ),
  page as (
    select s.*
    from public.shifts s, bounds b
    where s.user_id = b.uid
      and (
        p_after_updated_at is null
        or s.updated_at > p_after_updated_at
        or (
          s.updated_at = p_after_updated_at
          and s.id > coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)
        )
      )
    -- The same (updated_at, id) ordering the shipped tip cursor uses, so one
    -- transaction stamping a whole batch with an identical timestamp cannot
    -- make the client skip rows.
    order by s.updated_at, s.id
    -- Capped server-side as well as client-side: a client asking for a
    -- million rows is a client bug, not a licence.
    limit greatest(1, least(coalesce(p_limit, 1000), 1000))
  )
  select jsonb_build_object(
    'server_now', (select server_now from bounds),
    'rows', coalesce(
      (select jsonb_agg(to_jsonb(p) order by p.updated_at, p.id) from page p),
      '[]'::jsonb
    )
  );
$$;

revoke all on function public.fetch_shift_changes(timestamptz, uuid, integer)
  from public, anon;
grant execute on function public.fetch_shift_changes(timestamptz, uuid, integer)
  to authenticated;

comment on function public.fetch_shift_changes(timestamptz, uuid, integer) is
  'One page of shift changes AND the snapshot time that page was read at, '
  'returned together by one statement. Read separately they are two '
  'snapshots, and a transaction committing between them with an earlier '
  'updated_at would be skipped by the client''s cursor forever -- which is '
  'exactly what a slow 1.0 batch transaction produces, because updated_at is '
  'the transaction timestamp and the fold runs at the end of the batch. The '
  'client clamps its cursor to server_now minus 300s.';
