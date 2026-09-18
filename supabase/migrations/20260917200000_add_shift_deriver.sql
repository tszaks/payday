-- PR 2, slice S3: the single deriver.
--
-- private.derive_shifts(uuid, uuid[]) is the ONLY code that turns legacy
-- public.tip_entries rows into public.shifts rows. The on-arrival trigger
-- (S4) and the one-shot public.migrate_tip_entries_to_shifts (S5) both call
-- it identically, so they cannot disagree about grouping, receipt
-- arithmetic, tip-out, hours, or what happens when conservation fails.
--
-- Three things about this file are normative rather than stylistic:
--
-- 1. There is no p_strict. Conservation RECORDS, it never raises, on both
--    paths. An earlier draft gave the RPC path p_strict := true, which was
--    unsatisfiable against two other rules: provenance must be written
--    unconditionally onto a CLOSED shift, and a closed shift's money is by
--    definition no longer equal to its legacy sources, so the one-shot
--    raised identically on run 1, 2 and 3 for the most ordinary sequence
--    there is (old build logs $50, user corrects the night on the new build,
--    old phone then deletes the tip) and rolled its own bookkeeping back
--    with it. This function therefore returns the conservation numbers and
--    lets its callers record them.
--
-- 2. The source/ranked/owned/grouped chain is evaluated EXACTLY ONCE per
--    invocation, into the jsonb local v_grouped, and all four write arms plus
--    the conservation check read that local. Repeating the chain per arm
--    would give four copies of a money rule AND four snapshots, because at
--    READ COMMITTED each statement takes a fresh one and a concurrent writer
--    that lost the fold's try-lock still COMMITS its legacy row before
--    returning. A temporary table is not an option either: `create temporary
--    table ... on commit drop` makes the body non-reentrant (measured:
--    `relation "_incoming" already exists` on the second call in one
--    transaction), and the trigger calls this several times per transaction.
--
-- 3. payday.folding is set transaction-local here and by nothing else, and is
--    cleared immediately before every return, including inside the exception
--    handler. Transaction-local means it otherwise outlives the fold: once a
--    fold has run, every later UPDATE to public.shifts in the same
--    transaction would take private.touch_shift_row()'s derived branch,
--    freezing `version` and turning the agent API's
--    .eq("version", expected_version) guard into a no-op instead of a 409.
--
-- The function raises nothing of its own, and it swallows nothing either: on
-- an abort it clears the GUC and re-raises, because the caller is the layer
-- that must record the failure in private.shift_fold_failures with the real
-- sqlstate and queue the keys into private.shift_fold_backlog (S4). A
-- deriver that swallowed the abort would make that record impossible and
-- silently drop the work.

-- ---------------------------------------------------------------------------
-- A shift is open to the fold only while no human and no agent has touched
-- it. native_modified_at is written by private.write_shifts (S6) and by
-- nothing else; the fold never writes it.
-- ---------------------------------------------------------------------------

create or replace function private.shift_is_open_to_fold(s public.shifts)
returns boolean language sql immutable set search_path = '' as $$
  select s.native_modified_at is null and s.deleted_at is null;
$$;

comment on function private.shift_is_open_to_fold(public.shifts) is
  'The precedence rule, in one place: a shift that has been natively edited, '
  'natively authored or natively deleted is CLOSED to the fold and its money '
  'columns are never rewritten by a conversion. Provenance is still written '
  'unconditionally, so the partition stays total and nothing is orphaned.';

-- ---------------------------------------------------------------------------
-- The net rule, in the deriver's language.
--
-- public.shifts.non_wage_earnings_cents is `generated always as ... stored`,
-- which gives the net rule exactly one implementation per language. This is
-- that one implementation for plpgsql/SQL callers: the deriver needs the
-- folded net of a group BEFORE any row exists to read it off (arm 1's
-- unconverted_legacy_cents, arm 4's conflict rows, the conservation "in"
-- side), and hand-writing the arithmetic three more times is how a money
-- rule drifts. The gratuity half is not re-spelled at all -- it goes through
-- private.receipt_gratuity_cents, the same function the generated columns
-- call.
--
-- Clamped in NUMERIC space at both ends, never int4: cash 2147483000 +
-- gratuity 2000000 aborts with 22003 in int4 space even though every input is
-- in range, and an abort here is a rejected write from a shipped 1.0 build.
--
-- Agreement with the generated column is asserted, not assumed:
-- supabase/tests/shift_deriver_test.sql checks
--   non_wage_earnings_cents = private.legacy_non_wage_cents(cash, credit, receipt, tip_out)
-- on every row every fixture in that suite produces, including the
-- out-of-range and fractional payloads.
-- ---------------------------------------------------------------------------

