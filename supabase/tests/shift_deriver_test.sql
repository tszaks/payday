-- PR 2, slice S3: tests for private.derive_shifts, the single deriver.
--
-- Same convention as supabase/tests/shift_schema_test.sql (slice S2): a plain
-- psql script, every assertion lands in a temporary results table, and the
-- last statement raises if any row is false, which makes psql exit non-zero
-- under -v ON_ERROR_STOP=1. Not pgTAP: it is not installed in this project
-- and the gate is CI job E, which already has a live database in front of it.
--
-- CI (job E, "Supabase migrations (db reset)"), after `supabase db reset --local`:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/shift_deriver_test.sql
--
-- Locally with no Docker: `bash scripts/db-test-local.sh` (a throwaway
-- Homebrew postgresql@17 cluster in /tmp with the Supabase primitives).
--
-- The script is re-runnable: it deletes its four fixture accounts first, which
-- cascades every row it wrote last time.
--
-- ONE thing in this suite is checked on the OTHER side of the wall:
-- PaydayTests/ShiftDeriverStoredPayloadTests.swift decodes the same stored
-- receipt payload literals this file pins as ShiftReceiptMetrics. Neither
-- side re-derives; both carry the literals. If you change what the sanitizer
-- stores, BOTH files fail, which is the point.

\set ON_ERROR_STOP on
\timing off
\pset pager off

create temporary table results (
  seq serial primary key, name text not null, ok boolean not null, detail text not null default '');

-- Runs one statement and reports what it raised: '00000' when it succeeded,
-- otherwise 'SQLSTATE' or 'SQLSTATE/constraint_name'.
create function pg_temp.outcome_of(p_sql text) returns text language plpgsql as $$
declare v_constraint text;
begin
  execute p_sql;
  return '00000';
exception when others then
  get stacked diagnostics v_constraint = constraint_name;
  return sqlstate || coalesce('/' || nullif(v_constraint, ''), '');
end;
$$;

create function pg_temp.expect(p_name text, p_ok boolean, p_detail text default '')
returns void language sql as $$
  insert into results (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail);
$$;

-- Every fixture row is described by this one helper so a fixture reads as a
-- table of facts rather than a wall of INSERT syntax.
create function pg_temp.legacy_row(
  p_user uuid, p_id uuid, p_shift uuid, p_date date, p_amount integer, p_kind text,
  p_tip_out integer default null, p_hours numeric default null,
  p_receipt jsonb default null, p_cua timestamptz default '2026-01-01 00:00:00+00',
  p_sales integer default null, p_period text default null, p_note text default null)
returns void language sql as $$
  insert into public.tip_entries (
    id, user_id, shift_id, work_date, amount_cents, kind, tip_out_cents,
    hours_worked, receipt_metrics, client_updated_at, sales_cents, shift_period, note)
  values (p_id, p_user, p_shift, p_date, p_amount, p_kind, p_tip_out,
          p_hours, p_receipt, p_cua, p_sales, p_period, p_note);
$$;

-- The one shift row of a group, as a jsonb blob, so an assertion can name
-- several columns at once and report all of them when it fails.
create function pg_temp.shift_facts(p_user uuid, p_key uuid) returns jsonb
language sql as $$
  select coalesce(
    (select to_jsonb(x) from (
       select s.work_date, s.shift_period, s.cash_tips_cents, s.credit_tips_cents,
              s.tip_out_cents, s.sales_cents, s.hours_worked, s.server_count,
              s.gratuity_fees_cents, s.non_wage_earnings_cents, s.receipt_metrics,
              s.note, s.source, s.legacy_entry_ids, s.deleted_at is not null as is_deleted,
              s.deleted_reason, s.unconverted_legacy_cents, s.version, s.derived_version,
              s.native_modified_at is not null as is_closed
       from public.shifts s where s.user_id = p_user and s.id = p_key) x),
    'null'::jsonb);
$$;

-- Fixture accounts ------------------------------------------------------------

delete from auth.users where id in (
  '51000000-0000-4000-8000-000000000001',
  '51000000-0000-4000-8000-000000000002',
  '51000000-0000-4000-8000-000000000003',
  '51000000-0000-4000-8000-000000000004');
insert into auth.users (id, email) values
  ('51000000-0000-4000-8000-000000000001', 'payday-s3-fixtures@test.invalid'),
  ('51000000-0000-4000-8000-000000000002', 'payday-s3-junk@test.invalid'),
  ('51000000-0000-4000-8000-000000000003', 'payday-s3-arms@test.invalid'),
  ('51000000-0000-4000-8000-000000000004', 'payday-s3-repeat@test.invalid');

-- =============================================================================
-- 1. The named fixtures: N1, N4, N5, L1, L2, N3, P6
-- =============================================================================

-- N1: cash 6000 + credit 4000 sharing a shift_id, with tip_out 1000 duplicated
-- onto BOTH rows. ShiftDetails.resolve reads credit ?? cash and NEVER sums, so
-- the shift's tip-out is 1000 and non-wage is 9000, not 8000.
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000102',
  '00000000-0000-0000-0000-000000000101', '2026-09-29', 6000, 'cash',
  p_tip_out => 1000, p_cua => '2026-09-29 21:30:00+00');
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000103',
  '00000000-0000-0000-0000-000000000101', '2026-09-29', 4000, 'credit',
  p_tip_out => 1000, p_cua => '2026-09-29 21:35:00+00');

-- N4: cash 5000, credit 2000, a v1 receipt (no earningsSchemaVersion key, which
-- is live production data) carrying gratuity 4200 on the CREDIT row, tip-out
-- 1000. This ports the READ path: resolve the owner, then max(0, amount -
-- gratuity) on THAT ROW ONLY. The credit row is deliberately SHORT of the
-- folded gratuity, so the edit-path rule would give a different split.
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000401', '2026-07-01', 5000, 'cash',
  p_cua => '2026-07-02 01:00:00+00');
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000403',
  '00000000-0000-0000-0000-000000000401', '2026-07-01', 2000, 'credit',
  p_tip_out => 1000, p_receipt => '{"gratuityFeesCents": 4200}'::jsonb,
  p_cua => '2026-07-02 01:05:00+00');

-- N5: the object-first ranking. The CREDIT row carries a NON-OBJECT payload
-- ("hi") and the CASH row carries a v1 object payload with gratuity 4200.
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000502',
  '00000000-0000-0000-0000-000000000501', '2026-07-02', 5000, 'cash',
  p_receipt => '{"gratuityFeesCents": 4200}'::jsonb, p_cua => '2026-07-03 01:00:00+00');
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000503',
  '00000000-0000-0000-0000-000000000501', '2026-07-02', 2000, 'credit',
  p_receipt => '"hi"'::jsonb, p_cua => '2026-07-03 01:05:00+00');

-- L1: two rows sharing a shift_id with DIFFERENT work dates. min(work_date),
-- never max: the agent API's groupShifts reduced to the largest (correction D1).
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000602',
  '00000000-0000-0000-0000-000000000601', '2026-07-04', 1000, 'cash',
  p_cua => '2026-07-05 01:00:00+00');
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000603',
  '00000000-0000-0000-0000-000000000601', '2026-07-05', 2000, 'credit',
  p_cua => '2026-07-06 01:00:00+00');

