#!/usr/bin/env bash
#
# Generate files for Kubernetes secret cp-pki-secret:
#   ca-private-key.pem, ca-public-cert.pem
#   ssl-private-key.pem, ssl-public-cert.pem              (cp-api-srv TLS)
#   edge-private-key.pem, edge-public-cert.pem            (cp-edge TLS)
#   docker-private-key.pem, docker-public-cert.pem        (cp-docker-registry TLS)
#   git-private-key.pem, git-public-cert.pem              (cp-git / GitLab TLS)
#   share-srv-public-cert.pem                              (cp-share-srv TLS; private key is not stored, only used to build the p12 below)
#   sso-private-key.pem, sso-public-cert.pem
#   cp-api-srv-ssl.p12, cp-api-srv-sso.p12
#   cp-share-srv-ssl.p12, cp-share-srv-sso.p12
#
# Self-signed mode (default):
#   ./generate-cp-pki-certs.sh <api-domain> [deployment-id]
#
# Wildcard / import mode — provide one certificate that covers all services
# (e.g. a wildcard cert *.example.com or a multi-SAN cert from Let's Encrypt):
#   TLS_CERT=/etc/letsencrypt/live/example.com/fullchain.pem \
#   TLS_KEY=/etc/letsencrypt/live/example.com/privkey.pem \
#   ./generate-cp-pki-certs.sh [api-domain] [deployment-id]
#
#   The script copies the provided certificate to all per-service pairs
#   (ssl, docker, edge, git, share-srv) and builds all required .p12 files automatically.
#
#   api-domain is optional in import mode; derived from the certificate CN
#   when omitted. EC keys (e.g. Let's Encrypt P-256) are supported — RSA SSO
#   material is auto-generated since cp-idp requires RSA for SAML signing.
#
# Per-service certificates (optional import mode):
#   Set service-specific TLS_CERT/TLS_KEY pairs to use separate certificates
#   for each service. When unset, each service falls back to ssl-*.pem.
#   DOCKER_TLS_CERT / DOCKER_TLS_KEY       — cp-docker-registry certificate
#   EDGE_TLS_CERT / EDGE_TLS_KEY           — cp-edge certificate
#   GIT_TLS_CERT / GIT_TLS_KEY             — cp-git / GitLab certificate
#   SHARE_SRV_TLS_CERT / SHARE_SRV_TLS_KEY — cp-share-srv certificate
#
# Environment:
#   TLS_CERT              Path to fullchain.pem (enables import mode)
#   TLS_KEY               Path to privkey.pem   (enables import mode)
#   DOCKER_TLS_CERT       Path to docker-registry fullchain.pem (optional)
#   DOCKER_TLS_KEY        Path to docker-registry privkey.pem   (optional)
#   EDGE_TLS_CERT         Path to cp-edge fullchain.pem (optional)
#   EDGE_TLS_KEY          Path to cp-edge privkey.pem   (optional)
#   GIT_TLS_CERT          Path to git/GitLab fullchain.pem (optional)
#   GIT_TLS_KEY           Path to git/GitLab privkey.pem   (optional)
#   SHARE_SRV_TLS_CERT    Path to share-srv fullchain.pem (optional)
#   SHARE_SRV_TLS_KEY     Path to share-srv privkey.pem   (optional)
#   CERT_DURATION         Validity in days for generated certs (default: 7300)
#   OUTPUT_DIR            Output directory (default: ./certificates)
#   PKCS12_PASSWORD       Password for .p12 files (default: changeit)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cert-common.sh
source "${SCRIPT_DIR}/lib/cert-common.sh"

# ── determine mode ────────────────────────────────────────────────────────────
IMPORT_MODE=false
if [[ -n "${TLS_CERT:-}" && -n "${TLS_KEY:-}" ]]; then
  IMPORT_MODE=true
fi

# ── argument handling ─────────────────────────────────────────────────────────
if [[ "$IMPORT_MODE" == "false" && -z "${1:-}" ]]; then
  cert_common_usage \
    "$0 <api-domain> [deployment-id]
Import mode: TLS_CERT=<fullchain.pem> TLS_KEY=<privkey.pem> $0 [api-domain] [deployment-id]"
fi

CERT_DURATION="${CERT_DURATION:-7300}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/certificates}"
PKCS12_PASSWORD="${PKCS12_PASSWORD:-changeit}"

cert_common_require_command openssl

# ── helpers (used in import mode) ─────────────────────────────────────────────
_key_alg() {
  if openssl rsa -in "$1" -check -noout 2>/dev/null; then echo rsa
  elif openssl ec -in "$1" -check -noout 2>/dev/null; then echo ec
  else echo unknown; fi
}

_cert_cn() {
  openssl x509 -in "$1" -noout -subject -nameopt sep_multiline 2>/dev/null \
    | sed -n 's/^ *CN=//p' | head -1 | tr -d '\r'
}

