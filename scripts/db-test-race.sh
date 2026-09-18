#!/usr/bin/env bash
# The concurrency half of PR 2 slice S4's gate.
#
# Five facts about private.fold_legacy_writes() need two or three CONCURRENT
# sessions, which a single psql script cannot produce, so they are here instead
# of in supabase/tests/shift_fold_test.sql:
#
#   1. the try-lock race          cash 5000 / credit 0    / prov 1 / 1 backlog row
#   2. the blocking-lock variant  cash 5000 / credit 2000 / prov 2 / 0 backlog rows
#   3. the loser of the try-lock does not BLOCK behind the winner's transaction
#   4. two sessions queueing the same group neither block-forever nor raise 23505
#   5. the 40P01 deadlock row of the S-gate table
#
# Both of 1 and 2 are recorded verbatim because the design's own table records
# both, and because the shipping (try-) variant leaves the authoritative read
# surface UNDER-counted until the backlog drains -- which contradicts an
# earlier draft's claim that the transient error is "an over-count, never an
# under-count", and is the reason three separate containments exist.
#
# Usage:
#   bash scripts/db-test-race.sh                      # its own throwaway cluster
#   bash scripts/db-test-race.sh "postgresql://..."   # an existing database (CI job E)
#
# HOW THE SESSIONS WORK. A session that must hold a transaction open is a psql
# process reading a FIFO, so a statement can be sent without waiting for it --
# which is the only way to issue a statement that is SUPPOSED to block.
# Sequencing never polls psql's stdout (psql block-buffers when its output is a
# file, so a marker can sit in the buffer for the whole test); it polls
# pg_stat_activity for the session's own application_name instead, which is
# what the database itself believes.
set -euo pipefail

PG_BIN_DEFAULT=/opt/homebrew/opt/postgresql@17/bin
[ -x "$PG_BIN_DEFAULT/psql" ] || PG_BIN_DEFAULT=/usr/lib/postgresql/17/bin
PG_BIN="${PG_BIN:-$PG_BIN_DEFAULT}"

WORK="$(mktemp -d /tmp/payday-race.XXXXXX)"
OWN_CLUSTER=0
FAILED=0

if [ "${1:-}" != "" ]; then
  DSN="$1"
  PSQL=("$PG_BIN/psql" "$DSN")
else
  # shellcheck source=scripts/db-test-cluster.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/db-test-cluster.sh"
  payday_cluster_start
  payday_cluster_apply >/dev/null
  OWN_CLUSTER=1
  DSN="postgresql://postgres@localhost/postgres?host=$PAYDAY_PG_SOCK&port=$PAYDAY_PG_PORT"
  PSQL=("$PAYDAY_PG_BIN/psql" "$DSN")
fi

cleanup() {
  # Close any FIFO still open so its psql sees EOF and exits, then reap.
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  exec 5>&- 2>/dev/null || true
  wait 2>/dev/null || true
  if [ "$OWN_CLUSTER" = "1" ]; then payday_cluster_stop; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

q() { "${PSQL[@]}" -v ON_ERROR_STOP=1 -tAc "$1"; }
qq() { "${PSQL[@]}" -v ON_ERROR_STOP=1 -q -f "$1"; }

check() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf 'PASS  %-60s %s\n' "$1" "$3"
  else
    FAILED=1
    printf 'FAIL  %-60s expected [%s] got [%s]\n' "$1" "$2" "$3"
  fi
}

check_true() { # name actual_bool detail
  if [ "$2" = "t" ]; then
    printf 'PASS  %-60s %s\n' "$1" "$3"
  else
    FAILED=1
    printf 'FAIL  %-60s %s\n' "$1" "$3"
  fi
}

# --- session plumbing -------------------------------------------------------

# open_session NAME FD: a psql process reading NAME.fifo, tagged with
# application_name = payday_race_NAME so pg_stat_activity can be polled for it.
open_session() {
  local name="$1" fd="$2"
  rm -f "$WORK/$name.fifo"
  mkfifo "$WORK/$name.fifo"
  PGAPPNAME="payday_race_$name" "${PSQL[@]}" -q -f "$WORK/$name.fifo" \
    >"$WORK/$name.out" 2>&1 &
  # Hold the write end open so psql does not see EOF between statements.
  eval "exec $fd> $WORK/$name.fifo"
}