-- L2: the metrics owner. BOTH rows carry object payloads, so object-ness ties
-- and credit wins. guestCount tags which payload was stored.
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000702',
  '00000000-0000-0000-0000-000000000701', '2026-07-06', 5000, 'cash',
  p_receipt => '{"guestCount": 7, "gratuityFeesCents": 1000}'::jsonb,
  p_cua => '2026-07-07 01:00:00+00');
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000703',
  '00000000-0000-0000-0000-000000000701', '2026-07-06', 3000, 'credit',
  p_receipt => '{"guestCount": 42, "gratuityFeesCents": 4200}'::jsonb,
  p_cua => '2026-07-07 01:05:00+00');

-- N3: nil shift_id on both rows, so the group key is
-- payday_legacy_shift_id(work_date). tip_out, hours and sales are NULL on both
-- rows: "never entered" and "tipped out nothing" are different facts.
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000031',
  null, '2026-09-28', 3000, 'cash', p_cua => '2026-09-28 19:10:00+00');
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000032',
  null, '2026-09-28', 5000, 'credit', p_cua => '2026-09-29 03:40:00+00');

-- P6: hours resolved by rank, credit first, NEVER summed and never
-- cash-first. 5.0 hours is what PaydayCore turns into 1415c of wages at the
-- confirmed 283c rate (job A); the deriver computes no wages at all, so the
-- hours input is what this side pins.
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000802',
  '00000000-0000-0000-0000-000000000801', '2026-07-08', 1000, 'cash',
  p_hours => 7.5, p_cua => '2026-07-09 01:00:00+00');
select pg_temp.legacy_row(
  '51000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000803',
  '00000000-0000-0000-0000-000000000801', '2026-07-08', 2000, 'credit',
  p_hours => 5.0, p_sales => 120000, p_period => 'dinner',
  p_note => 'Saturday double', p_cua => '2026-07-09 01:05:00+00');

-- One derive over every fixture key at once, which is also how the trigger
-- calls it: the touched set is a set, not one group.
do $$
declare v_out record;
begin
  select * into v_out from private.derive_shifts(
    '51000000-0000-4000-8000-000000000001',
    array['00000000-0000-0000-0000-000000000101'::uuid,
          '00000000-0000-0000-0000-000000000401'::uuid,
          '00000000-0000-0000-0000-000000000501'::uuid,
          '00000000-0000-0000-0000-000000000601'::uuid,
          '00000000-0000-0000-0000-000000000701'::uuid,
          '00000000-0000-0000-0000-000000000801'::uuid,
          public.payday_legacy_shift_id('2026-09-28')]);
  perform pg_temp.expect('theFixtureDeriveWroteSevenGroupsAndRaisedNothing',
    v_out.touched_count = 7 and v_out.wrote_count = 7 and v_out.conflicts = 0,
    'touched=' || v_out.touched_count || ' wrote=' || v_out.wrote_count
      || ' conflicts=' || v_out.conflicts
      || ' in=' || v_out.source_cents || ' out=' || v_out.shift_cents);
  perform pg_temp.expect('aPristineDeriveConservesEveryCent',
    v_out.source_cents = v_out.shift_cents and v_out.source_cents = 9000 + 8200 + 7000 + 3000 + 9200 + 8000 + 3000,
    'in=' || v_out.source_cents || ' out=' || v_out.shift_cents);
end;
$$;

