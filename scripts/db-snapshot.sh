#!/usr/bin/env bash
# Snapshot production tables, and REFUSE unless the snapshot is provably real.
#
# Written because `supabase db dump` requires Docker, which is not available
# on this machine. It exited CLEANLY and wrote two 0-BYTE FILES with the
# right names and timestamps. That is one step away from applying migrations
# to a money database on the strength of a rollback that does not exist.
#
# A backup that does not exist is byte-for-byte indistinguishable from one
# that does, unless you check. A zero exit is not evidence. File existence
# is not evidence. The only evidence is ROW COUNTS THAT MATCH counts
# measured separately.
#
# So this script measures counts first, dumps second, compares third, and
# exits non-zero on any mismatch. Nothing downstream may run on a snapshot
# it has not proven.
#
# Uses `supabase db query --output json`, which is the Docker-free route and
# therefore the canonical one here. Do not "simplify" this to `db dump`.
#
# Usage: scripts/db-snapshot.sh <out-dir> <table> [table...]
#        scripts/db-snapshot.sh /tmp/snap tip_entries paycheck_records
set -uo pipefail

OUT="${1:?usage: db-snapshot.sh <out-dir> <table> [table...]}"; shift
[ "$#" -gt 0 ] || { echo "REFUSE: name at least one table"; exit 2; }
mkdir -p "$OUT"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
FAIL=0

# The primary key differs per table, and getting it wrong yields an EMPTY
# file rather than an error: `user_settings` is keyed on user_id, and
# `order by id` produced a second silent 0-byte snapshot before this was
# handled.
order_key() {
  case "$1" in
    user_settings|dataset_revisions|earnings_snapshots|shift_migration_state) echo "user_id";;
    *) echo "id";;
  esac
}

for t in "$@"; do
  # STEP 1: count, independently, before dumping anything.
  expected=$(supabase db query --linked "select count(*) n from public.$t" --output json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); r=d.get("result") or d.get("rows") or []
    print(r[0]["n"] if r else "ERR")
except Exception: print("ERR")')
  if [ "$expected" = "ERR" ]; then
    echo "[FAIL] $t: could not measure a baseline count"; FAIL=1; continue
  fi

  # STEP 2: dump.
  f="$OUT/$t-$STAMP.json"
  supabase db query --linked "select * from public.$t order by $(order_key "$t")" \
    --output json 2>/dev/null > "$f"

  # STEP 3: compare. This is the only step that constitutes evidence.
  got=$(python3 -c "
import json
try:
    d=json.load(open('$f')); r=d.get('result') or d.get('rows') or []
    print(len(r))
except Exception: print('ERR')")
  if [ "$got" != "$expected" ]; then
    echo "[FAIL] $t: snapshot holds $got rows, the table holds $expected"
    echo "   -> The file exists and may be non-empty. It is still not a snapshot."
    FAIL=1
  else
    printf "[OK]   %-24s %s rows, verified against a separately measured count\n" "$t" "$got"
  fi
done

if [ "$FAIL" = "1" ]; then
  echo "=== SNAPSHOT NOT PROVEN — nothing downstream may run ==="
  exit 1
fi
echo "=== snapshot proven, $OUT (stamp $STAMP) ==="