send() { # FD sql
  local fd="$1"; shift
  eval "printf '%s\n' \"\$*\" >&$fd"
}

close_session() { # FD
  eval "exec $1>&-"
}

# wait_state NAME PATTERN: block until this session's pg_stat_activity row
# matches, e.g. 'idle in transaction' (its statement finished and it is holding
# the transaction open) or 'active'.
wait_state() {
  local name="$1" want="$2" i=0
  while [ "$i" -lt 600 ]; do
    if [ "$(q "select count(*) from pg_stat_activity
              where application_name = 'payday_race_$name' and state = '$want'")" = "1" ]; then
      return 0
    fi
    sleep 0.05; i=$((i + 1))
  done
  echo "TIMEOUT waiting for session $name to be $want" >&2
  q "select application_name, state, wait_event_type, wait_event, left(query, 60)
       from pg_stat_activity where application_name like 'payday_race_%'" >&2
  cat "$WORK/$name.out" >&2 || true
  exit 1
}

# wait_blocked NAME: block until this session is waiting on a lock.
wait_blocked() {
  local name="$1" i=0
  while [ "$i" -lt 600 ]; do
    if [ "$(q "select count(*) from pg_stat_activity
              where application_name = 'payday_race_$name'
                and wait_event_type = 'Lock'")" = "1" ]; then
      return 0
    fi
    sleep 0.05; i=$((i + 1))
  done
  echo "TIMEOUT waiting for session $name to block on a lock" >&2
  exit 1
}

# --- fixture ----------------------------------------------------------------

U=54000000-0000-4000-8000-000000000001
U2=54000000-0000-4000-8000-000000000002

setup_account() { # user_id
  q "delete from auth.users where id = '$1'" >/dev/null
  q "insert into auth.users (id, email) values ('$1', 'payday-race-$1@test.invalid')" >/dev/null
}

# A 1.0-shaped write, as one self-contained statement string: the authenticated
# role, a JWT claim, and the shipped public.upsert_tip_entries RPC. Built as a
# DO block so it is a single statement that a FIFO session can be handed.
device_upsert_sql() { # user_id rows_json
  cat <<SQL
do \$race\$
begin
  perform set_config('request.jwt.claims', '{"sub": "$1"}', true);
  set local role authenticated;
  perform public.upsert_tip_entries('$2'::jsonb);
  reset role;
end \$race\$;
SQL
}

echo "== S4 concurrency suite (scripts/db-test-race.sh)"
echo

# ===========================================================================
# 1. THE TRY-LOCK RACE, the variant that ships.
#
# MEASURED with no per-group lock at all: session A inserts a $50.00 cash row
# and holds its transaction open, session B inserts the $20.00 credit row of
# the same shift and commits, and the result is cash = 0, credit = 2000,
# provenance length 1, with the CASH row named by no shift at all. At READ
# COMMITTED B's recompute took its snapshot before A committed, so `excluded`
# described only B's row and `do update` overwrote A's.
#
# Under pg_try_advisory_xact_lock B does not overwrite and does not block: it
# queues the group and returns, so the shift is UNDER-counted until the backlog
# drains.
# ===========================================================================

setup_account "$U"
open_session a 3
send 3 "begin;"
wait_state a "idle in transaction"
send 3 "$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000011","shift_id":"54000000-0000-0000-0000-000000000010","work_date":"2026-07-04","amount_cents":5000,"kind":"cash","client_updated_at":"2026-07-04T23:00:00Z"}]')"
wait_state a "idle in transaction"

# B: one autocommit statement, so its fold runs and commits while A holds the
# advisory lock.
PGAPPNAME=payday_race_b "${PSQL[@]}" -v ON_ERROR_STOP=1 -q -c \
  "$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000012","shift_id":"54000000-0000-0000-0000-000000000010","work_date":"2026-07-04","amount_cents":2000,"kind":"credit","client_updated_at":"2026-07-04T23:05:00Z"}]')"

send 3 "commit;"
wait_state a "idle"
close_session 3
wait || true