-- N1 ---------------------------------------------------------------------------
select pg_temp.expect('N1_aDuplicatedTipOutSubtractsOnce',
  (f ->> 'cash_tips_cents')::integer = 6000
  and (f ->> 'credit_tips_cents')::integer = 4000
  and (f ->> 'tip_out_cents')::integer = 1000
  and (f ->> 'gratuity_fees_cents')::integer = 0
  and (f ->> 'non_wage_earnings_cents')::integer = 9000,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000101') as f;

-- The two wrong answers N1 exists to exclude, each asserted as a number the
-- shift does NOT hold: per-row subtraction gives non-wage 8000, and summing
-- the tip-out across rows gives tip_out 2000 (and non-wage 8000 as well,
-- which is why the tip-out COMPONENT has to be asserted, not only the total).
select pg_temp.expect('N1_theTwoWrongTipOutAnswersAreBothExcluded',
  (f ->> 'non_wage_earnings_cents')::integer <> 8000
  and (f ->> 'tip_out_cents')::integer <> 2000
  and (f ->> 'tip_out_cents')::integer <> 0,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000101') as f;

select pg_temp.expect('N1_provenanceNamesBothLegacyRowsSortedAndDeduplicated',
  (select legacy_entry_ids from public.shifts
    where user_id = '51000000-0000-4000-8000-000000000001'
      and id = '00000000-0000-0000-0000-000000000101')
  = array['00000000-0000-0000-0000-000000000102'::uuid,
          '00000000-0000-0000-0000-000000000103'::uuid],
  (select legacy_entry_ids::text from public.shifts
    where user_id = '51000000-0000-4000-8000-000000000001'
      and id = '00000000-0000-0000-0000-000000000101'));

-- N4 ---------------------------------------------------------------------------
select pg_temp.expect('N4_theReadPathSplitIsFiveThousandZeroFortyTwoHundred',
  (f ->> 'cash_tips_cents')::integer = 5000
  and (f ->> 'credit_tips_cents')::integer = 0
  and (f ->> 'gratuity_fees_cents')::integer = 4200
  and (f ->> 'non_wage_earnings_cents')::integer = 8200,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000401') as f;

-- The edit path (LogTipSheet.gratuityFeesBinding) moves the WHOLE folded
-- gratuity to the other kind and would give cash 800 / credit 2000 /
-- non-wage 6000: $22.00 on one shift AND a different cash-versus-credit
-- split, which is what drives the paycheck comparison.
select pg_temp.expect('N4_theEditPathSplitIsExcluded',
  not ((f ->> 'cash_tips_cents')::integer = 800 and (f ->> 'credit_tips_cents')::integer = 2000)
  and (f ->> 'non_wage_earnings_cents')::integer <> 6000,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000401') as f;

-- N5 ---------------------------------------------------------------------------
select pg_temp.expect('N5_objectFirstRankingGives800_2000_4200_7000',
  (f ->> 'cash_tips_cents')::integer = 800
  and (f ->> 'credit_tips_cents')::integer = 2000
  and (f ->> 'gratuity_fees_cents')::integer = 4200
  and (f ->> 'non_wage_earnings_cents')::integer = 7000,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000501') as f;

select pg_temp.expect('N5_theStoredPayloadIsTheObjectOneAndItIsRelabelledV2',
  f -> 'receipt_metrics' = '{"gratuityFeesCents": 4200, "earningsSchemaVersion": 2}'::jsonb,
  (f -> 'receipt_metrics')::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000501') as f;

-- Two wrong rankings, each run over the SAME rows, to prove the number it
-- produces. `p_ranking = 'is_not_null'` is the ranking the design's first
-- draft carried: a non-object payload is not null, so it wins rank 1, nothing
-- is subtracted anywhere, and the object payload's gratuity is then ADDED by
-- the generated column without ever being SUBTRACTED. `p_ranking =
-- 'nulls_first'` is the object-first ranking spelled WITHOUT `nulls last`,
-- which is the same bug reached through a sort default, because
-- jsonb_typeof(NULL) is NULL and `desc` means NULLS FIRST.
--
-- Both are also parity breaks, not just arithmetic: Swift gives the correct
-- number for the same input, because an undecodable or absent payload is nil
-- on device and TipBreakdown then picks the row that does hold one.
create function pg_temp.derive_with_wrong_ranking(p_user uuid, p_key uuid, p_ranking text)
returns jsonb language sql as $$
  with source as (
    select e.*, private.legacy_group_key(e.shift_id, e.work_date) as group_key
    from public.tip_entries e
    where e.user_id = p_user
      and private.legacy_group_key(e.shift_id, e.work_date) = p_key
      and e.deleted_at is null
  ),
  ranked as (
    select s.*,
      row_number() over (partition by s.group_key order by
        -- THE BUG, on purpose, in both of its spellings.
        case when p_ranking = 'is_not_null'
             then (s.receipt_metrics is not null) end desc,
        case when p_ranking = 'nulls_first'
             then (jsonb_typeof(s.receipt_metrics) = 'object') end desc,
        (s.kind = 'credit') desc, s.id asc) as metrics_rank
    from source s
  ),
  owned as (
    select r.*,
      case when r.metrics_rank = 1 then private.receipt_gratuity_cents(r.receipt_metrics)
           else 0 end as owner_gratuity_cents,
      case when r.metrics_rank = 1
                and jsonb_typeof(r.receipt_metrics -> 'earningsSchemaVersion') = 'number'
           then (r.receipt_metrics ->> 'earningsSchemaVersion')::numeric
           else 1 end as schema_version
    from ranked r
  ),
  grouped as (
    select
      sum(case when o.kind = 'cash' then case when o.schema_version >= 2 then o.amount_cents
               else greatest(0, o.amount_cents - o.owner_gratuity_cents) end else 0 end)::integer as cash,
      sum(case when o.kind = 'credit' then case when o.schema_version >= 2 then o.amount_cents
               else greatest(0, o.amount_cents - o.owner_gratuity_cents) end else 0 end)::integer as credit,
      (array_agg(o.receipt_metrics order by o.metrics_rank)
         filter (where jsonb_typeof(o.receipt_metrics) = 'object'))[1] as receipt,
      -- Resolved exactly as the shipped deriver resolves it (credit first,
      -- once per group), so the ONLY difference between this replica and
      -- private.derive_shifts is the ranking under test.
      (array_agg(o.tip_out_cents order by (o.kind = 'credit') desc, o.id)
         filter (where o.tip_out_cents is not null))[1] as tip_out
    from owned o
  )
  select jsonb_build_object(
           'cash', g.cash, 'credit', g.credit,
           'gratuity', private.receipt_gratuity_cents(g.receipt),
           'tipOut', g.tip_out,
           'nonWage', private.legacy_non_wage_cents(g.cash, g.credit, g.receipt, g.tip_out))
  from grouped g;
$$;

select pg_temp.expect('N5_theIsNotNullRankingInventsFortyTwoDollars',
  (w ->> 'nonWage')::integer = 11200 and (w ->> 'cash')::integer = 5000,
  'wrong=' || w::text)
from pg_temp.derive_with_wrong_ranking(
  '51000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000501', 'is_not_null') as w;

-- The same class of bug reached through a SORT DEFAULT rather than a wrong
-- predicate, on N4, which is the commonest real group shape: one row with a
-- scanned receipt, one row with none. jsonb_typeof(NULL) is NULL, `desc` is
-- NULLS FIRST, so the payload-less row owns the metrics, nothing is
-- subtracted, and the gratuity is added anyway: 10200 where the answer is
-- 8200. MEASURED against the design's printed expression, which omitted
-- `nulls last`.
select pg_temp.expect('N4_theNullsFirstRankingInventsTwentyDollars',
  (w ->> 'nonWage')::integer = 10200 and (w ->> 'credit')::integer = 2000,
  'wrong=' || w::text)
from pg_temp.derive_with_wrong_ranking(
  '51000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000401', 'nulls_first') as w;

-- The same replica, with the owner resolved correctly, reproduces the shipped
-- function's 8200. So the replica is not rigged: ranking is the only variable.
select pg_temp.expect('N4_theSameReplicaWithTheCorrectOwnerGives8200',
  (w ->> 'nonWage')::integer = 8200 and (w ->> 'credit')::integer = 0
  and (w ->> 'tipOut')::integer = 1000,
  'right=' || w::text)
from pg_temp.derive_with_wrong_ranking(
  '51000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000401', 'is_not_null') as w;

-- L1 ---------------------------------------------------------------------------
select pg_temp.expect('L1_theGroupTakesTheMinimumWorkDate',
  (f ->> 'work_date')::date = '2026-07-04'
  and (f ->> 'work_date')::date <> '2026-07-05'
  and (f ->> 'non_wage_earnings_cents')::integer = 3000,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000601') as f;

select pg_temp.expect('L1_oneShiftIdSpanningTwoDatesIsStillOneShift',
  (select count(*) from public.shifts
    where user_id = '51000000-0000-4000-8000-000000000001'
      and id = '00000000-0000-0000-0000-000000000601') = 1
  and (select count(*) from public.shifts
        where user_id = '51000000-0000-4000-8000-000000000001'
          and work_date = '2026-07-05') = 0);

-- L2 ---------------------------------------------------------------------------
select pg_temp.expect('L2_theCreditRowOwnsTheMetricsWhenBothPayloadsAreObjects',
  (f ->> 'cash_tips_cents')::integer = 5000
  and (f ->> 'credit_tips_cents')::integer = 0
  and (f ->> 'gratuity_fees_cents')::integer = 4200
  and (f ->> 'non_wage_earnings_cents')::integer = 9200
  and (f -> 'receipt_metrics' ->> 'guestCount')::integer = 42,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000701') as f;

-- Three wrong owners, each a real number: cash-first gives 4000/3000/1000,
-- per-row subtraction sums the gratuity to 5200, and storing one payload while
-- subtracting the other's gratuity is the N5 class of bug.
select pg_temp.expect('L2_theThreeWrongOwnerAnswersAreExcluded',
  (f ->> 'gratuity_fees_cents')::integer <> 1000
  and (f ->> 'gratuity_fees_cents')::integer <> 5200
  and (f ->> 'cash_tips_cents')::integer <> 4000
  and (f -> 'receipt_metrics' ->> 'guestCount')::integer <> 7,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000701') as f;

-- N3 ---------------------------------------------------------------------------
select pg_temp.expect('N3_nullIsNotZeroForTipOutHoursAndSales',
  (f ->> 'cash_tips_cents')::integer = 3000
  and (f ->> 'credit_tips_cents')::integer = 5000
  and f -> 'tip_out_cents' = 'null'::jsonb
  and f -> 'hours_worked' = 'null'::jsonb
  and f -> 'sales_cents' = 'null'::jsonb
  and (f ->> 'non_wage_earnings_cents')::integer = 8000,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         public.payday_legacy_shift_id('2026-09-28')) as f;

select pg_temp.expect('N3_theNilShiftIdGroupIsKeyedByTheDerivedIdentity',
  (select count(*) from public.shifts
    where user_id = '51000000-0000-4000-8000-000000000001'
      and id = public.payday_legacy_shift_id('2026-09-28')) = 1
  and public.payday_legacy_shift_id('2026-09-28')
      = private.legacy_group_key(null, '2026-09-28'),
  public.payday_legacy_shift_id('2026-09-28')::text);

-- P6 ---------------------------------------------------------------------------
select pg_temp.expect('P6_hoursAreResolvedCreditFirstAndNeverSummed',
  (f ->> 'hours_worked')::numeric = 5.0
  and (f ->> 'hours_worked')::numeric <> 7.5
  and (f ->> 'hours_worked')::numeric <> 12.5
  and (f ->> 'sales_cents')::integer = 120000
  and f ->> 'shift_period' = 'dinner'
  and f ->> 'note' = 'Saturday double'
  and (f ->> 'non_wage_earnings_cents')::integer = 3000,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000001',
                         '00000000-0000-0000-0000-000000000801') as f;

-- Every fixture row is one shift and every shift is source 'migration'.
select pg_temp.expect('theSevenFixtureGroupsAreSevenShiftsAllMarkedMigration',
  (select count(*) from public.shifts
    where user_id = '51000000-0000-4000-8000-000000000001') = 7
  and (select count(*) from public.shifts
        where user_id = '51000000-0000-4000-8000-000000000001'
          and source = 'migration') = 7,
  (select count(*)::text from public.shifts
    where user_id = '51000000-0000-4000-8000-000000000001'));

-- =============================================================================
-- 2. Every junk-payload row of the design's section 3.4
-- =============================================================================

select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000001', null, '2026-01-01', 5000, 'cash',
  p_receipt => null);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000002', null, '2026-01-02', 5000, 'cash',
  p_receipt => '[1, 2]'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000003', null, '2026-01-03', 5000, 'cash',
  p_receipt => '"hi"'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000004', null, '2026-01-04', 5000, 'cash',
  p_receipt => '4'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000005', null, '2026-01-05', 5000, 'cash',
  p_receipt => '{"gratuityFeesCents": 4200}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000006', null, '2026-01-06', 5000, 'cash',
  p_receipt => '{"earningsSchemaVersion": true, "gratuityFeesCents": 1000}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000007', null, '2026-01-07', 5000, 'cash',
  p_receipt => '{"earningsSchemaVersion": "v2", "gratuityFeesCents": 1000}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000008', null, '2026-01-08', 5000, 'cash',
  p_receipt => '{"gratuityFeesCents": true}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000009', null, '2026-01-09', 5000, 'cash',
  p_receipt => '{"gratuityFeesCents": "42"}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000010', null, '2026-01-10', 5000, 'cash',
  p_receipt => '{"gratuityFeesCents": 1234.6}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000011', null, '2026-01-11', 5000, 'cash',
  p_receipt => '{"gratuityFeesCents": 1234.4}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000012', null, '2026-01-12', 5000, 'cash',
  p_receipt => '{"gratuityFeesCents": 99999999999}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000013', null, '2026-01-13', 5000, 'cash',
  p_receipt => '{"gratuityFeesCents": 1e30}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000014', null, '2026-01-14', 5000, 'cash',
  p_receipt => '{"gratuityFeesCents": -500}'::jsonb);
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000015', null, '2026-01-15', 5000, 'cash',
  p_receipt => '{"earningsSchemaVersion": 2, "gratuityFeesCents": 4200}'::jsonb);
-- An in-range sum that still overflows int4: cash 2147483000 + gratuity
-- 2000000, both legal on their own.
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000016', null, '2026-01-16', 2147483000, 'cash',
  p_receipt => '{"earningsSchemaVersion": 2, "gratuityFeesCents": 2000000}'::jsonb);
-- A JSON null payload, which is not SQL NULL and is storable in
-- tip_entries today: jsonb_typeof gives 'null', so it is excluded like any
-- other non-object and jsonb_set is never called on it.
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000017', null, '2026-01-17', 5000, 'cash',
  p_receipt => 'null'::jsonb);
-- TWO cash rows whose SUM overflows int4 even though each amount_cents is
-- legal. The group sums widen to bigint and then clamp, because an overflow
-- here is a statement abort, which under this shape is a rejected write from a
-- shipped 1.0 build.
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000018', null, '2026-01-18', 2000000000, 'cash');
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000002',
  'b0000000-0000-4000-8000-000000000019', null, '2026-01-18', 2000000000, 'cash');

do $$
declare v_state text; v_out record;
begin
  begin
    select * into v_out from private.derive_shifts(
      '51000000-0000-4000-8000-000000000002',
      array(select public.payday_legacy_shift_id(d::date)
            from generate_series('2026-01-01'::date, '2026-01-18'::date, '1 day') as d));
    v_state := '00000';
  exception when others then
    v_state := sqlstate || ' ' || sqlerrm;
  end;
  perform pg_temp.expect('everyJunkPayloadFoldsWithNoAbortAtAll',
    v_state = '00000' and v_out.wrote_count = 18, v_state || ' wrote=' || coalesce(v_out.wrote_count::text, 'null'));
end;
$$;

-- One assertion per 3.4 row, each naming the payload it was given.
select pg_temp.expect(
  'junk_' || to_char(work_date, 'MMDD'),
  case to_char(work_date, 'MMDD')
    -- null payload: no gratuity, no subtraction, stored payload null
    when '0101' then cash_tips_cents = 5000 and gratuity_fees_cents = 0
                     and receipt_metrics is null and non_wage_earnings_cents = 5000
    -- non-object payloads are excluded by jsonb_typeof, so the group's
    -- payload is NULL and jsonb_set is never called on a scalar
    when '0102' then cash_tips_cents = 5000 and gratuity_fees_cents = 0 and receipt_metrics is null
    when '0103' then cash_tips_cents = 5000 and gratuity_fees_cents = 0 and receipt_metrics is null
    when '0104' then cash_tips_cents = 5000 and gratuity_fees_cents = 0 and receipt_metrics is null
    -- object with the version key ABSENT is live production data: treat as v1,
    -- subtract the owner's gratuity, then relabel to 2
    when '0105' then cash_tips_cents = 800 and gratuity_fees_cents = 4200
                     and non_wage_earnings_cents = 5000
                     and receipt_metrics = '{"gratuityFeesCents": 4200, "earningsSchemaVersion": 2}'::jsonb
    -- version non-numeric resolves to 1 through the jsonb_typeof guard
    when '0106' then cash_tips_cents = 4000 and gratuity_fees_cents = 1000
                     and receipt_metrics = '{"gratuityFeesCents": 1000, "earningsSchemaVersion": 2}'::jsonb
    when '0107' then cash_tips_cents = 4000 and gratuity_fees_cents = 1000
                     and receipt_metrics = '{"gratuityFeesCents": 1000, "earningsSchemaVersion": 2}'::jsonb
    -- non-numeric gratuity contributes 0 and nothing is subtracted; the
    -- sanitizer rewrites the key to that same 0 so the stored payload still
    -- decodes as ShiftReceiptMetrics on the device (Int?, so `true` and "42"
    -- fail the WHOLE payload)
    when '0108' then cash_tips_cents = 5000 and gratuity_fees_cents = 0
                     and receipt_metrics = '{"gratuityFeesCents": 0, "earningsSchemaVersion": 2}'::jsonb
    when '0109' then cash_tips_cents = 5000 and gratuity_fees_cents = 0
                     and receipt_metrics = '{"gratuityFeesCents": 0, "earningsSchemaVersion": 2}'::jsonb
    -- fractional gratuity ROUNDS HALF AWAY FROM ZERO
    when '0110' then cash_tips_cents = 3765 and gratuity_fees_cents = 1235
                     and non_wage_earnings_cents = 5000
                     and receipt_metrics = '{"gratuityFeesCents": 1235, "earningsSchemaVersion": 2}'::jsonb
    when '0111' then cash_tips_cents = 3766 and gratuity_fees_cents = 1234
                     and receipt_metrics = '{"gratuityFeesCents": 1234, "earningsSchemaVersion": 2}'::jsonb
    -- out of int4 range, clamped in NUMERIC space in one place
    when '0112' then cash_tips_cents = 0 and gratuity_fees_cents = 2147483647
                     and non_wage_earnings_cents = 2147483647
                     and receipt_metrics = '{"gratuityFeesCents": 2147483647, "earningsSchemaVersion": 2}'::jsonb
    when '0113' then cash_tips_cents = 0 and gratuity_fees_cents = 2147483647
                     and non_wage_earnings_cents = 2147483647
    when '0114' then cash_tips_cents = 5000 and gratuity_fees_cents = 0
                     and receipt_metrics = '{"gratuityFeesCents": 0, "earningsSchemaVersion": 2}'::jsonb
    -- already v2: NO subtraction, the gratuity is additive
    when '0115' then cash_tips_cents = 5000 and gratuity_fees_cents = 4200
                     and non_wage_earnings_cents = 9200
    -- an in-range sum that overflows int4 clamps instead of aborting
    when '0116' then cash_tips_cents = 2147483000 and gratuity_fees_cents = 2000000
                     and non_wage_earnings_cents = 2147483647
    -- a JSON null payload is not SQL NULL and is not an object either
    when '0117' then cash_tips_cents = 5000 and gratuity_fees_cents = 0
                     and receipt_metrics is null and non_wage_earnings_cents = 5000
    -- two legal amounts whose sum does not fit int4: clamped, not aborted
    when '0118' then cash_tips_cents = 2147483647 and gratuity_fees_cents = 0
                     and non_wage_earnings_cents = 2147483647
    else false end,
  'cash=' || cash_tips_cents || ' gratuity=' || gratuity_fees_cents
    || ' nonwage=' || non_wage_earnings_cents
    || ' stored=' || coalesce(receipt_metrics::text, 'null'))
from public.shifts
where user_id = '51000000-0000-4000-8000-000000000002'
order by work_date;

-- The complete set of distinct stored payloads this suite produces, pinned.
-- PaydayTests/ShiftDeriverStoredPayloadTests.swift decodes exactly these as
-- ShiftReceiptMetrics. A new junk case cannot be added on one side only.
select pg_temp.expect('theStoredPayloadSetIsExactlyWhatTheSwiftDecoderTestCarries',
  (select array_agg(distinct receipt_metrics::text order by receipt_metrics::text)
     from public.shifts
    where user_id in ('51000000-0000-4000-8000-000000000001',
                      '51000000-0000-4000-8000-000000000002')
      and receipt_metrics is not null)
  -- Sorted by TEXT, so 2147483647 precedes 4200. Eight distinct payloads.
  = array[
    '{"gratuityFeesCents": 0, "earningsSchemaVersion": 2}',
    '{"gratuityFeesCents": 1000, "earningsSchemaVersion": 2}',
    '{"gratuityFeesCents": 1234, "earningsSchemaVersion": 2}',
    '{"gratuityFeesCents": 1235, "earningsSchemaVersion": 2}',
    '{"gratuityFeesCents": 2000000, "earningsSchemaVersion": 2}',
    '{"gratuityFeesCents": 2147483647, "earningsSchemaVersion": 2}',
    '{"gratuityFeesCents": 4200, "earningsSchemaVersion": 2}',
    '{"guestCount": 42, "gratuityFeesCents": 4200, "earningsSchemaVersion": 2}'],
  (select array_agg(distinct receipt_metrics::text order by receipt_metrics::text)::text
     from public.shifts
    where user_id in ('51000000-0000-4000-8000-000000000001',
                      '51000000-0000-4000-8000-000000000002')
      and receipt_metrics is not null));

-- Every stored payload satisfies both receipt CHECKs by construction, which is
-- the whole point of the sanitizer: the CHECK is the belt, this is the braces.
select pg_temp.expect('everyStoredPayloadIsAnObjectLabelledAtLeastV2',
  (select count(*) from public.shifts
    where receipt_metrics is not null
      and (jsonb_typeof(receipt_metrics) <> 'object'
        or jsonb_typeof(receipt_metrics -> 'earningsSchemaVersion') <> 'number'
        or (receipt_metrics ->> 'earningsSchemaVersion')::numeric < 2)) = 0);

-- The net rule has two spellings -- the stored generated column and
-- private.legacy_non_wage_cents -- and they must agree on every row.
select pg_temp.expect('theGeneratedColumnAndTheDeriversNetRuleAgreeOnEveryRow',
  (select count(*) from public.shifts s
    where s.non_wage_earnings_cents <> private.legacy_non_wage_cents(
      s.cash_tips_cents, s.credit_tips_cents, s.receipt_metrics, s.tip_out_cents)) = 0,
  (select coalesce(string_agg(s.id::text, ','), 'none') from public.shifts s
    where s.non_wage_earnings_cents <> private.legacy_non_wage_cents(
      s.cash_tips_cents, s.credit_tips_cents, s.receipt_metrics, s.tip_out_cents)));

-- =============================================================================
-- 3. The four write arms
-- =============================================================================

-- Arm 1's CASE partition, arm 4's conflict record, and unconverted_legacy_cents
-- in BOTH directions, on a shift the user has edited on the new build.
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000003',
  'c0000000-0000-4000-8000-000000000001',
  'c1000000-0000-4000-8000-000000000001', '2026-03-05', 5000, 'cash');
select private.derive_shifts('51000000-0000-4000-8000-000000000003',
  array['c1000000-0000-4000-8000-000000000001'::uuid]);

-- The user corrects the night on the new build. private.write_shifts lands in
-- S6; this is the write it will make: money changed, native_modified_at
-- stamped, so the shift is CLOSED to the fold from here on.
update public.shifts set cash_tips_cents = 6000, native_modified_at = now(),
                         client_updated_at = now()
 where user_id = '51000000-0000-4000-8000-000000000003'
   and id = 'c1000000-0000-4000-8000-000000000001';

-- An old phone pushes one unsynced $20 cash tip for the same night.
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000003',
  'c0000000-0000-4000-8000-000000000002',
  'c1000000-0000-4000-8000-000000000001', '2026-03-05', 2000, 'cash',
  p_cua => '2026-03-06 02:00:00+00');

do $$
declare v_out record;
begin
  select * into v_out from private.derive_shifts(
    '51000000-0000-4000-8000-000000000003',
    array['c1000000-0000-4000-8000-000000000001'::uuid]);
  perform pg_temp.expect('aClosedShiftReportsOneConflictAndConservesNothing',
    v_out.conflicts = 1 and v_out.source_cents = 0 and v_out.shift_cents = 0,
    'conflicts=' || v_out.conflicts || ' in=' || v_out.source_cents
      || ' out=' || v_out.shift_cents);
end;
$$;

select pg_temp.expect('aClosedShiftKeepsItsMoneyAndStillTakesTheProvenance',
  (f ->> 'cash_tips_cents')::integer = 6000
  and (f ->> 'non_wage_earnings_cents')::integer = 6000
  and (f ->> 'unconverted_legacy_cents')::integer = 1000
  and f -> 'legacy_entry_ids' = '["c0000000-0000-4000-8000-000000000001", "c0000000-0000-4000-8000-000000000002"]'::jsonb,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000003',
                         'c1000000-0000-4000-8000-000000000001') as f;

select pg_temp.expect('theConflictRowCarriesBothNumbersAndBothDirections',
  (select shift_cents_before = 6000 and legacy_cents_after = 7000
     from public.shift_legacy_conflicts
    where user_id = '51000000-0000-4000-8000-000000000003'
    order by id limit 1),
  (select string_agg(shift_cents_before || '->' || legacy_cents_after, ' ' order by id)
     from public.shift_legacy_conflicts
    where user_id = '51000000-0000-4000-8000-000000000003'));

-- A DOWNWARD correction from an old build. greatest(0, ...) would report 0
-- here and Data health would show nothing at all, and downward is the common
-- shape of a correction, so unconverted_legacy_cents is abs().
update public.tip_entries set amount_cents = 1000, client_updated_at = now()
 where id = 'c0000000-0000-4000-8000-000000000001';
select private.derive_shifts('51000000-0000-4000-8000-000000000003',
  array['c1000000-0000-4000-8000-000000000001'::uuid]);

select pg_temp.expect('aDownwardLegacyCorrectionOnAClosedShiftIsStillSurfaced',
  (f ->> 'cash_tips_cents')::integer = 6000
  and (f ->> 'unconverted_legacy_cents')::integer = 3000,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000003',
                         'c1000000-0000-4000-8000-000000000001') as f;

-- A later arrival that happens to EQUAL the shift zeroes the per-shift
-- magnitude, which is exactly why shift_legacy_conflicts is append-only and
-- is the honest surface.
update public.tip_entries set amount_cents = 4000, client_updated_at = now()
 where id = 'c0000000-0000-4000-8000-000000000001';
select private.derive_shifts('51000000-0000-4000-8000-000000000003',
  array['c1000000-0000-4000-8000-000000000001'::uuid]);

select pg_temp.expect('aMatchingLateArrivalDoesNotEraseAnEarlierDisagreement',
  (select unconverted_legacy_cents from public.shifts
    where user_id = '51000000-0000-4000-8000-000000000003'
      and id = 'c1000000-0000-4000-8000-000000000001') = 0
  and (select count(*) from public.shift_legacy_conflicts
        where user_id = '51000000-0000-4000-8000-000000000003') = 2
  and (select shift_cents_before = 6000 and legacy_cents_after = 7000
         from public.shift_legacy_conflicts
        where user_id = '51000000-0000-4000-8000-000000000003'
        order by id limit 1),
  (select string_agg(shift_cents_before || '->' || legacy_cents_after, ' ' order by id)
     from public.shift_legacy_conflicts
    where user_id = '51000000-0000-4000-8000-000000000003'));

-- Arm 2: emptying every live row of an OPEN group releases its money and
-- tombstones it with deleted_reason 'converted', which is what makes arm 3
-- reversible.
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000003',
  'c0000000-0000-4000-8000-000000000003',
  'c2000000-0000-4000-8000-000000000002', '2026-03-06', 5000, 'cash');
