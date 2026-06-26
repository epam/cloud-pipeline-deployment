#!/bin/bash
# Validation for cp-edge release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

EDGE_EXTERNAL_HOST=$(jq_val '.edge.service.host.external // ""')
[ -z "$EDGE_EXTERNAL_HOST" ] && add_error "edge.service.host.external is required"
