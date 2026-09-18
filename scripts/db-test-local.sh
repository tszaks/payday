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
# It creates only the Supabase primitives the migrations actually depend on --
# auth.users, auth.uid(), the anon / authenticated / service_role roles, and
# Supabase's DEFAULT PRIVILEGES on schema public, which is what makes the
# migrations' REVOKE statements load-bearing rather than cosmetic. It is not a
# substitute for job E; it is the fast local loop.
set -euo pipefail

PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@17/bin}"
# Any free high port: a cluster left running from an earlier debugging session
# must not silently take the suite's connection.
PORT="${PORT:-$(python3 -c "import socket
s = socket.socket()
s.bind((\"127.0.0.1\", 0))
print(s.getsockname()[1])
s.close()")}"
DATA_DIR="$(mktemp -d /tmp/payday-dbtest.XXXXXX)"
SOCK_DIR="$DATA_DIR/sock"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
  "$PG_BIN/pg_ctl" -D "$DATA_DIR/pgdata" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$DATA_DIR"
}
trap cleanup EXIT

mkdir -p "$SOCK_DIR"
"$PG_BIN/initdb" -D "$DATA_DIR/pgdata" -U postgres --auth=trust -E UTF8 >"$DATA_DIR/initdb.log" 2>&1
"$PG_BIN/pg_ctl" -D "$DATA_DIR/pgdata" -l "$DATA_DIR/pg.log" \
  -o "-p $PORT -k $SOCK_DIR" -w start >/dev/null

psql=("$PG_BIN/psql" -h "$SOCK_DIR" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1)

"${psql[@]}" -q <<'SQL'
create extension if not exists pgcrypto;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
end $$;
grant anon, authenticated, service_role to postgres;
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  created_at timestamptz not null default now());
create unique index if not exists users_email_partial_key on auth.users (email) where email is not null;
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$;
grant execute on function auth.uid() to anon, authenticated, service_role;
SQL

# -1 wraps each file in one transaction, which is how `supabase db reset`
# applies a migration: without it a `set local` inside a migration warns and
# does nothing, and a half-applied file would leave the cluster inconsistent.
for f in "$REPO_ROOT"/supabase/migrations/*.sql; do
  "${psql[@]}" -q -1 -f "$f"
  echo "applied $(basename "$f")"
done

status=0
for f in "$REPO_ROOT"/supabase/tests/*_test.sql; do
  echo "== $(basename "$f")"
  "${psql[@]}" -f "$f" || status=$?
done
exit "$status"