# orphans=1 is the under-count itself, stated as a number: the credit row is
# committed in public.tip_entries and named by NO shift until the backlog
# drains. That is the fact that makes an earlier draft's "the transient error
# is an over-count, never an under-count" false, and the reason the reader's
# first-switch predicate, payday_unmigrated_tip_row_count()'s backlog term and
# the explicit drain step in the sync pass are all load-bearing.
check "theTryLockRaceLeavesTheWinnersMoneyAndQueuesTheLosers" \
  "cash=5000 credit=0 nonwage=5000 prov=1 backlog=1 orphans=1 truth=7000" \
  "$(q "select 'cash=' || s.cash_tips_cents || ' credit=' || s.credit_tips_cents
            || ' nonwage=' || s.non_wage_earnings_cents
            || ' prov=' || coalesce(array_length(s.legacy_entry_ids,1),0)
            || ' backlog=' || (select count(*) from private.shift_fold_backlog where user_id = '$U')
            || ' orphans=' || (select count(*) from public.tip_entries e
                                where e.user_id = '$U' and e.deleted_at is null
                                  and not exists (select 1 from public.shifts x
                                                   where x.user_id = e.user_id
                                                     and e.id = any(x.legacy_entry_ids)))
            || ' truth=' || (select sum(amount_cents) from public.tip_entries
                              where user_id = '$U' and deleted_at is null)
       from public.shifts s where s.user_id = '$U'")"

check "theRaceRecordedNoFailureAnywhere" "0" \
  "$(q "select count(*) from private.shift_fold_failures where user_id = '$U'")"

# aConcurrentLegacyWriteThatLosesTheLockIsStillCountedAfterTheNextSync: the
# under-count is transient. Any later legacy write drains the reserved backlog
# share and the money converges.
"${PSQL[@]}" -v ON_ERROR_STOP=1 -q -c \
  "$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000021","shift_id":"54000000-0000-0000-0000-000000000020","work_date":"2026-07-05","amount_cents":100,"kind":"cash","client_updated_at":"2026-07-05T23:00:00Z"}]')"

check "aConcurrentLegacyWriteThatLosesTheLockIsStillCountedAfterTheNextSync" \
  "cash=5000 credit=2000 nonwage=7000 prov=2 backlog=0 orphans=0" \
  "$(q "select 'cash=' || s.cash_tips_cents || ' credit=' || s.credit_tips_cents
            || ' nonwage=' || s.non_wage_earnings_cents
            || ' prov=' || coalesce(array_length(s.legacy_entry_ids,1),0)
            || ' backlog=' || (select count(*) from private.shift_fold_backlog where user_id = '$U')
            || ' orphans=' || (select count(*) from public.tip_entries e
                                where e.user_id = '$U' and e.deleted_at is null
                                  and not exists (select 1 from public.shifts x
                                                   where x.user_id = e.user_id
                                                     and e.id = any(x.legacy_entry_ids)))
       from public.shifts s where s.user_id = '$U'
        and s.id = '54000000-0000-0000-0000-000000000010'")"

# ===========================================================================
# 2. THE BLOCKING-LOCK VARIANT, recorded verbatim for comparison. NOT what
#    ships: blocking would put an old build's write behind a possibly long
#    migration and into a client-side timeout, which is itself a rejected
#    write.
#
#    The second session takes the SAME per-account key with the BLOCKING
#    pg_advisory_xact_lock before its own legacy write, which is exactly the
#    shape private.write_shifts and the one-shot take (S5, S6). Advisory locks
#    are reentrant within a transaction, so the fold's own try-lock then
#    succeeds, and because the session waited for the holder its snapshot
#    includes the first row. That is the whole semantic difference between the
#    two table rows, reproduced without a second copy of the fold.
# ===========================================================================

setup_account "$U2"
open_session a 3
send 3 "begin;"
wait_state a "idle in transaction"
send 3 "$(device_upsert_sql "$U2" '[{"id":"54000000-0000-0000-0000-000000000031","shift_id":"54000000-0000-0000-0000-000000000030","work_date":"2026-07-04","amount_cents":5000,"kind":"cash","client_updated_at":"2026-07-04T23:00:00Z"}]')"
wait_state a "idle in transaction"

# B, in the background, blocking on the per-account key.
cat > "$WORK/blocking.sql" <<SQL
begin;
do \$lock\$ begin
  perform pg_advisory_xact_lock(hashtextextended('payday:shiftmig:$U2', 0));
