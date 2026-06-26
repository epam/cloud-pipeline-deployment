#!/usr/bin/env bash
#
# Generate files for Kubernetes secret cp-jwt-pki-secret:
#   jwt.key.private, jwt.key.public, jwt.key.x509
#
# Keys expected by cp-jwt-pki-secret
#
# Usage:
#   ./generate-cp-jwt-pki-certs.sh
#
# Environment:
#   CERT_DURATION   Validity in days for jwt.key.x509 (default: 7300)
#   OUTPUT_DIR      Output directory (default: ./certificates)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cert-common.sh
source "${SCRIPT_DIR}/lib/cert-common.sh"

CERT_DURATION="${CERT_DURATION:-7300}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/certificates}"
JWT_SUBJECT="/CN=Cloud-Pipeline-JWT"

cert_common_require_command openssl

echo "=========================================="
echo "Generate cp-jwt-pki-secret material"
echo "  cert duration: ${CERT_DURATION} days"
echo "  output:        ${OUTPUT_DIR}"
echo "=========================================="

cert_common_prepare_output_dir "$OUTPUT_DIR"
rm -f jwt.key.private jwt.key.public jwt.key.x509 jwt.key.x509.pem jwt.key.private.tmp jwt.key.public.tmp 2>/dev/null || true

echo "Creating RSA key pair..."
if openssl genpkey -algorithm RSA -out jwt.key.private.tmp -pkeyopt rsa_keygen_bits:1024 2>/dev/null; then
  :
else
  openssl genrsa -out jwt.key.private.tmp 1024
fi

openssl rsa -pubout -in jwt.key.private.tmp -out jwt.key.public.tmp

echo "Creating X.509 certificate (${JWT_SUBJECT})..."
openssl req -new -x509 \
  -key jwt.key.private.tmp \
  -sha256 -nodes \
  -out jwt.key.x509.pem \
  -days "$CERT_DURATION" \
  -subj "$JWT_SUBJECT"

# API expects base64-like single-line key material (no PEM headers).
sed '$d' <jwt.key.private.tmp | sed '1d' | tr -d '\n' >jwt.key.private
sed '$d' <jwt.key.public.tmp | sed '1d' | tr -d '\n' >jwt.key.public
cp jwt.key.x509.pem jwt.key.x509

chmod 600 jwt.key.private
chmod 644 jwt.key.public jwt.key.x509 jwt.key.x509.pem
rm -f jwt.key.private.tmp jwt.key.public.tmp

echo ""
echo "Done. Files written to: ${OUTPUT_DIR}"
echo "Next: ./create-cp-secrets.sh <namespace>"
