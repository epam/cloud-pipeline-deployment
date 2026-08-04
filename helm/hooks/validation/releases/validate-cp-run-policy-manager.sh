#!/bin/bash
# Validation for cp-run-policy-manager release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

RPM_ENABLED=$(jq_val '.runPolicyManager.enabled // "false"')
[ "$RPM_ENABLED" != "true" ] && exit 0

POLL_PERIOD=$(jq_val '.runPolicyManager.pollPeriodSec // ""')
if [ -n "$POLL_PERIOD" ] && ! [[ "$POLL_PERIOD" =~ ^[0-9]+$ ]]; then
  add_error "runPolicyManager.pollPeriodSec='$POLL_PERIOD' must be a positive integer"
fi
