#!/usr/bin/env bash
#
# Generate files for Kubernetes secret cp-idp-secret:
#   idp-private-key.pem, idp-public-cert.pem
#
# IdP HTTPS also uses ssl-*.pem from cp-pki-secret; generate cp-pki for the same
# external hostname (or include IdP host in API cert SANs) before deploying IdP.
#
# Keys expected by cp-idp-secret
#
# Usage:
#   ./generate-idp-certs.sh <idp-external-host> [idp-internal-host] [namespace]
#
# Example:
#   ./generate-idp-certs.sh idp.pipeline.example.com
#   ./generate-idp-certs.sh idp.pipeline.example.com cp-idp.prod.svc.cluster.local prod
#
# Environment:
#   CERT_DURATION   Validity in days (default: 7300)
#   OUTPUT_DIR      Output directory (default: ./certificates)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cert-common.sh
source "${SCRIPT_DIR}/lib/cert-common.sh"

if [[ -z "${1:-}" ]]; then
  cert_common_usage "$0 <idp-external-host> [idp-internal-host] [namespace]"
fi

IDP_EXTERNAL_HOST="$1"
NAMESPACE="${3:-${NAMESPACE:-default}}"
IDP_INTERNAL_HOST="${2:-$(cert_common_default_idp_internal_host "$NAMESPACE")}"
CERT_DURATION="${CERT_DURATION:-7300}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/certificates}"

OPENSSL_CONFIG="$(cert_common_find_openssl_config)"
SAN_NAMES="$(cert_common_build_san_names "$IDP_EXTERNAL_HOST" "$IDP_INTERNAL_HOST")"

cert_common_require_command openssl

echo "=========================================="
echo "Generate cp-idp-secret material"
echo "  IdP external:  ${IDP_EXTERNAL_HOST}"
echo "  IdP internal:  ${IDP_INTERNAL_HOST}"
echo "  cert duration: ${CERT_DURATION} days"
echo "  output:        ${OUTPUT_DIR}"
echo "  SAN:           ${SAN_NAMES}"
echo "=========================================="

cert_common_prepare_output_dir "$OUTPUT_DIR"
rm -f idp-private-key.pem idp-public-cert.pem idp-req.cnf 2>/dev/null || true

echo "Creating IdP private key..."
openssl genrsa -out idp-private-key.pem 2048
chmod 600 idp-private-key.pem

echo "Creating self-signed IdP certificate..."
if [[ -n "$OPENSSL_CONFIG" ]]; then
  openssl req -x509 -new \
    -key idp-private-key.pem \
    -nodes \
    -subj "/CN=${IDP_EXTERNAL_HOST}" \
    -out idp-public-cert.pem \
    -days "$CERT_DURATION" \
    -reqexts SAN -extensions SAN \
    -config <(cat "$OPENSSL_CONFIG" <(printf '\n[SAN]\nsubjectAltName=%s\n' "$SAN_NAMES"))
else
  cat >idp-req.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${IDP_EXTERNAL_HOST}

[v3_req]
subjectAltName = ${SAN_NAMES}
EOF
  openssl req -x509 -new \
    -key idp-private-key.pem \
    -nodes \
    -subj "/CN=${IDP_EXTERNAL_HOST}" \
    -out idp-public-cert.pem \
    -days "$CERT_DURATION" \
    -config idp-req.cnf \
    -extensions v3_req
  rm -f idp-req.cnf
fi
chmod 644 idp-public-cert.pem

echo ""
echo "Done. Files written to: ${OUTPUT_DIR}"
echo "Next: ./create-cp-secrets.sh <namespace>"
