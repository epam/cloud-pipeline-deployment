#!/bin/bash
# Helm pre-install/pre-upgrade Job: add cp-share-srv-fed-meta.xml to cp-share-srv-fed-metadata-secret.
# First tries to copy cp-api-srv-fed-meta.xml from cp-fed-metadata-secret (already fetched by cp-idp).
# Falls back to fetching directly from the IdP if that key is empty.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

for cmd in kubectl openssl; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

# Idempotency: skip if already populated
B64CUR=$(kubectl get secret cp-share-srv-fed-metadata-secret -n "$NAMESPACE" \
  -o jsonpath='{.data.cp-share-srv-fed-meta\.xml}' 2>/dev/null || true)
if [ -n "${B64CUR:-}" ]; then
  BYTES=$(printf '%s' "$B64CUR" | openssl base64 -d -A 2>/dev/null | wc -c || echo 0)
  if [ "${BYTES:-0}" -gt 64 ]; then
    echo "cp-share-srv-fed-meta.xml already populated (${BYTES} bytes), skipping."
    exit 0
  fi
fi

# Try to reuse cp-api-srv-fed-meta.xml from the same secret (populated by cp-idp)
B64=$(kubectl get secret cp-fed-metadata-secret -n "$NAMESPACE" \
  -o jsonpath='{.data.cp-api-srv-fed-meta\.xml}' 2>/dev/null || true)
BYTES=0
if [ -n "${B64:-}" ]; then
  BYTES=$(printf '%s' "$B64" | openssl base64 -d -A 2>/dev/null | wc -c || echo 0)
fi

if [ "${BYTES:-0}" -gt 64 ]; then
  echo "Reusing cp-api-srv-fed-meta.xml from cp-fed-metadata-secret (${BYTES} bytes)."
else
  # Fall back: fetch directly from IdP
  command -v curl >/dev/null || { echo "ERROR: curl required but not installed"; exit 1; }
  [ -z "${CP_IDP_INTERNAL_HOST:-}" ] && { echo "ERROR: CP_IDP_INTERNAL_HOST not set"; exit 1; }
  [ -z "${CP_IDP_INTERNAL_PORT:-}" ] && { echo "ERROR: CP_IDP_INTERNAL_PORT not set"; exit 1; }
  [ -z "${CP_IDP_EXTERNAL_HOST:-}" ] && { echo "ERROR: CP_IDP_EXTERNAL_HOST not set"; exit 1; }
  [ -z "${CP_IDP_EXTERNAL_PORT:-}" ] && { echo "ERROR: CP_IDP_EXTERNAL_PORT not set"; exit 1; }

  echo "Fetching IdP metadata from https://${CP_IDP_INTERNAL_HOST}:${CP_IDP_INTERNAL_PORT}/metadata ..."
  curl -fsSk \
    "https://${CP_IDP_INTERNAL_HOST}:${CP_IDP_INTERNAL_PORT}/metadata" \
    -H "Host: ${CP_IDP_EXTERNAL_HOST}:${CP_IDP_EXTERNAL_PORT}" \
    -o cp-share-srv-fed-meta.xml
  test -s cp-share-srv-fed-meta.xml || { echo "ERROR: Empty metadata response from IdP"; exit 1; }
  B64=$(openssl base64 -A -in cp-share-srv-fed-meta.xml)
fi

kubectl patch secret cp-share-srv-fed-metadata-secret \
  -n "$NAMESPACE" \
  --type merge \
  -p "{\"data\":{\"cp-share-srv-fed-meta.xml\":\"${B64}\"}}"
echo "cp-share-srv-fed-meta.xml patched into cp-share-srv-fed-metadata-secret."