select private.derive_shifts('51000000-0000-4000-8000-000000000003',
  array['c2000000-0000-4000-8000-000000000002'::uuid]);
update public.tip_entries set deleted_at = now()
 where id = 'c0000000-0000-4000-8000-000000000003';
select private.derive_shifts('51000000-0000-4000-8000-000000000003',
  array['c2000000-0000-4000-8000-000000000002'::uuid]);

select pg_temp.expect('emptying_every_row_of_a_group_tombstones_its_shift',
  (f ->> 'cash_tips_cents')::integer = 0
  and (f ->> 'non_wage_earnings_cents')::integer = 0
  and (f ->> 'is_deleted')::boolean
  and f ->> 'deleted_reason' = 'converted'
  and f -> 'legacy_entry_ids' = '[]'::jsonb
  -- released, so there is nothing left to disagree about
  and (f ->> 'unconverted_legacy_cents')::integer = 0,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000003',
                         'c2000000-0000-4000-8000-000000000002') as f;

-- Arm 3: a legacy un-delete is a first-class live path (RemoteTipEntry
-- hardcodes deletedAt = nil and upsert_tip_entries lost its staleness guard),
-- so the shift must come back with its money.
update public.tip_entries set deleted_at = null
 where id = 'c0000000-0000-4000-8000-000000000003';