_cert_san() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | tail -n +2 | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ── resolve variables ─────────────────────────────────────────────────────────
if [[ "$IMPORT_MODE" == "true" ]]; then
  TLS_CERT="$(cd "$(dirname "$TLS_CERT")" && pwd)/$(basename "$TLS_CERT")"
  TLS_KEY="$(cd "$(dirname "$TLS_KEY")" && pwd)/$(basename "$TLS_KEY")"
  [[ -f "$TLS_CERT" ]] || { echo "ERROR: TLS_CERT not found: $TLS_CERT" >&2; exit 1; }
  [[ -f "$TLS_KEY"  ]] || { echo "ERROR: TLS_KEY not found: $TLS_KEY" >&2; exit 1; }
  CERT_CN="$(_cert_cn "$TLS_CERT")"
  API_DOMAIN="${1:-${CERT_CN}}"
  [[ -n "$API_DOMAIN" ]] || { echo "ERROR: api-domain not provided and cannot be read from certificate CN" >&2; exit 1; }
  KEY_ALG="$(_key_alg "$TLS_KEY")"
  [[ "$KEY_ALG" != "unknown" ]] || { echo "ERROR: could not detect TLS key type" >&2; exit 1; }
else
  API_DOMAIN="$1"
fi

DEPLOYMENT_ID="${2:-${CP_DEPLOYMENT_ID:-default}}"

# ── banner ────────────────────────────────────────────────────────────────────
if [[ "$IMPORT_MODE" == "true" ]]; then
  echo "=========================================="
  echo "Generate cp-pki-secret material (wildcard / import mode)"
  echo "  API domain:      ${API_DOMAIN}"
  echo "  key type:        ${KEY_ALG}"
  echo "  deployment id:   ${DEPLOYMENT_ID}"
  echo "  cert duration:   ${CERT_DURATION} days (generated certs only)"
  echo "  output:          ${OUTPUT_DIR}"
  echo "=========================================="
else
  echo "=========================================="
  echo "Generate cp-pki-secret material (self-signed)"
  echo "  API domain:      ${API_DOMAIN}"
  echo "  deployment id:   ${DEPLOYMENT_ID}"
  echo "  cert duration:   ${CERT_DURATION} days"
  echo "  output:          ${OUTPUT_DIR}"
  echo "=========================================="
fi

cert_common_prepare_output_dir "$OUTPUT_DIR"
rm -f \
  ca-private-key.pem ca-public-cert.pem ca-public-cert.srl ca-public-cert.pem.srl \
  ssl-private-key.pem ssl-public-cert.pem ssl-public-cert.csr \
  docker-private-key.pem docker-public-cert.pem \
  edge-private-key.pem edge-public-cert.pem \
  git-private-key.pem git-public-cert.pem \
  share-srv-private-key.pem share-srv-public-cert.pem \
  sso-private-key.pem sso-public-cert.pem \
  cp-api-srv-ssl.p12 cp-api-srv-sso.p12 \
  cp-share-srv-ssl.p12 cp-share-srv-sso.p12 \
  san.cnf sso.cnf \
  2>/dev/null || true

CA_SUBJECT="/CN=Cloud-Pipeline-${DEPLOYMENT_ID}"

# ── Step 1: internal CA ───────────────────────────────────────────────────────
echo "Step 1/6: create internal CA (${CA_SUBJECT})..."
openssl req -x509 -new -newkey rsa:2048 -nodes \
  -subj "$CA_SUBJECT" \
  -keyout ca-private-key.pem \
  -out ca-public-cert.pem \
  -days "$CERT_DURATION"
chmod 600 ca-private-key.pem
chmod 644 ca-public-cert.pem

# ── Step 2: API TLS certificate ───────────────────────────────────────────────
if [[ "$IMPORT_MODE" == "true" ]]; then
  echo "Step 2/6: import TLS certificate (will be applied to all services)..."
  cp -f "$TLS_CERT" ssl-public-cert.pem; chmod 644 ssl-public-cert.pem
  cp -f "$TLS_KEY"  ssl-private-key.pem; chmod 600 ssl-private-key.pem
else
  echo "Step 2/6: create API TLS certificate for ${API_DOMAIN}..."
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
fi

# ── Step 3: per-service certificate copies ────────────────────────────────────
echo "Step 3/6: create per-service certificate files (docker, edge, git, share-srv)..."

_copy_service_cert() {
  local name="$1" pub="$2" priv="$3" src_cert="${4:-}" src_key="${5:-}"
  if [[ -n "$src_cert" && -n "$src_key" ]]; then
    echo "  ${name}: importing separate certificate"
    cp -f "$src_cert" "$pub"; chmod 644 "$pub"
    cp -f "$src_key"  "$priv"; chmod 600 "$priv"
  else
    echo "  ${name}: copying from ssl-*.pem (wildcard fallback)"
    cp ssl-public-cert.pem "$pub"; chmod 644 "$pub"
    cp ssl-private-key.pem "$priv"; chmod 600 "$priv"
  fi
}

