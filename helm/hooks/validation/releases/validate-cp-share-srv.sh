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

# Required secrets
NAMESPACE=$(jq_val '.general.namespace // "default"')
IDP_ENABLED=$(jq_val '.idp.enabled // false')

# When idp.enabled=true cp-share-srv-fed-metadata-secret is created by the cp-idp Helm hook at deploy time.
if [ "$IDP_ENABLED" != "true" ]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    add_warning "kubectl not found — cannot verify required secrets in namespace '$NAMESPACE'"
  elif ! kubectl cluster-info >/dev/null 2>&1; then
    add_warning "kubectl cannot reach cluster — cannot verify required secrets in namespace '$NAMESPACE'"
  else
    kubectl get secret "cp-share-srv-fed-metadata-secret" -n "$NAMESPACE" >/dev/null 2>&1 || \
      add_error "required secret 'cp-share-srv-fed-metadata-secret' not found in namespace '$NAMESPACE' — see prerequisites docs"
  fi
fi