create or replace function private.legacy_non_wage_cents(
  p_cash integer, p_credit integer, p_receipt jsonb, p_tip_out integer)
returns integer language sql immutable set search_path = '' as $$
  select greatest(-2147483648::numeric, least(2147483647::numeric,
      coalesce(p_cash, 0)::numeric + coalesce(p_credit, 0)::numeric
    + private.receipt_gratuity_cents(p_receipt)::numeric
    - coalesce(p_tip_out, 0)::numeric))::integer;
$$;

comment on function private.legacy_non_wage_cents(integer, integer, jsonb, integer) is
  'cash + credit + gratuity - tip_out, computed and clamped in numeric space: '
  'the SQL-callable twin of public.shifts.non_wage_earnings_cents'' generated '
  'expression. The two spellings are pinned equal by '
  'supabase/tests/shift_deriver_test.sql; changing either one alone is a '
  'money bug that no error message would report.';

-- ---------------------------------------------------------------------------
-- The single deriver.
-- ---------------------------------------------------------------------------

create or replace function private.derive_shifts(
  p_user_id uuid, p_group_keys uuid[]
) returns table (touched_count integer, wrote_count integer,
                 source_cents bigint, shift_cents bigint, conflicts integer)
language plpgsql security definer set search_path = '' as $fn$
declare
  v_keys uuid[];
  v_grouped jsonb;
  v_rows integer := 0;
  v_wrote integer := 0;
  v_conflicts integer := 0;
