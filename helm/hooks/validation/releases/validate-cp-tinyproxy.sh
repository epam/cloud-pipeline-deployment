#!/bin/bash
# Validation for cp-tinyproxy release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

TP_ENABLED=$(jq_val '.tinyproxy.enabled // "true"')
[ "$TP_ENABLED" != "true" ] && exit 0

for field in CP_TP_MAX_CLIENTS CP_TP_TIMEOUT; do
  VALUE=$(jq_val ".tinyproxy.config.${field} // \"\"")
  if [ -n "$VALUE" ] && ! [[ "$VALUE" =~ ^[0-9]+$ ]]; then
    add_error "tinyproxy.config.${field}='$VALUE' must be a positive integer"
  fi
done

for field in CP_TP_HTTP_PROXY_ENABLED CP_TP_STREAM_PROXY_ENABLED; do
  VALUE=$(jq_val ".tinyproxy.config.${field} // \"\"")
  if [ -n "$VALUE" ] && [ "$VALUE" != "true" ] && [ "$VALUE" != "false" ]; then
    add_error "tinyproxy.config.${field}='$VALUE' must be 'true' or 'false'"
  fi
done

ALLOWED_DEST=$(jq_val '.tinyproxy.config.CP_TP_ALLOWED_DESTINATION // ""')
RESTRICTED_DEST=$(jq_val '.tinyproxy.config.CP_TP_RESTRICTED_DESTINATION // ""')
if [ -n "$ALLOWED_DEST" ] && [ -n "$RESTRICTED_DEST" ]; then
  add_error "tinyproxy.config: set only one of CP_TP_ALLOWED_DESTINATION / CP_TP_RESTRICTED_DESTINATION (allowlist wins over denylist, the other is ignored)"
fi
