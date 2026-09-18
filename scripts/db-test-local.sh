#!/usr/bin/env bash
# Run the supabase/tests SQL suites without Docker.
#
# CI job E ("Supabase migrations (db reset)") runs `supabase db reset --local`
# and then the same scripts against the local stack. This does the equivalent
# on a throwaway Homebrew postgresql@17 cluster in /tmp, which takes a couple
# of seconds and works when Docker is not running:
#
#   bash scripts/db-test-local.sh
#
# The cluster itself, and the Supabase primitives the migrations depend on,
# live in scripts/db-test-cluster.sh, which scripts/db-test-race.sh shares.
# The concurrency suite is NOT run here: it needs several real psql processes
# and has its own script.
set -euo pipefail

# shellcheck source=scripts/db-test-cluster.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/db-test-cluster.sh"

cleanup() { payday_cluster_stop; }
trap cleanup EXIT

payday_cluster_start
payday_cluster_apply

status=0
for f in "$PAYDAY_REPO_ROOT"/supabase/tests/*_test.sql; do
  echo "== $(basename "$f")"
  $PAYDAY_PSQL -v ON_ERROR_STOP=1 -f "$f" || status=$?
done
exit "$status"
