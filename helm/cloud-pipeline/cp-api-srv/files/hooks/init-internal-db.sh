#!/bin/bash
set -e
_pg_attempt=0
_pg_max=140
until PGPASSWORD=postgres pg_isready -h "$PSG_HOST" -p "$PSG_PORT" -U postgres -d postgres; do
  _pg_attempt=$((_pg_attempt + 1))
  if [ "$_pg_attempt" -ge "$_pg_max" ]; then
    echo "ERROR: PostgreSQL not reachable at $PSG_HOST:$PSG_PORT after $((_pg_max * 2))s"
    exit 1
  fi
  echo "cp-api-db-init: waiting for PostgreSQL at $PSG_HOST:$PSG_PORT (attempt $_pg_attempt/${_pg_max})..."
  sleep 2
done
echo "cp-api-db-init: PostgreSQL is accepting connections."
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
EPASS="$(sql_escape "$PSG_PASS")"
PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h "$PSG_HOST" -p "$PSG_PORT" -U postgres -d postgres \
  -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
if ! PGPASSWORD=postgres psql -h "$PSG_HOST" -p "$PSG_PORT" -U postgres -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$PSG_USER'" | grep -q 1; then
  PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h "$PSG_HOST" -p "$PSG_PORT" -U postgres -d postgres \
    -c "CREATE USER \"$PSG_USER\" CREATEDB SUPERUSER;"
fi
PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h "$PSG_HOST" -p "$PSG_PORT" -U postgres -d postgres \
  -c "ALTER USER \"$PSG_USER\" WITH SUPERUSER;"
PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h "$PSG_HOST" -p "$PSG_PORT" -U postgres -d postgres \
  -c "ALTER USER \"$PSG_USER\" WITH PASSWORD '$EPASS';"
if ! PGPASSWORD=postgres psql -h "$PSG_HOST" -p "$PSG_PORT" -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$PSG_DB'" | grep -q 1; then
  PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h "$PSG_HOST" -p "$PSG_PORT" -U postgres -d postgres \
    -c "CREATE DATABASE \"$PSG_DB\" OWNER \"$PSG_USER\";"
fi
PGPASSWORD="$PSG_PASS" psql -v ON_ERROR_STOP=1 -h "$PSG_HOST" -p "$PSG_PORT" -U "$PSG_USER" -d "$PSG_DB" \
  -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
echo "cp-api-db-init: done (user=$PSG_USER database=$PSG_DB)"