select private.derive_shifts('51000000-0000-4000-8000-000000000003',
  array['c2000000-0000-4000-8000-000000000002'::uuid]);

select pg_temp.expect('theUndeleteArmReopensAConvertedTombstoneAndRefillsIt',
  (f ->> 'cash_tips_cents')::integer = 5000
  and not (f ->> 'is_deleted')::boolean
  and f -> 'deleted_reason' = 'null'::jsonb
  and f -> 'legacy_entry_ids' = '["c0000000-0000-4000-8000-000000000003"]'::jsonb,
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000003',
                         'c2000000-0000-4000-8000-000000000002') as f;

-- ... and never a tombstone the USER set. soft_delete_shifts is a native
-- write, so deleted_reason is 'user' and native_modified_at is non-null.
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000003',
  'c0000000-0000-4000-8000-000000000004',
  'c3000000-0000-4000-8000-000000000003', '2026-03-07', 5000, 'cash');
select private.derive_shifts('51000000-0000-4000-8000-000000000003',
  array['c3000000-0000-4000-8000-000000000003'::uuid]);
update public.shifts set deleted_at = now(), deleted_reason = 'user',
                         native_modified_at = now(), client_updated_at = now()
 where user_id = '51000000-0000-4000-8000-000000000003'
   and id = 'c3000000-0000-4000-8000-000000000003';
