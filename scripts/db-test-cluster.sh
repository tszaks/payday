#!/usr/bin/env bash
# A throwaway Postgres cluster with Payday's migrations applied, for the SQL
# suites. SOURCED, never executed: it defines three functions and sets three
# variables.
#
#   source scripts/db-test-cluster.sh
#   payday_cluster_start          # sets PAYDAY_PG_SOCK / PAYDAY_PG_PORT / PAYDAY_PSQL
#   payday_cluster_apply          # applies supabase/migrations in order
#   payday_cluster_stop
#
# It creates only the Supabase primitives the migrations actually depend on --
# auth.users, auth.uid(), the anon / authenticated / service_role roles, and
# Supabase's DEFAULT PRIVILEGES on schema public, which is what makes the
# migrations' REVOKE statements load-bearing rather than cosmetic. It is not a
# substitute for CI job E, which runs `supabase db reset --local` against the
# real local stack; it is the fast local loop, and it works when Docker is not
# running.
#
# Used by scripts/db-test-local.sh and scripts/db-test-race.sh.

PAYDAY_PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@17/bin}"
if [ ! -x "$PAYDAY_PG_BIN/initdb" ] && [ -x /usr/lib/postgresql/17/bin/initdb ]; then
  PAYDAY_PG_BIN=/usr/lib/postgresql/17/bin
fi
PAYDAY_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

payday_cluster_start() {
  # Any free high port: a cluster left running from an earlier debugging
  # session must not silently take the suite's connection.
  PAYDAY_PG_PORT="${PORT:-$(python3 -c "import socket
s = socket.socket()
s.bind((\"127.0.0.1\", 0))
print(s.getsockname()[1])
s.close()")}"
  PAYDAY_PG_DATA="$(mktemp -d /tmp/payday-dbtest.XXXXXX)"
  PAYDAY_PG_SOCK="$PAYDAY_PG_DATA/sock"
  mkdir -p "$PAYDAY_PG_SOCK"
  "$PAYDAY_PG_BIN/initdb" -D "$PAYDAY_PG_DATA/pgdata" -U postgres --auth=trust -E UTF8 \
    >"$PAYDAY_PG_DATA/initdb.log" 2>&1
  "$PAYDAY_PG_BIN/pg_ctl" -D "$PAYDAY_PG_DATA/pgdata" -l "$PAYDAY_PG_DATA/pg.log" \
    -o "-p $PAYDAY_PG_PORT -k $PAYDAY_PG_SOCK" -w start >/dev/null
  PAYDAY_PSQL="$PAYDAY_PG_BIN/psql -h $PAYDAY_PG_SOCK -p $PAYDAY_PG_PORT -U postgres -d postgres"

  $PAYDAY_PSQL -v ON_ERROR_STOP=1 -q <<'SQL'
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
}

payday_cluster_apply() {
  local f
  # -1 wraps each file in one transaction, which is how `supabase db reset`
  # applies a migration: without it a `set local` inside a migration warns and
  # does nothing, and a half-applied file would leave the cluster inconsistent.
  for f in "$PAYDAY_REPO_ROOT"/supabase/migrations/*.sql; do
    $PAYDAY_PSQL -v ON_ERROR_STOP=1 -q -1 -f "$f"
    echo "applied $(basename "$f")"
  done
}

payday_cluster_stop() {
  "$PAYDAY_PG_BIN/pg_ctl" -D "$PAYDAY_PG_DATA/pgdata" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$PAYDAY_PG_DATA"
}
