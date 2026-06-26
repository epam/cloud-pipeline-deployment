#!/bin/bash
# Validation for cp-docker-registry release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

ENABLED=$(jq_val 'if .dockerRegistry.enabled == false then "false" else (.dockerRegistry.enabled // true | tostring) end')
[ "$ENABLED" != "true" ] && exit 0

EXTERNAL_HOST=$(jq_val '.dockerRegistry.service.host.external // ""')
[ -z "$EXTERNAL_HOST" ] && add_error "dockerRegistry.service.host.external is required when dockerRegistry.enabled=true"

STORAGE_CONTAINER=$(jq_val '.dockerRegistry.config.CP_DOCKER_STORAGE_CONTAINER // ""')
[ -z "$STORAGE_CONTAINER" ] && add_error "dockerRegistry.config.CP_DOCKER_STORAGE_CONTAINER is required when dockerRegistry.enabled=true"
