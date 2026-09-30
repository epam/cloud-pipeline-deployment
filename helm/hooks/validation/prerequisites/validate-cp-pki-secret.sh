#!/bin/bash
# Validation for the cp-pki-secret prerequisite.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.
# cp-pki-secret must contain per-service certificate pairs (docker-*, edge-*, git-*, idp-ssl-*,
# share-srv-*); a secret with only ssl-*.pem is missing these keys and will cause services to
# mount the wrong certificate.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE=$(jq_val '.general.namespace // "default"')

# cp-edge is always deployed (helmfile.yaml.gotmpl has no `installed:` guard for it);
# the other services are optional releases, so only require their cert pairs when enabled.
DOCKER_REGISTRY_ENABLED=$(jq_val '.dockerRegistry.enabled // true')
GIT_ENABLED=$(jq_val '.git.enabled // false')
IDP_ENABLED=$(jq_val '.idp.enabled // false')
SHARE_SRV_ENABLED=$(jq_val '.shareSrv.enabled // false')

REQUIRED_PKI_KEYS=(edge-public-cert.pem edge-private-key.pem)
[ "$DOCKER_REGISTRY_ENABLED" = "true" ] && REQUIRED_PKI_KEYS+=(docker-public-cert.pem docker-private-key.pem)
[ "$GIT_ENABLED" = "true" ]             && REQUIRED_PKI_KEYS+=(git-public-cert.pem git-private-key.pem)
[ "$IDP_ENABLED" = "true" ]             && REQUIRED_PKI_KEYS+=(idp-ssl-public-cert.pem idp-ssl-private-key.pem)
[ "$SHARE_SRV_ENABLED" = "true" ]       && REQUIRED_PKI_KEYS+=(share-srv-public-cert.pem share-srv-private-key.pem)

command -v "$KUBECTL" >/dev/null 2>&1 || exit 0

if ! "$KUBECTL" get secret cp-pki-secret -n "$NAMESPACE" >/dev/null 2>&1; then
  add_warning "cp-pki-secret not found in namespace '$NAMESPACE' — deploy will fail without it."
  exit 0
fi

SECRET_KEYS=$("$KUBECTL" get secret cp-pki-secret -n "$NAMESPACE" \
  -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null || true)

MISSING_PKI_KEYS=()
for key in "${REQUIRED_PKI_KEYS[@]}"; do
  printf '%s\n' "$SECRET_KEYS" | grep -qxF "$key" || MISSING_PKI_KEYS+=("$key")
done

if [ ${#MISSING_PKI_KEYS[@]} -gt 0 ]; then
  add_error "cp-pki-secret in namespace '$NAMESPACE' is missing required per-service certificate keys: ${MISSING_PKI_KEYS[*]}. Recreate it: cd helm/prerequisites && ./generate-cp-pki-certs.sh <api-domain> && ./create-cp-secrets.sh $NAMESPACE (or place updated cert files in ./certificates/ then run create-cp-secrets.sh $NAMESPACE)."
fi
