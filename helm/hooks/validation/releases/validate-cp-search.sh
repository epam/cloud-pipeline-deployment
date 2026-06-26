#!/bin/bash
# Validation for cp-search release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

ENABLED=$(jq_val '.search.enabled // "false"')
[ "$ENABLED" != "true" ] && exit 0

SRV_MODE=$(jq_val '.search.srv.mode // ""')
if [ -n "$SRV_MODE" ] && ! [[ "$SRV_MODE" =~ ^(default|nfsEvents|nfsOnly)$ ]]; then
  add_warning "search.srv.mode='$SRV_MODE' is unrecognised; expected default, nfsEvents, or nfsOnly"
fi