end \$lock\$;
$(device_upsert_sql "$U2" '[{"id":"54000000-0000-0000-0000-000000000032","shift_id":"54000000-0000-0000-0000-000000000030","work_date":"2026-07-04","amount_cents":2000,"kind":"credit","client_updated_at":"2026-07-04T23:05:00Z"}]')
commit;
SQL
PGAPPNAME=payday_race_b "${PSQL[@]}" -v ON_ERROR_STOP=1 -q -f "$WORK/blocking.sql" &
BPID=$!
wait_blocked b
send 3 "commit;"
wait_state a "idle"
close_session 3
wait "$BPID"

check "theBlockingLockVariantSeesBothRowsAndQueuesNothing" \
  "cash=5000 credit=2000 nonwage=7000 prov=2 backlog=0 truth=7000" \
  "$(q "select 'cash=' || s.cash_tips_cents || ' credit=' || s.credit_tips_cents
            || ' nonwage=' || s.non_wage_earnings_cents
            || ' prov=' || coalesce(array_length(s.legacy_entry_ids,1),0)
            || ' backlog=' || (select count(*) from private.shift_fold_backlog where user_id = '$U2')
            || ' truth=' || (select sum(amount_cents) from public.tip_entries
                              where user_id = '$U2' and deleted_at is null)
       from public.shifts s where s.user_id = '$U2'")"

wait || true

# ===========================================================================
# 3. THE LOSER OF THE TRY-LOCK DOES NOT BLOCK behind the winner's transaction.
#
# This is what makes private.note_legacy_write's placement load-bearing rather
# than tidy. It writes ONE row per account, so if the fold stamped
# last_legacy_write_at before or outside the advisory lock, the session that
# LOST the try-lock -- the one whose entire purpose is to return immediately --
# would take a ROW lock queued behind the winner's whole fold transaction. A
# 1.0 write blocked behind another 1.0 write is the shape the try-lock exists
# to prevent, reintroduced by a bookkeeping UPDATE.
#
# The winner holds for 2 seconds; the loser must finish in a small fraction of
# that. Measured in milliseconds, with a deliberately loose 1000 ms ceiling so
# the assertion is about blocking-versus-not and not about machine speed.
# ===========================================================================

setup_account "$U"
open_session a 3
send 3 "begin;"
wait_state a "idle in transaction"
send 3 "$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000041","shift_id":"54000000-0000-0000-0000-000000000040","work_date":"2026-07-06","amount_cents":5000,"kind":"cash","client_updated_at":"2026-07-06T23:00:00Z"}]')"
wait_state a "idle in transaction"
# the winner keeps the lock for two more seconds
send 3 "select pg_sleep(2);"

# Timed in the shell, around the whole round trip, so nothing inside the
# database can flatter the number.
START=$(python3 -c 'import time; print(int(time.time()*1000))')
PGAPPNAME=payday_race_b "${PSQL[@]}" -v ON_ERROR_STOP=1 -q -c \
  "$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000051","shift_id":"54000000-0000-0000-0000-000000000050","work_date":"2026-07-07","amount_cents":2000,"kind":"cash","client_updated_at":"2026-07-07T23:00:00Z"}]')"
END=$(python3 -c 'import time; print(int(time.time()*1000))')
LOSER_MS=$((END - START))

send 3 "commit;"
wait_state a "idle"
close_session 3
wait || true

check_true "theLoserOfTheTryLockDoesNotBlockOnTheWinnersTransaction" \
  "$([ "$LOSER_MS" -lt 1000 ] && echo t || echo f)" \
  "loser returned in ${LOSER_MS} ms while the winner held the lock for 2000 ms"

check "theLosersGroupWasQueuedNotDropped" "1" \
  "$(q "select count(*) from private.shift_fold_backlog
         where user_id = '$U' and group_key = '54000000-0000-0000-0000-000000000050'")"