select private.derive_shifts('51000000-0000-4000-8000-000000000003',
  array['c3000000-0000-4000-8000-000000000003'::uuid]);

select pg_temp.expect('aUserTombstoneIsNeverReopenedByTheFold',
  (f ->> 'is_deleted')::boolean and f ->> 'deleted_reason' = 'user',
  f::text)
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000003',
                         'c3000000-0000-4000-8000-000000000003') as f;

-- Arm 2a is UNCONDITIONAL and arm 4b reports the emptied-and-closed case: a
-- closed shift whose sources are all gone keeps its money, loses its claim,
-- and is recorded. If arm 2a were gated on shift_is_open_to_fold, this shift
-- would name a row it no longer derives from forever, which is what made the
-- unmigrated predicate and the duplicate count never reach zero.
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000003',
  'c0000000-0000-4000-8000-000000000005',
  'c4000000-0000-4000-8000-000000000004', '2026-03-08', 5000, 'cash');
select private.derive_shifts('51000000-0000-4000-8000-000000000003',
  array['c4000000-0000-4000-8000-000000000004'::uuid]);
update public.shifts set native_modified_at = now(), client_updated_at = now()
 where user_id = '51000000-0000-4000-8000-000000000003'
   and id = 'c4000000-0000-4000-8000-000000000004';
update public.tip_entries set deleted_at = now()
 where id = 'c0000000-0000-4000-8000-000000000005';

