#!/bin/bash
set -euo pipefail

echo "cp-clair-db-init: provisioning database=$CLAIR_DB user=$CLAIR_USER on host=$CLAIR_HOST port=$CLAIR_PORT"

# Bounded wait (until hook activeDeadlineSeconds if DB never appears).
_pg_attempt=0
_pg_max=140
until PGPASSWORD=postgres pg_isready -h "$CLAIR_HOST" -p "$CLAIR_PORT" -U postgres -d postgres; do
  _pg_attempt=$((_pg_attempt + 1))
  if [ "$_pg_attempt" -ge "$_pg_max" ]; then
    echo "ERROR: PostgreSQL not reachable at $CLAIR_HOST:$CLAIR_PORT after $((_pg_max * 2))s (pg_isready never succeeded)."
    exit 1
  fi
  if [ $((_pg_attempt % 15)) -eq 1 ]; then
    echo "cp-clair-db-init: waiting for PostgreSQL at $CLAIR_HOST:$CLAIR_PORT (attempt $_pg_attempt/${_pg_max})..."
  fi
  sleep 2
done
echo "cp-clair-db-init: PostgreSQL is accepting connections."

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
EPASS="$(sql_escape "$CLAIR_PASS")"

PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h "$CLAIR_HOST" -p "$CLAIR_PORT" -U postgres -d postgres \
  -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

if ! PGPASSWORD=postgres psql -h "$CLAIR_HOST" -p "$CLAIR_PORT" -U postgres -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$CLAIR_USER'" | grep -q 1; then
  PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h "$CLAIR_HOST" -p "$CLAIR_PORT" -U postgres -d postgres \
    -c "CREATE USER \"$CLAIR_USER\" CREATEDB;"
fi
PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h "$CLAIR_HOST" -p "$CLAIR_PORT" -U postgres -d postgres \
  -c "ALTER USER \"$CLAIR_USER\" WITH PASSWORD '$EPASS';"

if ! PGPASSWORD=postgres psql -h "$CLAIR_HOST" -p "$CLAIR_PORT" -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$CLAIR_DB'" | grep -q 1; then
  PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h "$CLAIR_HOST" -p "$CLAIR_PORT" -U postgres -d postgres \
    -c "CREATE DATABASE \"$CLAIR_DB\" OWNER \"$CLAIR_USER\";"
fi

PGPASSWORD="$CLAIR_PASS" psql -v ON_ERROR_STOP=1 -h "$CLAIR_HOST" -p "$CLAIR_PORT" -U "$CLAIR_USER" -d "$CLAIR_DB" \
  -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

echo "cp-clair-db-init: done (user=$CLAIR_USER database=$CLAIR_DB)"
