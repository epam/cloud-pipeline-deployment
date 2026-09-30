#!/bin/bash
# Validation for the cp-pki-secret prerequisite.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.
# cp-pki-secret must contain per-service certificate pairs (docker-*, edge-*, git-*,
# share-srv-public-cert.pem + cp-share-srv-*.p12); a secret with only ssl-*.pem is missing
# these keys and will cause services to mount the wrong certificate. cp-api-srv (ssl-*.pem) and
# cp-edge (edge-*.pem) are always deployed, so their pairs are always required; docker/git/
# share-srv are optional releases, so their pairs are only required when the corresponding
# service is actually enabled.
# idp-ssl-* is intentionally not checked here: cp-idp uses its own separate secret (cp-idp-secret).
# cp-share-srv-pki-secret has been retired — its former contents now live in cp-pki-secret.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE=$(jq_val '.general.namespace // "default"')

# cp-edge is always deployed (helmfile.yaml.gotmpl has no `installed:` guard for it);
# the other services are optional releases, so only require their cert pairs when enabled.
DOCKER_REGISTRY_ENABLED=$(jq_val '.dockerRegistry.enabled // true')
GIT_ENABLED=$(jq_val '.git.enabled // false')
SHARE_SRV_ENABLED=$(jq_val '.shareSrv.enabled // false')

REQUIRED_PKI_KEYS=(ssl-public-cert.pem ssl-private-key.pem edge-public-cert.pem edge-private-key.pem)
[ "$DOCKER_REGISTRY_ENABLED" = "true" ] && REQUIRED_PKI_KEYS+=(docker-public-cert.pem docker-private-key.pem)
[ "$GIT_ENABLED" = "true" ]             && REQUIRED_PKI_KEYS+=(git-public-cert.pem git-private-key.pem)
[ "$SHARE_SRV_ENABLED" = "true" ]       && REQUIRED_PKI_KEYS+=(share-srv-public-cert.pem cp-share-srv-ssl.p12 cp-share-srv-sso.p12)

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
