# S4 brief: the on-arrival trigger (PR 2 slice 4)

Worktree: ~/Projects/Payday-s4, branch paydaycore/pr2-s4-trigger.
MUST rebase onto S3's merge commit before starting: the trigger calls private.derive_shifts.

Spec: docs/design/PR2-design-final.md section 4 in full (38KB, extracted to /tmp/paydaycore/S4-section.md
for convenience but read it from the repo), plus section 13's S4 entry for the exact file and test list,
and section 4.6's S-gate table which is the abort-class contract.

## Why this slice is the dangerous one

The fold runs INSIDE the shipped 1.0 build's own transaction. Payday 1.0 contains no handling for a
rejected write (this is what killed design shape 2). So anything the fold can fail on becomes a dark
app and a device that can never sync again. The rule is absolute:

  THE FOLD NEVER RAISES AND NEVER REJECTS.

That is why the five-arm exception block exists, why every money value is clamped rather than
CHECK-validated, and why every constraint on public.shifts must be satisfiable-by-construction from
any row public.tip_entries can legally hold. `when others` does NOT catch 57014 query_canceled or
assert_failure: both need their own arm. Measured, binding.

## Measured facts this slice must reproduce, not rediscover

- Two legacy rows of one shift arriving in separate overlapping transactions LOSE one row's money
  without a per-group lock: measured cash=0/credit=2000/prov=1 with the cash row orphaned. With
  `pg_advisory_xact_lock` as the first statement it is cash=5000/credit=2000/prov=2/orphans=0.
- The design mandates `pg_try_advisory_xact_lock` instead, so a 1.0 write never blocks behind the
  one-shot's 60s statement_timeout. The try-variant therefore gives cash 5000 / credit 0 / prov 1 and
  ONE backlog row; the blocking variant gives 5000/2000/prov 2 and zero backlog. Record BOTH verbatim.
- Soft-deleting the LAST live row of a group leaves the shift's money in place forever unless arm 2
  handles it: `group by` emits no row, so `insert ... on conflict do update` updates nothing.
- `jsonb_set` on a non-object receipt payload raises `path element at position 1 is not an integer`,
  and tip_entries.receipt_metrics has no object CHECK.
- Reference timing: 14.6 ms for 500 rows / 250 groups. Report your own measurement.

## Gate

CI job E from a clean `supabase db reset --local`, every test in the S4 list green, the 500-row timing
in the PR body, plus the whole existing gate (package tests, app suite Swift Testing total, design
lint, deno) unbroken. Execute against a real Postgres and paste output; do not reason about SQL.