_copy_service_cert "docker-registry" docker-public-cert.pem docker-private-key.pem \
  "${DOCKER_TLS_CERT:-}" "${DOCKER_TLS_KEY:-}"
_copy_service_cert "edge" edge-public-cert.pem edge-private-key.pem \
  "${EDGE_TLS_CERT:-}" "${EDGE_TLS_KEY:-}"
_copy_service_cert "git" git-public-cert.pem git-private-key.pem \
  "${GIT_TLS_CERT:-}" "${GIT_TLS_KEY:-}"
_copy_service_cert "share-srv" share-srv-public-cert.pem share-srv-private-key.pem \
  "${SHARE_SRV_TLS_CERT:-}" "${SHARE_SRV_TLS_KEY:-}"

# ── Step 4: ssl.p12 ───────────────────────────────────────────────────────────
echo "Step 4/6: build cp-api-srv-ssl.p12 and cp-share-srv-ssl.p12..."
openssl pkcs12 -export \
  -inkey ssl-private-key.pem \
  -in ssl-public-cert.pem \
  -out cp-api-srv-ssl.p12 \
  -name ssl \
  -passout "pass:${PKCS12_PASSWORD}"
chmod 644 cp-api-srv-ssl.p12
openssl pkcs12 -export \
  -inkey share-srv-private-key.pem \
  -in share-srv-public-cert.pem \
  -out cp-share-srv-ssl.p12 \
  -name ssl \
  -passout "pass:${PKCS12_PASSWORD}"
chmod 644 cp-share-srv-ssl.p12

# ── Step 5: SSO certificate ───────────────────────────────────────────────────
echo "Step 5/6: prepare SSO certificate (RSA required for SAML)..."
if [[ "$IMPORT_MODE" == "true" && "$KEY_ALG" == "rsa" ]]; then
  echo "  TLS key is RSA: reusing for SSO"
  cp ssl-public-cert.pem sso-public-cert.pem; chmod 644 sso-public-cert.pem
  cp ssl-private-key.pem sso-private-key.pem; chmod 640 sso-private-key.pem
else
  if [[ "$IMPORT_MODE" == "true" ]]; then
    SSO_CN="$(_cert_cn "$TLS_CERT")"; [[ -z "$SSO_CN" ]] && SSO_CN="cloud-pipeline-sso"
    SSO_SAN="$(_cert_san "$TLS_CERT")"; [[ -z "$SSO_SAN" ]] && SSO_SAN="DNS:${SSO_CN}"
    echo "  TLS key is EC: generating RSA 2048 SSO cert (SAN: ${SSO_SAN})"
  else
    SSO_CN="${API_DOMAIN}"
    SSO_SAN="DNS:${API_DOMAIN},DNS:*.${API_DOMAIN}"
    echo "  Generating RSA 2048 SSO cert"
  fi

  openssl genrsa -out sso-private-key.pem 2048
  chmod 640 sso-private-key.pem

  if openssl req -help 2>&1 | grep -q -- '-addext'; then
    openssl req -x509 -new -key sso-private-key.pem -nodes \
      -subj "/CN=${SSO_CN}" \
      -out sso-public-cert.pem \
      -days "$CERT_DURATION" \
      -addext "subjectAltName=${SSO_SAN}" \
      -addext "keyUsage = critical, digitalSignature, keyEncipherment" \
      -addext "extendedKeyUsage = serverAuth, clientAuth"
  else
    cat >sso.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = ${SSO_CN}

[v3_req]
subjectAltName = ${SSO_SAN}
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF
    openssl req -x509 -new -key sso-private-key.pem -nodes \
      -out sso-public-cert.pem -days "$CERT_DURATION" \
      -config sso.cnf -extensions v3_req
    rm -f sso.cnf
  fi
  chmod 644 sso-public-cert.pem
fi

# ── Step 6: sso.p12 ───────────────────────────────────────────────────────────
echo "Step 6/6: build cp-api-srv-sso.p12 and cp-share-srv-sso.p12..."
openssl pkcs12 -export \
  -inkey sso-private-key.pem \
  -in sso-public-cert.pem \
  -out cp-api-srv-sso.p12 \
  -name sso \
  -passout "pass:${PKCS12_PASSWORD}"
chmod 644 cp-api-srv-sso.p12
openssl pkcs12 -export \
  -inkey sso-private-key.pem \
  -in sso-public-cert.pem \
  -out cp-share-srv-sso.p12 \
  -name sso \
  -passout "pass:${PKCS12_PASSWORD}"
chmod 644 cp-share-srv-sso.p12

echo ""
echo "Done. Files written to: ${OUTPUT_DIR}"
echo "Next: ./create-cp-secrets.sh <namespace>"
