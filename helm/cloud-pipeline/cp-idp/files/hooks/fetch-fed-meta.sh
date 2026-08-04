#!/bin/bash
# Usage: fetch-fed-meta.sh <service-name>
# Fetches IdP federation metadata and patches it into the service's Kubernetes secret.
# Secret naming: <service-name>-fed-metadata-secret, key: <service-name>-fed-meta.xml.
set -euo pipefail

SERVICE="${1:-}"
[ -z "$SERVICE" ] && { echo "ERROR: service name required as first argument"; exit 1; }

NAMESPACE="${NAMESPACE:-default}"

for cmd in kubectl openssl curl; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

[ -z "${CP_IDP_INTERNAL_HOST:-}" ] && { echo "ERROR: CP_IDP_INTERNAL_HOST not set"; exit 1; }
[ -z "${CP_IDP_INTERNAL_PORT:-}" ] && { echo "ERROR: CP_IDP_INTERNAL_PORT not set"; exit 1; }
[ -z "${CP_IDP_EXTERNAL_HOST:-}" ] && { echo "ERROR: CP_IDP_EXTERNAL_HOST not set"; exit 1; }
[ -z "${CP_IDP_EXTERNAL_PORT:-}" ] && { echo "ERROR: CP_IDP_EXTERNAL_PORT not set"; exit 1; }

SECRET_NAME="${SERVICE}-fed-metadata-secret"
SECRET_KEY="${SERVICE}-fed-meta.xml"
JSONPATH_KEY="${SECRET_KEY/./\\.}"

B64CUR=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" \
  -o "jsonpath={.data.${JSONPATH_KEY}}" 2>/dev/null || true)
BYTES=0
if [ -n "${B64CUR:-}" ]; then
  BYTES=$(printf '%s' "$B64CUR" | openssl base64 -d -A 2>/dev/null | wc -c || echo 0)
fi
if [ "${BYTES:-0}" -gt 64 ]; then
  echo "${SECRET_KEY} already populated in ${SECRET_NAME} (${BYTES} bytes), skipping."
  exit 0
fi

LOCAL_FILE="${SERVICE}-fed-meta.xml"
echo "Downloading IdP metadata from https://${CP_IDP_INTERNAL_HOST}:${CP_IDP_INTERNAL_PORT}/metadata ..."
curl -fsSk \
  "https://${CP_IDP_INTERNAL_HOST}:${CP_IDP_INTERNAL_PORT}/metadata" \
  -H "Host: ${CP_IDP_EXTERNAL_HOST}:${CP_IDP_EXTERNAL_PORT}" \
  -o "$LOCAL_FILE"
test -s "$LOCAL_FILE" || { echo "ERROR: empty metadata response from IdP"; exit 1; }

B64=$(openssl base64 -A -in "$LOCAL_FILE")
kubectl patch secret "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --type merge \
  -p "{\"data\":{\"${SECRET_KEY}\":\"${B64}\"}}"
echo "${SECRET_KEY} patched into ${SECRET_NAME}."
