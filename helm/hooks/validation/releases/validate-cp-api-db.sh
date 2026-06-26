#!/bin/bash
# Validation for cp-api-db release (db connection settings used by both internal and external db).
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

DB_PASS=$(jq_val '.apiSrv.db.pass // ""')
[ -z "$DB_PASS" ] && add_error "apiSrv.db.pass is required"

DB_PORT=$(jq_val '.apiSrv.db.port // ""')
if [ -n "$DB_PORT" ]; then
  if ! [[ "$DB_PORT" =~ ^[0-9]+$ ]] || [ "$DB_PORT" -lt 1 ] || [ "$DB_PORT" -gt 65535 ]; then
    add_error "apiSrv.db.port='$DB_PORT' is not a valid TCP port (1–65535)"
  fi
fi