do $$
declare v_out record;
begin
  select * into v_out from private.derive_shifts(
    '51000000-0000-4000-8000-000000000003',
    array['c4000000-0000-4000-8000-000000000004'::uuid]);
  perform pg_temp.expect('aNativelyEditedShiftWhoseLegacyRowsWereDeletedKeepsItsMoneyAndRecordsAConflict',
    v_out.conflicts = 1
    and (select cash_tips_cents = 5000 and deleted_at is null
                and array_length(legacy_entry_ids, 1) is null
           from public.shifts
          where user_id = '51000000-0000-4000-8000-000000000003'
            and id = 'c4000000-0000-4000-8000-000000000004')
    and (select legacy_cents_after = 0 and shift_cents_before = 5000
           from public.shift_legacy_conflicts
          where user_id = '51000000-0000-4000-8000-000000000003'
            and shift_id = 'c4000000-0000-4000-8000-000000000004'
          order by id desc limit 1)
    -- the per-shift magnitude is abs(0 - 5000), not a stale value from an
    -- earlier arrival: arm 2a writes it, which the design's printed arm did not
    and (select unconverted_legacy_cents = 5000 from public.shifts
          where user_id = '51000000-0000-4000-8000-000000000003'
            and id = 'c4000000-0000-4000-8000-000000000004'),
    'conflicts=' || v_out.conflicts || ' ' ||
    (select to_jsonb(x)::text from (
       select cash_tips_cents, deleted_at is not null as is_deleted, legacy_entry_ids
         from public.shifts
        where user_id = '51000000-0000-4000-8000-000000000003'
          and id = 'c4000000-0000-4000-8000-000000000004') x));
end;
$$;

-- =============================================================================
-- 4. Idempotence, scope, and the payday.folding GUC
-- =============================================================================

-- Two rows, one group, plus a SECOND group on the SAME work_date with a
-- different shift_id (lunch and dinner is a supported shape, and a late legacy
-- row next to a native shift is another). The scope filter is inside `source`,
-- so it precedes the group by: deriving one key must never read the other's
-- rows.
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000004',
  'd0000000-0000-4000-8000-000000000001',
  'd1000000-0000-4000-8000-000000000001', '2026-05-01', 5000, 'cash',
  p_tip_out => 800, p_hours => 6.25, p_cua => '2026-05-02 01:00:00+00');
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000004',
  'd0000000-0000-4000-8000-000000000002',
  'd1000000-0000-4000-8000-000000000001', '2026-05-01', 2000, 'credit',
  p_receipt => '{"gratuityFeesCents": 500}'::jsonb, p_cua => '2026-05-02 01:05:00+00');
select pg_temp.legacy_row('51000000-0000-4000-8000-000000000004',
  'd0000000-0000-4000-8000-000000000003',
  'd2000000-0000-4000-8000-000000000002', '2026-05-01', 9900, 'cash',
  p_cua => '2026-05-02 02:00:00+00');

select private.derive_shifts('51000000-0000-4000-8000-000000000004',
  array['d1000000-0000-4000-8000-000000000001'::uuid]);

select pg_temp.expect('theScopeFilterPrecedesTheGroupBy',
  -- The in-scope group holds its own money only: 5000 + max(0, 2000-500) = 6500
  -- cash/credit, and NOT one cent of the 9900 sitting on the same work_date.
  (f ->> 'cash_tips_cents')::integer = 5000
  and (f ->> 'credit_tips_cents')::integer = 1500
  and (f ->> 'gratuity_fees_cents')::integer = 500
  and (f ->> 'non_wage_earnings_cents')::integer = 6200
  -- ... and the out-of-scope group has no shift row at all.
  and (select count(*) from public.shifts
        where user_id = '51000000-0000-4000-8000-000000000004') = 1,
  f::text || ' shifts=' || (select count(*)::text from public.shifts
    where user_id = '51000000-0000-4000-8000-000000000004'))
from pg_temp.shift_facts('51000000-0000-4000-8000-000000000004',
                         'd1000000-0000-4000-8000-000000000001') as f;

-- Two calls with the same keys and unchanged sources produce byte-identical
-- rows. converted_at, updated_at and derived_version are the three columns
-- that MUST move -- they are the stamps that say a derivation happened -- and
-- every other column, including `version`, is compared verbatim.
create temporary table snap_before as
select id, (to_jsonb(s) - 'converted_at' - 'updated_at' - 'derived_version')::text as row_text
from public.shifts s where s.user_id = '51000000-0000-4000-8000-000000000004';

select private.derive_shifts('51000000-0000-4000-8000-000000000004',
  array['d1000000-0000-4000-8000-000000000001'::uuid]);

create temporary table snap_after as
select id, (to_jsonb(s) - 'converted_at' - 'updated_at' - 'derived_version')::text as row_text
from public.shifts s where s.user_id = '51000000-0000-4000-8000-000000000004';

select pg_temp.expect('twoCallsProduceByteIdenticalRows',
  (select count(*) from snap_before) = 1
  and not exists (select 1 from snap_before b full join snap_after a using (id)
                   where b.row_text is distinct from a.row_text),
  coalesce((select 'before=' || b.row_text || E'\nafter =' || coalesce(a.row_text, 'MISSING')
              from snap_before b full join snap_after a using (id)
             where b.row_text is distinct from a.row_text limit 1), 'identical'));

select pg_temp.expect('aFoldFreezesVersionAndBumpsDerivedVersion',
  (select version = 1 and derived_version = 1 from public.shifts
    where user_id = '51000000-0000-4000-8000-000000000004'
      and id = 'd1000000-0000-4000-8000-000000000001'),
  (select 'version=' || version || ' derived_version=' || derived_version
     from public.shifts where user_id = '51000000-0000-4000-8000-000000000004'
       and id = 'd1000000-0000-4000-8000-000000000001'));

-- payday.folding is cleared before the successful return, so a native shift
-- write later in the SAME transaction still bumps `version`. That is what
-- keeps the agent API's .eq("version", expected_version) a real 409 guard
-- instead of a no-op. private.write_shifts lands in S6; a plain UPDATE is the
-- write it will make.
do $$
declare v_guc text; v_version_before bigint; v_version_after bigint;
begin
  select version into v_version_before from public.shifts
   where user_id = '51000000-0000-4000-8000-000000000004'
     and id = 'd1000000-0000-4000-8000-000000000001';
  perform private.derive_shifts('51000000-0000-4000-8000-000000000004',
    array['d1000000-0000-4000-8000-000000000001'::uuid]);
  v_guc := coalesce(current_setting('payday.folding', true), '<unset>');
  update public.shifts set note = 'native edit'
   where user_id = '51000000-0000-4000-8000-000000000004'
     and id = 'd1000000-0000-4000-8000-000000000001';
  select version into v_version_after from public.shifts
   where user_id = '51000000-0000-4000-8000-000000000004'
     and id = 'd1000000-0000-4000-8000-000000000001';
  perform pg_temp.expect('thePaydayFoldingGucIsOffAfterASuccessfulReturn',
    v_guc = 'off', 'payday.folding=' || v_guc);
  perform pg_temp.expect('aNativeShiftWriteAfterAFoldInTheSameTransactionStillBumpsVersion',
    v_version_after = v_version_before + 1,
    'before=' || v_version_before || ' after=' || v_version_after);
