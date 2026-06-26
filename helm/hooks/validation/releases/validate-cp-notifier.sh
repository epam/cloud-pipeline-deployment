#!/bin/bash
# Validation for cp-notifier release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

NOTIFIER_ENABLED=$(jq_val '.notifier.enabled // "false"')
[ "$NOTIFIER_ENABLED" != "true" ] && exit 0

SMTP_ENABLED=$(jq_val '.notifier.smtp.enabled // "false"')
if [ "$SMTP_ENABLED" = "true" ]; then
  SMTP_HOST=$(jq_val '.notifier.smtp.server.host // ""')
  SMTP_PORT=$(jq_val '.notifier.smtp.server.port // ""')
  [ -z "$SMTP_HOST" ] && add_error "notifier.smtp.server.host is required when notifier.smtp.enabled=true"
  if [ -z "$SMTP_PORT" ]; then
    add_error "notifier.smtp.server.port is required when notifier.smtp.enabled=true"
  elif ! [[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || [ "$SMTP_PORT" -lt 1 ] || [ "$SMTP_PORT" -gt 65535 ]; then
    add_error "notifier.smtp.server.port='$SMTP_PORT' is not a valid TCP port (1–65535)"
  fi
fi

AZURE_ENABLED=$(jq_val '.notifier.azure.enabled // "false"')
if [ "$AZURE_ENABLED" = "true" ]; then
  AZURE_TENANT=$(jq_val '.notifier.azure.tenantId // ""')
  AZURE_CLIENT=$(jq_val '.notifier.azure.clientId // ""')
  AZURE_SECRET=$(jq_val '.notifier.azure.clientSecret // ""')
  [ -z "$AZURE_TENANT" ] && add_error "notifier.azure.tenantId is required when notifier.azure.enabled=true"
  [ -z "$AZURE_CLIENT" ] && add_error "notifier.azure.clientId is required when notifier.azure.enabled=true"
  [ -z "$AZURE_SECRET" ] && add_error "notifier.azure.clientSecret is required when notifier.azure.enabled=true"
fi
