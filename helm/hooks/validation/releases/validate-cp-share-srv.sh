#!/bin/bash
# Validation for cp-share-srv release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

SHARE_SRV_ENABLED=$(jq_val '.shareSrv.enabled // "false"')
[ "$SHARE_SRV_ENABLED" != "true" ] && exit 0

EXTERNAL_HOST=$(jq_val '.shareSrv.service.host.external // ""')
[ -z "$EXTERNAL_HOST" ] && add_error "shareSrv.service.host.external is required when shareSrv.enabled=true"