begin
  touched_count := 0;
  wrote_count := 0;
  source_cents := 0;
  shift_cents := 0;
  conflicts := 0;

  -- Deduplicated and sorted: the callers pass the union of old and new group
  -- keys and may repeat one, and a sorted key list is what keeps two
  -- concurrent sessions from taking row locks in opposite orders.
  v_keys := array(
    select distinct k
    from unnest(coalesce(p_group_keys, '{}'::uuid[])) as k
    where k is not null
    order by k);

  -- An empty or junk invocation is a no-op with defined output, never an
  -- error: the trigger calls this with whatever the transition tables held.
  if p_user_id is null or cardinality(v_keys) = 0 then
    return next;
    return;
  end if;

  touched_count := cardinality(v_keys);

  perform set_config('payday.folding', 'on', true);

  -- -------------------------------------------------------------------------
  -- ONE evaluation of the grouping chain.
  --
  -- metrics_rank is OBJECT-FIRST, then credit, then id. Ranking on
  -- `receipt_metrics is not null` instead is a measured $42.00 money bug: a
  -- non-object payload ("hi") is not null, so it won rank 1, no subtraction
  -- happened on any row, and the object payload's gratuity was then ADDED by
  -- the generated column without ever being SUBTRACTED -- cash 5000 /
  -- credit 2000 / gratuity 4200 / non-wage 11200 where the answer is
  -- 800 / 2000 / 4200 / 7000. Object-first is also what keeps the gratuity
  -- OWNER and the group's STORED payload the same row by construction.
  --
  -- The `filter (where jsonb_typeof(...) = 'object')` on the payload
  -- aggregate stays: it is what keeps a group in which NO row holds an
  -- object payload from storing a scalar and violating
  -- shifts_receipt_is_object.
  --
  -- detail_rank is credit-first then id. Every scalar is resolved as the
  -- first NON-NULL in that order across ALL of a group's rows: a tip-out
  -- duplicated onto both rows of a group must subtract once, and a value
  -- sitting on a group's SECOND credit row must not be invisible.
  --
  -- On the scope of the claim "this is a port of ShiftDetails.resolve".
  -- When this file was first written it was NOT a port; it was the correct
  -- rule next to a different one. ShiftDetails.resolve was
  -- `first{kind == .credit} ?? first{kind == .cash}` PER FIELD, with no rank
  -- and no visibility of a second row of either kind, and for a group of
  -- exactly one cash row plus one credit row the two rules agree to the cent
  -- -- which is why N1/N3/N4/N5/L1/L2/P6 all passed under both and none of
  -- them could see it. MEASURED on the real shipped TipBreakdown over a
  -- four-row group (fixture P7: cash 5000 a1, credit 2000 tip-out 1000 b1,
  -- cash 1000 c1, credit 3000 carrying a v1 receipt with gratuity 4200 d1),
  -- Swift returned TWO different answers for identical data depending on
  -- array order -- 6000/5000/0/1000/10000 in 12 of the 24 orderings and
  -- 6000/2000/4200/0/12200 in the other 12 -- and this fold agreed with
  -- neither: it folds that group to 6000/2000/4200/1000/11200.
  --
  -- Conservation cannot catch that class of disagreement at all. Both sides
  -- of the check are THIS fold's own grouping, so P7 returns
  -- source_cents = shift_cents = 11200 with conflicts = 0 while both shipped
  -- readers are wrong. Only a pinned fixture catches it, which is what P7 is.
  --
  -- The ranking was therefore ported INTO Swift rather than the reverse,
  -- because the fold's answer is the correct one: ShiftDetails now carries
  -- detailRanked / metricsRanked / metricsOwner, resolves every scalar as the
  -- first non-null in detail-rank order across all rows, and writes onto
  -- detail rank 1. The same five numbers are literals in
  -- supabase/tests/shift_deriver_test.sql (P7) and in
  -- PaydayTests/ShiftGroupRankingParityTests.swift, so neither side can move
  -- alone. One asymmetry remains and is deliberate: this file ranks on
  -- `jsonb_typeof(...) = 'object'`, while Swift can only see a payload that
  -- DECODES as ShiftReceiptMetrics, so an object-but-undecodable payload
  -- outranks on this side and is nil on that one. The sanitizer below is what
  -- confines it to un-folded legacy rows, and
  -- ShiftRecord.receiptPayloadIsUnreadable is the surface that reports it.
  --
  -- The agent API's groupShifts (supabase/functions/payday-api/index.ts) is
  -- still a THIRD reader of the legacy rows with the old first-credit rule
  -- and a max(work_date) that correction D1 already names as wrong. It is
  -- deliberately NOT patched here: its slice replaces that function with a
  -- read of public.shifts, and porting a ranking into code scheduled for
  -- deletion would be the fourth copy of a money rule, not the second.
  --
  -- min(work_date), never max: ShiftDays and StatsEngine use min, and the
  -- agent API's groupShifts reduced to the largest, which is correction D1.
  --
  -- The v1-to-v2 receipt conversion ports the READ path (TipBreakdown.total:
  -- resolve the owner, then max(0, amount - gratuity) on THAT ROW ONLY), not
  -- LogTipSheet.gratuityFeesBinding's edit path, which moves the whole
  -- folded gratuity to the other kind. On the N4 shape that difference is
  -- $22.00 and a different cash-versus-credit split, and the split is what
  -- drives the paycheck comparison.
  --
  -- Sums widen to bigint and then clamp into int4: amount_cents is int4, a
  -- junk account can overflow a group sum, and an overflow is a statement
  -- abort, which here is a rejected 1.0 write.
  --
  -- The scope filter is inside `source`, so it precedes the group by. Two
  -- shifts on one work_date (lunch and dinner, or a late legacy row next to a
  -- native shift) are different group keys, and deriving one of them must
  -- never read the other's rows.
  -- -------------------------------------------------------------------------
  v_grouped := (
    select coalesce(jsonb_agg(to_jsonb(g) order by g.id), '[]'::jsonb)
    from (
      with source as (
        select e.*, private.legacy_group_key(e.shift_id, e.work_date) as group_key
        from public.tip_entries e
        where e.user_id = p_user_id
          and private.legacy_group_key(e.shift_id, e.work_date) = any(v_keys)
          and e.deleted_at is null
      ),
      ranked as (
        select s.*,
          -- `nulls last` is load-bearing and was MEASURED, not reasoned.
          -- jsonb_typeof(NULL) is NULL, so `jsonb_typeof(receipt_metrics) =
          -- 'object'` is NULL on a row with no payload at all -- not false --
          -- and `order by ... desc` defaults to NULLS FIRST. Without `nulls
          -- last` a row carrying NO receipt outranks the row carrying the
          -- object receipt, which is the commonest real shape there is (one
          -- scanned row, one hand-entered row) and is fixture N4 exactly. The
          -- owner then resolves to the payload-less row, its gratuity reads 0,
          -- NOTHING is subtracted, and the object payload's gratuity is still
          -- ADDED by the generated column: N4 folds to non-wage 10200 instead
          -- of 8200, $20.00 of money that does not exist, on one shift. That is
          -- the identical failure mode the object-first ranking exists to fix,
          -- reintroduced by a NULL sort default. Pinned by
          -- N4_theNullsFirstRankingInventsTwentyDollars.
          row_number() over (partition by s.group_key order by
            (jsonb_typeof(s.receipt_metrics) = 'object') desc nulls last,
            (s.kind = 'credit') desc, s.id asc) as metrics_rank,
          row_number() over (partition by s.group_key order by
            (s.kind = 'credit') desc, s.id asc) as detail_rank
        from source s
      ),
      owned as (
        select r.*,
          case when r.metrics_rank = 1
               then private.receipt_gratuity_cents(r.receipt_metrics)
               else 0 end as owner_gratuity_cents,
          case when r.metrics_rank = 1
                    and jsonb_typeof(r.receipt_metrics -> 'earningsSchemaVersion') = 'number'
               then (r.receipt_metrics ->> 'earningsSchemaVersion')::numeric
               else 1 end as schema_version
        from ranked r
      ),
      grouped as (
        select
          o.group_key as id,
          min(o.work_date) as work_date,
          (array_agg(o.shift_period order by o.detail_rank)
             filter (where o.shift_period is not null))[1] as shift_period,
          least(greatest(0, sum(case when o.kind = 'cash'
            then case when o.schema_version >= 2 then o.amount_cents
                      else greatest(0, o.amount_cents - o.owner_gratuity_cents) end
            else 0 end)::bigint), 2147483647)::integer as cash_tips_cents,
          least(greatest(0, sum(case when o.kind = 'credit'
            then case when o.schema_version >= 2 then o.amount_cents
                      else greatest(0, o.amount_cents - o.owner_gratuity_cents) end
            else 0 end)::bigint), 2147483647)::integer as credit_tips_cents,
          (array_agg(o.tip_out_cents order by o.detail_rank)
             filter (where o.tip_out_cents is not null))[1] as tip_out_cents,
          (array_agg(o.sales_cents order by o.detail_rank)
             filter (where o.sales_cents is not null))[1] as sales_cents,
          (array_agg(o.hours_worked order by o.detail_rank)
             filter (where o.hours_worked is not null))[1] as hours_worked,
          (array_agg(o.clock_in order by o.detail_rank)
             filter (where o.clock_in is not null))[1] as clock_in,
          (array_agg(o.clock_out order by o.detail_rank)
             filter (where o.clock_out is not null))[1] as clock_out,
          (array_agg(o.server_count order by o.detail_rank)
             filter (where o.server_count is not null))[1] as server_count,
          -- The sanitizer. earningsSchemaVersion is relabelled to 2 because
          -- the subtraction above has just made the payload v2, and
          -- gratuityFeesCents is rewritten through the SAME helper the
          -- arithmetic used (create_missing = false: never invent the key).
          -- Both halves exist so the STORED payload decodes as
          -- ShiftReceiptMetrics on the device: that struct decodes
          -- earningsSchemaVersion and gratuityFeesCents as Int?, so a payload
          -- carrying "1", true, "42" or 1234.6 fails to decode AS A WHOLE,
          -- ShiftRecord.receiptPayloadIsUnreadable fires, and that shift is
          -- excluded from the sync push set and reported forever, because the
          -- server keeps re-folding the same value. jsonb_set on a
          -- non-object raises ("cannot set path in scalar"), which is why the
          -- CASE guard is not optional.
          (array_agg(
             case when jsonb_typeof(o.receipt_metrics) = 'object'
                  then jsonb_set(
                         jsonb_set(o.receipt_metrics,
                                   '{earningsSchemaVersion}', '2'::jsonb, true),
                         '{gratuityFeesCents}',
                         to_jsonb(private.receipt_gratuity_cents(o.receipt_metrics)),
                         false)
                  else null end
             order by o.metrics_rank)
             filter (where jsonb_typeof(o.receipt_metrics) = 'object'))[1] as receipt_metrics,
          (array_agg(o.note order by o.detail_rank)
             filter (where o.note is not null))[1] as note,
          (array_agg(o.recorded_at order by o.detail_rank)
             filter (where o.recorded_at is not null))[1] as recorded_at,
          array_agg(distinct o.id order by o.id) as legacy_entry_ids,
          max(o.client_updated_at) as source_max_updated_at
        from owned o
        group by o.group_key
      )
      select * from grouped
    ) g);

  -- -------------------------------------------------------------------------
  -- ARM 3: the un-delete arm, BEFORE arm 1 so the reopened shift is then
  -- filled by arm 1's CASE.
  --
  -- A legacy un-delete is a first-class live path on both writers:
  -- RemoteTipEntry(entry:userID:) hardcodes deletedAt = nil, and
  -- upsert_tip_entries lost its staleness guard in 20260904134500, so EVERY
  -- 1.0 push of a locally present row writes deleted_at = null over a server
  -- tombstone. Without this arm the source row comes back, its money is back
  -- in tip_entries, and the shift stays tombstoned forever: the new build
  -- shows nothing while the old build shows the night.
  --
  -- Only a tombstone the fold itself set ('converted') on a shift no human
  -- has touched is reopened. A user deletion is never cleared.
  -- -------------------------------------------------------------------------
  update public.shifts s
     set deleted_at = null, deleted_reason = null
   where s.user_id = p_user_id
     and s.id = any(v_keys)
     and s.deleted_reason = 'converted'
     and s.native_modified_at is null
     and exists (select 1 from jsonb_to_recordset(v_grouped) as g(id uuid)
                  where g.id = s.id);

  -- -------------------------------------------------------------------------
  -- ARM 1: the upsert of derived groups.
  --
  -- deleted_at is guarded PER COLUMN, provenance is written
  -- UNCONDITIONALLY, and the conflict predicate never filters on deleted_at.
  -- There is NO `where` clause on the DO UPDATE and there may never be one:
  -- measured on PG 17, `on conflict (user_id,id) do update ... where
  -- deleted_at is null` against a deleted target reports INSERT 0 0 and
  -- leaves the row untouched with no error, so the arriving legacy id is
  -- never added to any legacy_entry_ids and this statement -- which runs
  -- inside a shipped 1.0 build's transaction -- silently drops that build's
  -- write. A CASE per column keeps the partition TOTAL over a closed target.
  -- scripts/design-lint.sh fails the build on `on conflict` combined with
  -- `where` in any statement touching public.shifts.
  --
  -- deleted_at is never written here, so nothing resurrects. source is never
  -- rewritten, so a native shift stays 'device'.
  --
  -- unconverted_legacy_cents is abs(), not greatest(0, ...): it means "the
  -- magnitude of the latest disagreement", never "unconverted money".
  -- Measured on a closed shift at 6000, a DOWNWARD correction from an old
  -- build (6000 to 4000) gave greatest(0, 4000-6000) = 0 and Data health
  -- showed nothing at all, and downward is the common shape of a correction.
  -- It is never accumulated: a repeated re-push of the same row would
  -- inflate it without bound. The honest account-wide figure comes from
  -- public.shift_legacy_conflicts (arm 4).
  -- -------------------------------------------------------------------------
  insert into public.shifts (
    user_id, id, work_date, shift_period, cash_tips_cents, credit_tips_cents,
    tip_out_cents, sales_cents, hours_worked, clock_in, clock_out, server_count,
    receipt_metrics, note, recorded_at, source, legacy_entry_ids,
    legacy_source_max_updated_at, converted_at, client_updated_at)
  select p_user_id, g.id, g.work_date, g.shift_period,
         g.cash_tips_cents, g.credit_tips_cents, g.tip_out_cents, g.sales_cents,
         g.hours_worked, g.clock_in, g.clock_out, g.server_count,
         g.receipt_metrics, g.note, g.recorded_at, 'migration', g.legacy_entry_ids,
         g.source_max_updated_at, statement_timestamp(),
         least(g.source_max_updated_at, statement_timestamp())
  from jsonb_to_recordset(v_grouped) as g(
    id uuid, work_date date, shift_period text,
    cash_tips_cents integer, credit_tips_cents integer,
    tip_out_cents integer, sales_cents integer, hours_worked numeric,
    clock_in timestamptz, clock_out timestamptz, server_count integer,
    receipt_metrics jsonb, note text, recorded_at timestamptz,
    legacy_entry_ids uuid[], source_max_updated_at timestamptz)
  on conflict (user_id, id) do update set
    work_date = case when private.shift_is_open_to_fold(public.shifts.*)
                     then excluded.work_date else public.shifts.work_date end,
    shift_period = case when private.shift_is_open_to_fold(public.shifts.*)
                        then excluded.shift_period else public.shifts.shift_period end,
    cash_tips_cents = case when private.shift_is_open_to_fold(public.shifts.*)
                           then excluded.cash_tips_cents else public.shifts.cash_tips_cents end,
    credit_tips_cents = case when private.shift_is_open_to_fold(public.shifts.*)
                             then excluded.credit_tips_cents else public.shifts.credit_tips_cents end,
    tip_out_cents = case when private.shift_is_open_to_fold(public.shifts.*)
                         then excluded.tip_out_cents else public.shifts.tip_out_cents end,
    sales_cents = case when private.shift_is_open_to_fold(public.shifts.*)
                       then excluded.sales_cents else public.shifts.sales_cents end,
    hours_worked = case when private.shift_is_open_to_fold(public.shifts.*)
                        then excluded.hours_worked else public.shifts.hours_worked end,
    clock_in = case when private.shift_is_open_to_fold(public.shifts.*)
                    then excluded.clock_in else public.shifts.clock_in end,
    clock_out = case when private.shift_is_open_to_fold(public.shifts.*)
                     then excluded.clock_out else public.shifts.clock_out end,
    server_count = case when private.shift_is_open_to_fold(public.shifts.*)
                        then excluded.server_count else public.shifts.server_count end,
    receipt_metrics = case when private.shift_is_open_to_fold(public.shifts.*)
                           then excluded.receipt_metrics else public.shifts.receipt_metrics end,
    note = case when private.shift_is_open_to_fold(public.shifts.*)
                then excluded.note else public.shifts.note end,
    recorded_at = case when private.shift_is_open_to_fold(public.shifts.*)
                       then excluded.recorded_at else public.shifts.recorded_at end,
    client_updated_at = case when private.shift_is_open_to_fold(public.shifts.*)
                             then excluded.client_updated_at else public.shifts.client_updated_at end,
    converted_at = statement_timestamp(),
    legacy_entry_ids = excluded.legacy_entry_ids,
    legacy_source_max_updated_at = excluded.legacy_source_max_updated_at,
    unconverted_legacy_cents = case
      when private.shift_is_open_to_fold(public.shifts.*) then 0
      else least(2147483647::numeric, abs(
             private.legacy_non_wage_cents(
               excluded.cash_tips_cents, excluded.credit_tips_cents,
               excluded.receipt_metrics, excluded.tip_out_cents)::numeric
             - public.shifts.non_wage_earnings_cents::numeric))::integer end;

  get diagnostics v_rows = row_count;
  v_wrote := v_rows;

  -- -------------------------------------------------------------------------
  -- ARM 4a: the conflict record for a group whose money arm 1 declined
  -- because the shift is closed and the numbers actually disagree. Arm 1
  -- cannot have changed either side of this comparison on a closed shift, so
  -- reading it here still reads the pre-arrival value.
  -- -------------------------------------------------------------------------
  insert into public.shift_legacy_conflicts
    (user_id, shift_id, detected_at, shift_cents_before, legacy_cents_after)
  select p_user_id, g.id, statement_timestamp(), s.non_wage_earnings_cents,
         private.legacy_non_wage_cents(g.cash_tips_cents, g.credit_tips_cents,
                                       g.receipt_metrics, g.tip_out_cents)
  from jsonb_to_recordset(v_grouped) as g(
         id uuid, cash_tips_cents integer, credit_tips_cents integer,
         tip_out_cents integer, receipt_metrics jsonb)
  join public.shifts s on s.user_id = p_user_id and s.id = g.id
  where not private.shift_is_open_to_fold(s)
    and s.non_wage_earnings_cents <> private.legacy_non_wage_cents(
          g.cash_tips_cents, g.credit_tips_cents, g.receipt_metrics, g.tip_out_cents);

  get diagnostics v_rows = row_count;
  v_conflicts := v_conflicts + v_rows;

  -- -------------------------------------------------------------------------
  -- ARM 2: the emptied-group arm, in TWO statements, because provenance and
  -- money must be released independently.
  --
  -- A `group by` over an empty source emits nothing. Measured: soft-deleting
  -- one row of a two-row group re-derives correctly; soft-deleting the LAST
  -- live row leaves the shift at cash 5000 with a stale provenance id,
  -- PERMANENTLY -- the user deleted the money on their old phone and the new
  -- build keeps counting it. Under this shape the arm fires on ordinary 1.0
  -- deletions, continuously.
  --
  -- ARM 2b (money and tombstone) runs BEFORE 2a (provenance), so
  -- shift_is_open_to_fold is evaluated against the pre-release row.
  -- -------------------------------------------------------------------------
  update public.shifts s
     set cash_tips_cents = 0, credit_tips_cents = 0,
         tip_out_cents = null, sales_cents = null, hours_worked = null,
         clock_in = null, clock_out = null, server_count = null,
         receipt_metrics = null,
         deleted_at = coalesce(s.deleted_at, statement_timestamp()),
         deleted_reason = coalesce(s.deleted_reason, 'converted')
   where s.user_id = p_user_id
     and s.id = any(v_keys)
     and not exists (select 1 from jsonb_to_recordset(v_grouped) as g(id uuid)
                      where g.id = s.id)
     and private.shift_is_open_to_fold(s);

  -- -------------------------------------------------------------------------
  -- ARM 2a: release provenance. UNCONDITIONAL. Closed and deleted shifts
  -- included.
  --
  -- With the single gated statement an earlier draft wrote, a closed shift
  -- whose sources move away or get tombstoned keeps naming rows it no longer
  -- derives from, forever, and that one stranded claim causes all three of:
  -- the night displayed twice on two different dates (and 5.5's duplicate
  -- detector groups by work_date, so two different dates are never
  -- reported); the conservation duplicate count returning 1 forever; and
  -- payday_unmigrated_tip_row_count() never returning 0, which makes the
  -- client re-invoke the one-shot on every pass forever.
  --
  -- The watermark is computed PER KEY over every row of that key including
  -- tombstoned ones, which is what the column comment on
  -- legacy_source_max_updated_at says the column means. The design printed a
  -- single invocation-wide scalar here; per key is strictly narrower and
  -- cannot be worse, and a cross-key max would make the column lie. It is
  -- informational either way, because this statement empties
  -- legacy_entry_ids, so the 5.2 predicate arms that read the watermark
  -- cannot apply to this shift until it names a row again.
  -- -------------------------------------------------------------------------
  update public.shifts s
     set legacy_entry_ids = '{}',
         legacy_source_max_updated_at = (
           select max(e.client_updated_at) from public.tip_entries e
            where e.user_id = p_user_id
              and private.legacy_group_key(e.shift_id, e.work_date) = s.id),
         -- The folded value of an emptied group IS zero, so the magnitude of
         -- the latest disagreement is abs(0 - this shift's net). One
         -- expression covers all three cases: an OPEN shift arm 2b just
         -- released reads 0, a CLOSED shift that kept its money reads that
         -- money, and a user-deleted shift likewise. The design's printed arm
         -- 2a did not write this column at all, which left a CLOSED emptied
         -- shift displaying a STALE magnitude from some earlier arrival -- the
         -- one number Data health puts in front of the person in exactly this
         -- case. Never accumulated: this is an absolute assignment.
         unconverted_legacy_cents =
           least(2147483647::numeric, abs(s.non_wage_earnings_cents::numeric))::integer,
         converted_at = statement_timestamp()
   where s.user_id = p_user_id
     and s.id = any(v_keys)
     and not exists (select 1 from jsonb_to_recordset(v_grouped) as g(id uuid)
                      where g.id = s.id)
     and array_length(s.legacy_entry_ids, 1) > 0;

  -- -------------------------------------------------------------------------
  -- ARM 4b: the emptied-and-closed case, which has no grouped row. A CLOSED
  -- emptied shift keeps its money -- the user's own edit wins -- and the
  -- disagreement is recorded here rather than silently retained.
  -- -------------------------------------------------------------------------
  insert into public.shift_legacy_conflicts
    (user_id, shift_id, detected_at, shift_cents_before, legacy_cents_after)
  select p_user_id, s.id, statement_timestamp(), s.non_wage_earnings_cents, 0
  from public.shifts s
  where s.user_id = p_user_id
    and s.id = any(v_keys)
    and not exists (select 1 from jsonb_to_recordset(v_grouped) as g(id uuid)
                     where g.id = s.id)
    and not private.shift_is_open_to_fold(s)
    and s.non_wage_earnings_cents <> 0;

  get diagnostics v_rows = row_count;
  v_conflicts := v_conflicts + v_rows;

  -- -------------------------------------------------------------------------
  -- The conservation numbers. RECORDED, never raised, and scoped so that
  -- equality is a real invariant rather than an aspiration.
  --
  -- Account-wide conservation is permanently unsatisfiable once one native
  -- shift, one post-conversion edit or one deletion exists, and scoping by
  -- legacy provenance alone is still not enough, because provenance is
  -- written unconditionally onto a CLOSED shift whose money the fold
  -- deliberately declined. So CLOSED shifts are excluded from BOTH sides:
  -- the comparison is over exactly the population where equality must hold,
  -- shifts nobody has touched derived from rows nobody has moved.
  --
  -- The "in" side is per GROUP, not per row, because the tip-out is resolved
  -- once per group and summing it per row would double-subtract it.
  -- -------------------------------------------------------------------------
  select coalesce(sum(private.legacy_non_wage_cents(
           g.cash_tips_cents, g.credit_tips_cents, g.receipt_metrics, g.tip_out_cents))::bigint, 0)
    into source_cents
  from jsonb_to_recordset(v_grouped) as g(
         id uuid, cash_tips_cents integer, credit_tips_cents integer,
         tip_out_cents integer, receipt_metrics jsonb)
  where not exists (
    select 1 from public.shifts s
     where s.user_id = p_user_id and s.id = g.id
       and (not private.shift_is_open_to_fold(s)
            or s.client_updated_at > statement_timestamp()));

  select coalesce(sum(s.non_wage_earnings_cents)::bigint, 0)
    into shift_cents
  from public.shifts s
  where s.user_id = p_user_id
    and s.id = any(v_keys)
    and array_length(s.legacy_entry_ids, 1) > 0
    and s.deleted_at is null
    and s.native_modified_at is null
    and s.client_updated_at <= statement_timestamp();

  wrote_count := v_wrote;
  conflicts := v_conflicts;

  perform set_config('payday.folding', 'off', true);
  return next;
  return;

exception
  -- 57014 (statement_timeout) and assert_failure are NOT caught by OTHERS,
  -- and 57014 is the abort class most likely to hit a 500-row 1.0 batch, so
  -- both get named arms. Each clears the GUC and re-raises: the CALLER
  -- records the failure and queues the keys (S4), because only the caller
  -- knows whether it is the trigger, the one-shot, or a future writer.
  --
  -- Measured on PG 17.11: catching in the caller also rolls the subtransaction
  -- back, which reverts this set_config on its own, so the clear here is belt
  -- rather than braces. It ships anyway, because the day a handler above
  -- stops re-raising, a GUC left at 'on' would silently freeze `version` on
  -- every later shift UPDATE in that transaction, and that is invisible at
  -- the call site that breaks.
  when query_canceled then
    perform set_config('payday.folding', 'off', true);
    raise;
  when assert_failure then
    perform set_config('payday.folding', 'off', true);
    raise;
  when others then
    perform set_config('payday.folding', 'off', true);
    raise;
end;
$fn$;

comment on function private.derive_shifts(uuid, uuid[]) is
  'The single deriver. The on-arrival trigger and the one-shot both call it '
  'identically, so they cannot disagree about grouping, receipt arithmetic, '
  'tip-out, hours or conservation. No p_strict: conservation is returned and '
  'recorded by the caller, never raised. Takes no lock -- the caller does '
  '(pg_try_advisory_xact_lock on the fold path, blocking elsewhere, all on '
  'the same payday:shiftmig:<uid> key). Sets payday.folding for the duration '
  'and clears it before every return, including in the exception handler.';