end;
$$;

-- ... and the same holds when the derive ABORTS. A NOT VALID check no derived
-- row can satisfy is the smallest thing that forces a real abort inside the
-- function; the S-gate's five abort classes are S4's, through the trigger.
do $$
declare v_state text; v_version_before bigint; v_version_after bigint;
begin
  alter table public.shifts
    add constraint probe_forced_abort check (cash_tips_cents < 1) not valid;
  select version into v_version_before from public.shifts
   where user_id = '51000000-0000-4000-8000-000000000004'
     and id = 'd1000000-0000-4000-8000-000000000001';
  begin
    perform private.derive_shifts('51000000-0000-4000-8000-000000000004',
      array['d1000000-0000-4000-8000-000000000001'::uuid]);
    v_state := '00000';
  exception when others then
    v_state := sqlstate;
  end;
  alter table public.shifts drop constraint probe_forced_abort;
  update public.shifts set note = 'native edit after a failed fold'
   where user_id = '51000000-0000-4000-8000-000000000004'
     and id = 'd1000000-0000-4000-8000-000000000001';
  select version into v_version_after from public.shifts
   where user_id = '51000000-0000-4000-8000-000000000004'
     and id = 'd1000000-0000-4000-8000-000000000001';
  perform pg_temp.expect('theDeriverReRaisesSoItsCallerCanRecordTheFailure',
    v_state = '23514', 'sqlstate=' || v_state);
  perform pg_temp.expect('aNativeShiftWriteAfterAFAILEDFoldInTheSameTransactionStillBumpsVersion',
    v_version_after = v_version_before + 1,
    'before=' || v_version_before || ' after=' || v_version_after);
end;
$$;

-- An empty or junk invocation is a no-op with defined output, never an error.
do $$
declare v_out record; v_shifts_before bigint; v_shifts_after bigint;
begin
  select count(*) into v_shifts_before from public.shifts;
  select * into v_out from private.derive_shifts(
    '51000000-0000-4000-8000-000000000004', '{}'::uuid[]);
  perform pg_temp.expect('anEmptyKeyArrayIsAZeroedNoOp',
    v_out.touched_count = 0 and v_out.wrote_count = 0 and v_out.conflicts = 0
      and v_out.source_cents = 0 and v_out.shift_cents = 0, to_jsonb(v_out)::text);

  select * into v_out from private.derive_shifts(
    '51000000-0000-4000-8000-000000000004', null);
  perform pg_temp.expect('aNullKeyArrayIsAZeroedNoOp',
    v_out.touched_count = 0 and v_out.wrote_count = 0, to_jsonb(v_out)::text);

  select * into v_out from private.derive_shifts(
    '51000000-0000-4000-8000-000000000004', array[null::uuid, null::uuid]);
  perform pg_temp.expect('anArrayOfNullKeysIsAZeroedNoOp',
    v_out.touched_count = 0 and v_out.wrote_count = 0, to_jsonb(v_out)::text);

  select * into v_out from private.derive_shifts(
    null, array['d1000000-0000-4000-8000-000000000001'::uuid]);
  perform pg_temp.expect('aNullAccountIsAZeroedNoOp',
    v_out.touched_count = 0 and v_out.wrote_count = 0, to_jsonb(v_out)::text);

  select * into v_out from private.derive_shifts(
    '51000000-0000-4000-8000-000000000004',
    array['ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid]);
  perform pg_temp.expect('aKeyWithNeitherRowsNorAShiftWritesNothing',
    v_out.touched_count = 1 and v_out.wrote_count = 0 and v_out.conflicts = 0,
    to_jsonb(v_out)::text);

  select count(*) into v_shifts_after from public.shifts;
  perform pg_temp.expect('theFiveNoOpInvocationsWroteNoRowAnywhere',
    v_shifts_before = v_shifts_after,
    'before=' || v_shifts_before || ' after=' || v_shifts_after);
end;
$$;

-- The deriver takes no lock of its own: the fold takes pg_try_advisory_xact_lock
-- and the one-shot and private.write_shifts take the blocking form, all on the
-- same payday:shiftmig:<uid> key. A lock taken here instead would put an old
-- build's write behind a possibly long migration.
select pg_temp.expect('theDeriverBodyTakesNoAdvisoryLockItself',
  (select count(*) from pg_proc
    where oid = 'private.derive_shifts(uuid, uuid[])'::regprocedure
      and prosrc not like '%advisory%') = 1);

select pg_temp.expect('theDeriverHasNoPStrictParameter',
  (select pronargs = 2 and pg_get_function_arguments(oid) = 'p_user_id uuid, p_group_keys uuid[]'
     from pg_proc where oid = 'private.derive_shifts(uuid, uuid[])'::regprocedure),
  (select pg_get_function_arguments(oid) from pg_proc
    where oid = 'private.derive_shifts(uuid, uuid[])'::regprocedure));

-- The grouping chain is evaluated ONCE per invocation, into a jsonb local read
-- by every arm. Four copies would be four snapshots at READ COMMITTED, and a
-- concurrent writer that lost the fold's try-lock still COMMITS its legacy row
-- before returning.
select pg_temp.expect('theGroupingChainAppearsExactlyOnceInTheBody',
  (select (length(prosrc) - length(replace(prosrc, 'group by o.group_key', '')))
          / length('group by o.group_key') = 1
     from pg_proc where oid = 'private.derive_shifts(uuid, uuid[])'::regprocedure)
  and (select prosrc like '%v_grouped := (%' and prosrc like '%jsonb_to_recordset(v_grouped)%'
         from pg_proc where oid = 'private.derive_shifts(uuid, uuid[])'::regprocedure));

-- The deriver is unreachable from the client roles: schema private has no
-- usage grant, and every client write goes through the definer RPCs.
do $$
declare v_state text;
begin
  begin
    perform set_config('request.jwt.claim.sub', '51000000-0000-4000-8000-000000000004', true);
    set local role authenticated;
    perform private.derive_shifts('51000000-0000-4000-8000-000000000004', '{}'::uuid[]);
    v_state := '00000';
  exception when others then
    v_state := sqlstate;
  end;
  reset role;
  perform pg_temp.expect('theDeriverIsUnreachableAsAuthenticated',
    v_state = '42501', 'sqlstate=' || v_state);
end;
$$;

-- Report ----------------------------------------------------------------------

-- An assertion whose driving SELECT returns no row never calls pg_temp.expect
-- and would vanish from the report instead of failing, so the count of the
-- assertions ahead of this line is pinned.
select pg_temp.expect('theSuiteRanEveryAssertion',
  (select count(*) from results) = 68,
  'ran ' || (select count(*) from results)::text || ' of 68');

select seq, case when ok then 'PASS' else 'FAIL' end as result, name, detail
from results order by seq;

select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed
from results;

do $$
declare v_failed integer;
begin
  select count(*) into v_failed from results where not ok;
  if v_failed > 0 then
    raise exception 'shift_deriver_test: % assertion(s) failed', v_failed;
  end if;
  raise notice 'shift_deriver_test: all % assertions passed', (select count(*) from results);
end;
$$;

delete from auth.users where id in (
  '51000000-0000-4000-8000-000000000001',
  '51000000-0000-4000-8000-000000000002',
  '51000000-0000-4000-8000-000000000003',
  '51000000-0000-4000-8000-000000000004');
