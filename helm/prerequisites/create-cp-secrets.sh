#!/usr/bin/env bash
#
# Create Cloud Pipeline PKI secrets from generated certificate files.
#
# Usage:
#   ./create-cp-secrets.sh <namespace> [assets-directory]
#
# Example:
#   ./create-cp-secrets.sh cloud-pipeline ./certificates
#
# Run generate scripts first:
#   ./generate-cp-pki-certs.sh <api-domain> [deployment-id]
#   ./generate-cp-jwt-pki-certs.sh
#   ./generate-idp-certs.sh <idp-external-host> [idp-internal-host] [namespace]
#
# Registry TLS uses cp-pki-secret (ssl-*.pem); no separate docker-registry secret.
#
# Environment:
#   KUBECTL           kubectl binary (default: kubectl)
#   REPLACE_SECRET    When "true", delete existing secrets first (default: true)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cert-common.sh
source "${SCRIPT_DIR}/lib/cert-common.sh"

if [[ -z "${1:-}" ]]; then
  cert_common_usage "$0 <namespace> [assets-directory]"
fi

NAMESPACE="$1"
ASSETS_DIR="${2:-${SCRIPT_DIR}/certificates}"
KUBECTL="${KUBECTL:-kubectl}"
REPLACE_SECRET="${REPLACE_SECRET:-true}"

cert_common_require_command "$KUBECTL"

cert_common_require_files() {
  local label="$1"
  shift
  for file_name in "$@"; do
    if [[ ! -f "${ASSETS_DIR}/${file_name}" ]]; then
      echo "ERROR: missing file: ${ASSETS_DIR}/${file_name}" >&2
      echo "Run the generate scripts first (${label})." >&2
      exit 1
    fi
  done
}

cert_common_delete_secret_if_needed() {
  local secret_name="$1"
  if [[ "$REPLACE_SECRET" == "true" ]]; then
    "$KUBECTL" delete secret "$secret_name" -n "$NAMESPACE" --ignore-not-found=true
  fi
}

echo "Creating Cloud Pipeline secrets in namespace ${NAMESPACE}..."
echo "  assets: ${ASSETS_DIR}"

# cp-pki-secret
CP_PKI_FILES=(
  ca-private-key.pem
  ca-public-cert.pem
  ssl-private-key.pem
  ssl-public-cert.pem
  sso-private-key.pem
  sso-public-cert.pem
  cp-api-srv-ssl.p12
  cp-api-srv-sso.p12
)
cert_common_require_files "generate-cp-pki-certs.sh" "${CP_PKI_FILES[@]}"
echo "==> cp-pki-secret"
cert_common_delete_secret_if_needed cp-pki-secret
"$KUBECTL" create secret generic cp-pki-secret -n "$NAMESPACE" \
  --from-file="${ASSETS_DIR}/ca-private-key.pem" \
  --from-file="${ASSETS_DIR}/ca-public-cert.pem" \
  --from-file="${ASSETS_DIR}/ssl-private-key.pem" \
  --from-file="${ASSETS_DIR}/ssl-public-cert.pem" \
  --from-file="${ASSETS_DIR}/sso-private-key.pem" \
  --from-file="${ASSETS_DIR}/sso-public-cert.pem" \
  --from-file="${ASSETS_DIR}/cp-api-srv-ssl.p12" \
  --from-file="${ASSETS_DIR}/cp-api-srv-sso.p12"

# cp-jwt-pki-secret
JWT_FILES=(jwt.key.private jwt.key.public jwt.key.x509)
cert_common_require_files "generate-cp-jwt-pki-certs.sh" "${JWT_FILES[@]}"
echo "==> cp-jwt-pki-secret"
cert_common_delete_secret_if_needed cp-jwt-pki-secret
"$KUBECTL" create secret generic cp-jwt-pki-secret -n "$NAMESPACE" \
  --from-file=jwt.key.private="${ASSETS_DIR}/jwt.key.private" \
  --from-file=jwt.key.public="${ASSETS_DIR}/jwt.key.public" \
  --from-file=jwt.key.x509="${ASSETS_DIR}/jwt.key.x509"

# cp-idp-secret
IDP_FILES=(idp-private-key.pem idp-public-cert.pem)
cert_common_require_files "generate-idp-certs.sh" "${IDP_FILES[@]}"
echo "==> cp-idp-secret"
cert_common_delete_secret_if_needed cp-idp-secret
"$KUBECTL" create secret generic cp-idp-secret -n "$NAMESPACE" \
  --from-file="${ASSETS_DIR}/idp-private-key.pem" \
  --from-file="${ASSETS_DIR}/idp-public-cert.pem"

echo "Done. Secrets cp-pki-secret, cp-jwt-pki-secret, and cp-idp-secret are ready in namespace ${NAMESPACE}."
