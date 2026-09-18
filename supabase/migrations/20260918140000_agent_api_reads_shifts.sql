-- PR 2 slice S11: the agent API stops being a second money engine.
--
-- THE PROBLEM, stated exactly. `supabase/functions/payday-api/index.ts`
-- carries `tipFacts` and `groupShifts`: a THIRD implementation of the
-- grouping and net rules, after the Swift one and the SQL one. It is not a
-- copy of either, and the differences are not cosmetic:
--
--   * it dates a shift by its LATEST row (`row.work_date > latest`) while iOS
--     dates it by the earliest, so a shift whose two rows straddle midnight
--     is reported on a different day by the API than by the app;
--   * it resolves shift-level detail as `credit ?? cash ?? canonical`, the
--     pre-S3 rule that correction D6 replaced with a detail rank, so a group
--     with a value on both rows can answer differently;
--   * it picks the receipt owner as "credit if it has metrics, else cash",
--     not the metrics rank the deriver uses, so a payload on a group's SECOND
--     credit row is invisible to it; and
--   * it has NO WAGE CONCEPT AT ALL, so `/v1/summary` and the app answer
--     "how much this period" with different numbers by construction rather
--     than by accident.
--
-- That last one matters most because of who reads it. A screen's divergence
-- is seen by a person who may notice; an API's divergence goes out
-- programmatically to an agent or an integration with nobody glancing at it.
--
-- THE FIX is not a fourth implementation. `public.shifts` already holds the
-- deriver's answer, one row per shift, with `gratuity_fees_cents` and
-- `non_wage_earnings_cents` as GENERATED columns -- so the net rule has
-- exactly one implementation per language, and this reads it rather than
-- recomputing it. The TypeScript math is deleted in the same slice.
--
-- What this deliberately does NOT do: invent wages. `public.shifts` has no
-- wage columns, because a wage is a property of a WORKWEEK under a rate
-- policy and not of a row. Reporting a wage-inclusive total needs the
-- device-published snapshot of Design 3, which is PR 6. Until then the API
-- reports the non-wage figures it can stand behind and says so, which is a
-- smaller claim than the one it makes today and a true one.

-- ---------------------------------------------------------------------------
-- The listing, with the same keyset contract the tip-entry version had.
-- ---------------------------------------------------------------------------
create or replace function public.payday_agent_recent_shifts(
  p_user_id uuid,
  p_start_date date default null,
  p_end_date date default null,
  p_shift_limit integer default 101,
  p_before_work_date date default null,
  p_before_recorded_at timestamptz default null,
  p_before_shift_id uuid default null
)
returns setof public.shifts
language sql
stable
security invoker
set search_path = ''
as $$
  select s.*
  from public.shifts as s
  where s.user_id = p_user_id
    and s.deleted_at is null
    and (p_start_date is null or s.work_date >= p_start_date)
    and (p_end_date is null or s.work_date <= p_end_date)
    -- The cursor, as a strict "older than" over the same triple the ordering
    -- uses. `recorded_at` is nullable, so every comparison against it has to
    -- treat null as the OLDEST value or a shift with no recorded_at becomes
    -- unreachable past the first page. `nulls last` in the ORDER BY and
    -- `coalesce(..., '-infinity')` here are the two halves of that.
    and (
      p_before_work_date is null
      or s.work_date < p_before_work_date
      or (
        s.work_date = p_before_work_date
        and (
          coalesce(s.recorded_at, '-infinity'::timestamptz)
            < coalesce(p_before_recorded_at, '-infinity'::timestamptz)
          or (
            coalesce(s.recorded_at, '-infinity'::timestamptz)
              = coalesce(p_before_recorded_at, '-infinity'::timestamptz)
            and s.id < coalesce(p_before_shift_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)
          )
        )
      )
    )
  -- Matches shifts_user_work_date_idx exactly, including the nulls-last
  -- clause, so this is an index scan rather than a sort over the account.
  order by s.work_date desc, s.recorded_at desc nulls last, s.id desc
  limit greatest(1, least(coalesce(p_shift_limit, 101), 201));
$$;

revoke all on function public.payday_agent_recent_shifts(uuid, date, date, integer, date, timestamptz, uuid)
  from public, anon, authenticated;

comment on function public.payday_agent_recent_shifts(uuid, date, date, integer, date, timestamptz, uuid) is
  'One page of derived shifts for the agent API, newest first. Replaces '
  'payday_agent_recent_tip_entries plus the TypeScript groupShifts, which was '
  'a third implementation of the grouping and net rules and disagreed with '
  'both others on the work date, the detail rank and the receipt owner.';

-- ---------------------------------------------------------------------------
-- One shift by id, including the pre-conversion case.
-- ---------------------------------------------------------------------------
create or replace function public.payday_agent_shift_by_id(
  p_user_id uuid,
  p_id uuid
)
returns setof public.shifts
language sql
stable
security invoker
set search_path = ''
as $$
  -- STEP 1: the shift's own id, which is what a post-conversion caller holds.
  select s.* from public.shifts as s
   where s.user_id = p_user_id and s.id = p_id and s.deleted_at is null
  union all
  -- STEP 2: THE PROVENANCE LOOKUP, and the reason it exists. An agent that
  -- listed shifts before the conversion holds a LEGACY ROW's id -- for a
  -- group whose rows had no shift_id, the API used the row's own id as the
  -- shift id. After conversion that id names no shift, so a plain lookup
  -- 404s on a shift the caller can see in its own earlier response. Matching
  -- on legacy_entry_ids keeps those references resolvable, which is what the
  -- gin index on that column is for.
  select s.* from public.shifts as s
   where s.user_id = p_user_id
     and s.deleted_at is null
     and p_id = any(s.legacy_entry_ids)
     and not exists (
       select 1 from public.shifts as own
        where own.user_id = p_user_id and own.id = p_id and own.deleted_at is null
     )
  limit 1;
$$;

revoke all on function public.payday_agent_shift_by_id(uuid, uuid)
  from public, anon, authenticated;

comment on function public.payday_agent_shift_by_id(uuid, uuid) is
  'One derived shift, by its own id or by a legacy row id it absorbed. The '
  'second arm keeps an id an agent obtained BEFORE the conversion resolvable '
  'afterwards; without it a caller 404s on a shift its own earlier response '
  'showed it.';
