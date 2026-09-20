# Applying `20260920030000_stamp_authority_at_account_creation.sql`

**Status: BLOCKED. DO NOT APPLY AS WRITTEN. The rollback does not exist on
production.**

## 2026-09-20: the blocker, found at step 2 of this runbook

Measured against production:

| | |
|---|---|
| `current_user` | `postgres` |
| `postgres` is superuser | **false** |
| `auth.users` owner | `supabase_auth_admin` |
| `postgres` member of that owner / can `SET ROLE` | **false / false** |
| `has_table_privilege('auth.users','TRIGGER')` | **true** |
| non-internal triggers on `auth.users` | **zero** (all 50 are `RI_ConstraintTrigger`) |

`CREATE TRIGGER` requires the TRIGGER privilege. `DROP TRIGGER` requires
**ownership of the table**. We have the first and not the second, so this
migration is **installable and not removable**: it would put a trigger in the
live signup path with no way to take it out.

**The step-2 check as originally written is worthless, and reads as a pass.**
Running `drop trigger if exists users_stamp_shift_authority on auth.users`
against production returns clean — because `IF EXISTS` on a trigger that does
not exist skips *before* checking permission. A no-op succeeding is
indistinguishable from permission confirmed. Do not re-run it and conclude
anything. Check `pg_roles.rolsuper`, the table's owner, and `pg_has_role`
instead, which is what the table above does.

**The local rollback test could not have caught this.** `db-test-cluster.sh`
creates `auth.users` itself, so `postgres` owns it there and the drop
naturally succeeds. The local run establishes the SQL is valid. It establishes
nothing about who may execute it here — the caveat already in this file, one
step further than it was taken.

### Where the design goes instead

The goal is unchanged: the server owns the authority fact, the device only
receives it. What fails is attaching to `auth.users`, which is not ours.

1. A trigger on a `public` table the app writes first (`user_settings` is
   owned by `postgres`, so it is ours to install *and* drop). Needs checking
   whether that write beats the log sheet, or it only moves the round-trip.
2. **Preferred.** Synthesise it on the READ path: an RPC or view returning an
   authoritative state when no row exists AND the account holds zero
   `tip_entries`. Entirely inside `public`, fully reversible.
3. Granting `postgres` membership of `supabase_auth_admin` is an
   infrastructure decision and is Tyler's, not an agent's.

Everything below is retained because it is still the right *procedure* — it
is the target that has to change.

---

**Original status: NOT APPLIED. Daylight only, with someone watching.**

## Why this one has a runbook and other migrations do not

Every other migration in this project touches `public.*`. This one puts a
trigger on `auth.users`, which is GoTrue's table, and a trigger there runs
inside the signup transaction. The failure mode is not a wrong number on a
screen. It is **a stranger being unable to create an account**, on the
onboarding flow that has already drawn a Guideline 4 rejection once, while
1.0 is `READY_FOR_SALE` on the store.

The upside is closing a first-run window that has existed for as long as the
store has been open. Nothing gets worse while this waits. That asymmetry is
why it waits.

## What local testing does and does not establish

`bash scripts/db-test-local.sh` passes, 10 suites / 390 assertions, including
`account_creation_authority_test.sql` with its control. That establishes:

- the SQL is valid and the trigger body cannot raise out of itself
- an **unguarded** raise in that position *does* block the insert, so the
  guarded case passing is not vacuous
- the fold still converts a legacy row arriving at an already-stamped account
- the delete cascade still removes the row

It does **not** establish either of the two things that matter at runtime:

1. **That hosted Supabase permits a trigger on `auth.users` at all.** There is
   no precedent for one in this project; every existing trigger targets
   `public.*`. The local cluster creates `auth.users` itself, so it cannot
   speak to the hosted instance's permissions.
2. **That the auth SERVICE tolerates it.** `insert into auth.users` is not the
   path a real signup takes. GoTrue inserts in its own transaction, as its own
   role, with its own error handling. The trigger fires in both cases, but
   "a raw SQL insert committed" is a different claim from "GoTrue's signup
   succeeded."

Only step 4 below tests the second one. Everything before it is necessary and
none of it is sufficient.

## The rollback, which exists before it is needed

```sql
drop trigger if exists users_stamp_shift_authority on auth.users;
```

**Have this ready before applying, not composed while signups are failing.**
A remedy written under pressure is how a five-second fix becomes twenty
minutes.

Verified on the local cluster rather than assumed:

- it removes the trigger
- running it a second time exits 0 and emits no error (idempotent, so it is
  safe to fire without first checking whether it already ran)
- signup afterwards works and produces no state row, which is exactly
  pre-migration behaviour
- the backfilled rows survive it, correctly: they are true regardless of
  whether the trigger stays, so **the backfill does not need reverting**

The function is left behind by the rollback and that is harmless: nothing
calls it once the trigger is gone.

## Order of operations

1. **Snapshot.** `bash scripts/db-snapshot.sh /tmp/snap-authority shift_migration_state`
   plus a count of `auth.users`. Record both numbers here before proceeding.
2. **Confirm the rollback executes** against production before you need it.
3. **Apply** the migration. It is one transaction, so a hosted instance
   refusing the trigger fails loudly and lands nothing partial — that is the
   good failure.
4. **A REAL Sign in with Apple**, end to end through the app on a throwaway
   Apple ID. Not a SQL insert. This is the only step that exercises the path a
   lockout would occur on.
5. **Confirm**: the account exists, it has exactly one `shift_migration_state`
   row, `migrated_at` is set, `remaining_group_count` is 0, the conservation
   counters are NULL, and the app reaches `.ready`.
6. **A second real signup ten minutes later**, because the first can succeed
   on a warm path.

**If step 4 fails, roll back first and diagnose second.**

## What this unblocks

The eleven flip `else` branches, and `ShiftWriter` with them. Those are
blocked on this and not on Tyler's account having flipped — the window is
about new accounts, and the store is open. See the deletion sequencing in
`docs/design/PAYDAYCORE_PLAN.md`.