# ===========================================================================
# 4. TWO SESSIONS QUEUEING THE SAME GROUP neither block forever nor raise.
#
# Every insert into private.shift_fold_backlog is `on conflict (user_id,
# group_key) do nothing`, in sorted key order. Without the ON CONFLICT clause
# the second session raises 23505 on commit, which the fold's own handler
# swallows -- and swallowing it DROPS that session's keys entirely. With the
# clause nothing raises and nothing is dropped. ON CONFLICT DO NOTHING still
# WAITS for a concurrent uncommitted duplicate, and that wait is bounded by the
# other session's transaction; the measured wait is printed.
# ===========================================================================

setup_account "$U"
q "delete from private.shift_fold_backlog where user_id = '$U'" >/dev/null

# A holds the advisory lock so that B and C both LOSE the try-lock and both try
# to queue the same group.
open_session a 3
send 3 "begin;"
wait_state a "idle in transaction"
send 3 "$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000061","shift_id":"54000000-0000-0000-0000-000000000060","work_date":"2026-07-08","amount_cents":5000,"kind":"cash","client_updated_at":"2026-07-08T23:00:00Z"}]')"
wait_state a "idle in transaction"

# B loses the try-lock, queues group 60, and HOLDS its transaction open.
open_session b 4
send 4 "begin;"
wait_state b "idle in transaction"
send 4 "$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000062","shift_id":"54000000-0000-0000-0000-000000000060","work_date":"2026-07-08","amount_cents":1000,"kind":"cash","client_updated_at":"2026-07-08T23:01:00Z"}]')"
wait_state b "idle in transaction"

# C loses the try-lock too and tries to queue the SAME group, so it meets B's
# uncommitted index entry.
START=$(python3 -c 'import time; print(int(time.time()*1000))')
PGAPPNAME=payday_race_c "${PSQL[@]}" -v ON_ERROR_STOP=1 -q -c \
  "$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000063","shift_id":"54000000-0000-0000-0000-000000000060","work_date":"2026-07-08","amount_cents":1500,"kind":"cash","client_updated_at":"2026-07-08T23:02:00Z"}]')" &
CPID=$!
wait_blocked c
send 4 "commit;"
wait_state b "idle"
wait "$CPID"
C_OUTCOME=$?
END=$(python3 -c 'import time; print(int(time.time()*1000))')
send 3 "commit;"
wait_state a "idle"
close_session 3
close_session 4
wait || true

check "two_sessions_queueing_the_same_group_neither_block_nor_raise" \
  "exit=0 backlog=1 failures=0" \
  "exit=$C_OUTCOME backlog=$(q "select count(*) from private.shift_fold_backlog where user_id = '$U' and group_key = '54000000-0000-0000-0000-000000000060'") failures=$(q "select count(*) from private.shift_fold_failures where user_id = '$U'")"

echo "      (the waiter cleared in $((END - START)) ms, bounded by the other session's transaction)"

# ===========================================================================
# 5. THE 40P01 ROW OF THE S-GATE TABLE.
#
# Two sessions taking row locks on two shifts in opposite orders. The fold's
# arm 1 locks the groups of v_spend in sorted key order, so a native shift
# write holding the second one and then reaching for the first is the one
# structurally reachable deadlock -- which is why private.write_shifts takes
# the same blocking advisory lock in S6, removing the shape entirely, and why
# the `when deadlock_detected` arm stays as the belt.
#
# WHICH SESSION DIES WAS A MEASUREMENT, NOT A CHOICE. PostgreSQL's detector
# aborts the process that DETECTS the cycle, and the fold is structurally the
# FIRST waiter in any cycle it can join: it holds nothing until the statement
# that then blocks, so the cycle only closes after it is already waiting. That
# would make the OTHER session the detector -- if the deadlock check ran once
# per wait. MEASURED on PG 17.11: it does not. PostgreSQL re-arms the check
# while a backend waits, so the fold, with deadlock_timeout = 100 ms against
# the other session's 10 s, detects the cycle it is already inside and is the
# victim. That is what makes this row of the S-gate assertable at all, and it
# is the only reason the `when deadlock_detected` arm can be exercised rather
# than merely declared.
# ===========================================================================

setup_account "$U"
q "delete from private.shift_fold_backlog where user_id = '$U'" >/dev/null
q "delete from private.shift_fold_failures where user_id = '$U'" >/dev/null

