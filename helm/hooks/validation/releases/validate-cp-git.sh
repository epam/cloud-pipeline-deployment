#!/bin/bash
# Validation for cp-git release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

GIT_ENABLED=$(jq_val '.git.enabled // "false"')
[ "$GIT_ENABLED" != "true" ] && exit 0

GIT_EXTERNAL_HOST=$(jq_val '.git.service.host.external // ""')
[ -z "$GIT_EXTERNAL_HOST" ] && add_error "git.service.host.external is required when git.enabled=true"
