#!/bin/bash
# Validation for cp-idp release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

IDP_ENABLED=$(jq_val '.idp.enabled // "false"')
[ "$IDP_ENABLED" != "true" ] && exit 0

IDP_EXTERNAL_HOST=$(jq_val '.idp.service.host.external // ""')
[ -z "$IDP_EXTERNAL_HOST" ] && add_error "idp.service.host.external is required when idp.enabled=true"