# Two existing shifts, so the fold's arm 1 takes ROW locks (DO UPDATE) instead
# of inserting fresh rows.
"${PSQL[@]}" -v ON_ERROR_STOP=1 -q -c \
  "$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000071","shift_id":"54000000-0000-0000-0000-000000000070","work_date":"2026-07-09","amount_cents":1000,"kind":"cash","client_updated_at":"2026-07-09T23:00:00Z"},{"id":"54000000-0000-0000-0000-000000000081","shift_id":"54000000-0000-0000-0000-000000000080","work_date":"2026-07-10","amount_cents":1000,"kind":"cash","client_updated_at":"2026-07-10T23:00:00Z"}]')"

# A holds the LATER key and will reach for the earlier one.
open_session a 3
send 3 "begin;"
wait_state a "idle in transaction"
send 3 "set local deadlock_timeout = '10s';"
send 3 "select 1 from public.shifts where user_id = '$U' and id = '54000000-0000-0000-0000-000000000080' for update;"
wait_state a "idle in transaction"

# B: a 1.0-shaped write touching BOTH groups. Its fold locks ...070 first, then
# blocks on ...080. Its deadlock_timeout is short so that if PostgreSQL re-arms
# the check while it waits, B is the detector.
cat > "$WORK/deadlock_b.sql" <<SQL
set deadlock_timeout = '100ms';
$(device_upsert_sql "$U" '[{"id":"54000000-0000-0000-0000-000000000072","shift_id":"54000000-0000-0000-0000-000000000070","work_date":"2026-07-09","amount_cents":2000,"kind":"credit","client_updated_at":"2026-07-09T23:05:00Z"},{"id":"54000000-0000-0000-0000-000000000082","shift_id":"54000000-0000-0000-0000-000000000080","work_date":"2026-07-10","amount_cents":2000,"kind":"credit","client_updated_at":"2026-07-10T23:05:00Z"}]')
SQL
PGAPPNAME=payday_race_b "${PSQL[@]}" -q -f "$WORK/deadlock_b.sql" >"$WORK/b_deadlock.out" 2>&1 &
BPID=$!
wait_blocked b

# A now closes the cycle by reaching for the key B holds.
send 3 "select 1 from public.shifts where user_id = '$U' and id = '54000000-0000-0000-0000-000000000070' for update;"

set +e
wait "$BPID"
B_EXIT=$?
set -e
send 3 "commit;"
close_session 3
wait || true

B_ERR="$(grep -c 'ERROR' "$WORK/b_deadlock.out" || true)"
FOLD_40P01="$(q "select count(*) from private.shift_fold_failures
                  where user_id = '$U' and sqlstate = '40P01'")"
DEADLOCK_VICTIM="fold"
[ "$FOLD_40P01" = "0" ] && DEADLOCK_VICTIM="the other session"

echo "      deadlock victim: $DEADLOCK_VICTIM (b exit=$B_EXIT, b errors=$B_ERR, fold 40P01 rows=$FOLD_40P01)"
sed 's/^/      | /' "$WORK/b_deadlock.out" | head -5

# Whatever the victim, the one thing that must hold is the rule this slice is
# built on: the shipped 1.0 build's write was NOT rejected.
check "aDeadlockNeverRejectsTheLegacyWrite" "rows=4 errors=0" \
  "rows=$(q "select count(*) from public.tip_entries where user_id = '$U'
              and id in ('54000000-0000-0000-0000-000000000071','54000000-0000-0000-0000-000000000072',
                         '54000000-0000-0000-0000-000000000081','54000000-0000-0000-0000-000000000082')
              and deleted_at is null") errors=$B_ERR"

check "aDeadlockInsideTheFoldIsCaughtAndTheKeysAreQueued" "rows=1 keys=2 queued=2" \
  "rows=$FOLD_40P01 keys=$(q "select count(distinct k) from private.shift_fold_failures f, unnest(f.group_keys) k
                where f.user_id = '$U' and f.sqlstate = '40P01'") queued=$(q "select count(*) from private.shift_fold_backlog where user_id = '$U'")"

q "delete from auth.users where id in ('$U','$U2')" >/dev/null

echo
if [ "$FAILED" = "1" ]; then
  echo "== S4 concurrency suite FAILED"
  exit 1
fi
echo "== S4 concurrency suite passed"
