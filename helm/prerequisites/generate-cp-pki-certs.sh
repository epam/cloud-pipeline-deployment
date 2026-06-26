#!/usr/bin/env bash
#
# Generate files for Kubernetes secret cp-pki-secret:
#   ca-private-key.pem, ca-public-cert.pem
#   ssl-private-key.pem, ssl-public-cert.pem
#   sso-private-key.pem, sso-public-cert.pem
#   cp-api-srv-ssl.p12, cp-api-srv-sso.p12
#
# Keys expected by cp-pki-secret (mounted by cp-api-srv, cp-edge, etc.)
#
# Usage:
#   ./generate-cp-pki-certs.sh <api-domain> [deployment-id]
#
# Example:
#   ./generate-cp-pki-certs.sh pipeline.example.com my-namespace
#
# Environment:
#   CERT_DURATION          Validity in days (default: 7300)
#   OUTPUT_DIR             Output directory (default: ./certificates)
#   PKCS12_PASSWORD        Password for .p12 files (default: changeit)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cert-common.sh
source "${SCRIPT_DIR}/lib/cert-common.sh"

if [[ -z "${1:-}" ]]; then
  cert_common_usage "$0 <api-domain> [deployment-id]"
fi

API_DOMAIN="$1"
DEPLOYMENT_ID="${2:-${CP_DEPLOYMENT_ID:-default}}"
CERT_DURATION="${CERT_DURATION:-7300}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/certificates}"
PKCS12_PASSWORD="${PKCS12_PASSWORD:-changeit}"

cert_common_require_command openssl

echo "=========================================="
echo "Generate cp-pki-secret material"
echo "  API domain:      ${API_DOMAIN}"
echo "  deployment id:   ${DEPLOYMENT_ID}"
echo "  cert duration:   ${CERT_DURATION} days"
echo "  output:          ${OUTPUT_DIR}"
echo "=========================================="

cert_common_prepare_output_dir "$OUTPUT_DIR"
# Remove only files produced by this script (shared certificates/ directory).
rm -f \
  ca-private-key.pem ca-public-cert.pem ca-public-cert.srl ca-public-cert.pem.srl \
  ssl-private-key.pem ssl-public-cert.pem ssl-public-cert.csr \
  sso-private-key.pem sso-public-cert.pem \
  cp-api-srv-ssl.p12 cp-api-srv-sso.p12 \
  san.cnf sso.cnf \
  2>/dev/null || true

CA_SUBJECT="/CN=Cloud-Pipeline-${DEPLOYMENT_ID}"

echo "Step 1/4: create CA (${CA_SUBJECT})..."
openssl req -x509 -new -newkey rsa:2048 -nodes \
  -subj "$CA_SUBJECT" \
  -keyout ca-private-key.pem \
  -out ca-public-cert.pem \
  -days "$CERT_DURATION"
chmod 600 ca-private-key.pem
chmod 644 ca-public-cert.pem

echo "Step 2/4: create API TLS certificate for ${API_DOMAIN}..."
openssl genrsa -out ssl-private-key.pem 4096
chmod 600 ssl-private-key.pem
openssl req -new -key ssl-private-key.pem -out ssl-public-cert.csr -subj "/CN=${API_DOMAIN}"

if [[ "$API_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  API_SAN="IP:${API_DOMAIN}"
else
  API_SAN="DNS:${API_DOMAIN},DNS:*.${API_DOMAIN},DNS:docker.${API_DOMAIN}"
fi
cat >san.cnf <<EOF
[v3_req]
subjectAltName=${API_SAN}
EOF

openssl x509 -req -in ssl-public-cert.csr -out ssl-public-cert.pem -days "$CERT_DURATION" \
  -CA ca-public-cert.pem -CAkey ca-private-key.pem -CAcreateserial \
  -extensions v3_req -extfile san.cnf
cat ca-public-cert.pem >>ssl-public-cert.pem
chmod 644 ssl-public-cert.pem
rm -f ssl-public-cert.csr san.cnf

echo "Step 3/4: build cp-api-srv-ssl.p12..."
openssl pkcs12 -export \
  -inkey ssl-private-key.pem \
  -in ssl-public-cert.pem \
  -out cp-api-srv-ssl.p12 \
  -name ssl \
  -passout "pass:${PKCS12_PASSWORD}"
chmod 644 cp-api-srv-ssl.p12

echo "Step 4/4: create SSO certificate for ${API_DOMAIN}..."
openssl genrsa -out sso-private-key.pem 2048
chmod 640 sso-private-key.pem

if openssl req -help 2>&1 | grep -q -- '-addext'; then
  openssl req -x509 -new -key sso-private-key.pem -nodes \
    -subj "/CN=${API_DOMAIN}" \
    -out sso-public-cert.pem \
    -days "$CERT_DURATION" \
    -addext "subjectAltName=DNS:${API_DOMAIN},DNS:*.${API_DOMAIN}" \
    -addext "keyUsage = critical, digitalSignature, keyEncipherment" \
    -addext "extendedKeyUsage = serverAuth, clientAuth"
else
  cat >sso.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${API_DOMAIN}

[v3_req]
subjectAltName = DNS:${API_DOMAIN},DNS:*.${API_DOMAIN}
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF
  openssl req -x509 -new -key sso-private-key.pem -nodes \
    -out sso-public-cert.pem -days "$CERT_DURATION" \
    -config sso.cnf -extensions v3_req
  rm -f sso.cnf
fi
chmod 644 sso-public-cert.pem

openssl pkcs12 -export \
  -inkey sso-private-key.pem \
  -in sso-public-cert.pem \
  -out cp-api-srv-sso.p12 \
  -name sso \
  -passout "pass:${PKCS12_PASSWORD}"
chmod 644 cp-api-srv-sso.p12

echo ""
echo "Done. Files written to: ${OUTPUT_DIR}"
echo "Next: ./create-cp-secrets.sh <namespace>"
