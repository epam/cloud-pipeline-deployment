#!/bin/bash
set -euo pipefail

if kubectl get secret cp-fed-metadata-secret -n "$NAMESPACE" >/dev/null 2>&1; then
  B64CUR=$(kubectl get secret cp-fed-metadata-secret -n "$NAMESPACE" -o jsonpath='{.data.cp-api-srv-fed-meta\.xml}' 2>/dev/null || true)
  if [ -n "${B64CUR:-}" ]; then
    BYTES=$(printf '%s' "$B64CUR" | openssl base64 -d -A 2>/dev/null | wc -c || echo 0)
    if [ "${BYTES:-0}" -gt 64 ]; then
      echo "cp-fed-metadata-secret already populated (${BYTES} bytes decoded), skipping."
      exit 0
    fi
  fi
fi

echo "Downloading IdP metadata from IdP service"
curl -fsSk "https://${CP_IDP_INTERNAL_HOST}:${CP_IDP_INTERNAL_PORT}/metadata" \
  -H "Host: ${CP_IDP_EXTERNAL_HOST}:${CP_IDP_EXTERNAL_PORT}" \
  -o cp-api-srv-fed-meta.xml
test -s cp-api-srv-fed-meta.xml
echo "IdP metadata file ready"

B64=$(openssl base64 -A -in cp-api-srv-fed-meta.xml)
kubectl patch secret cp-fed-metadata-secret \
  -n "$NAMESPACE" \
  --type merge \
  -p "{\"data\":{\"cp-api-srv-fed-meta.xml\":\"${B64}\"}}"
echo "IdP metadata secret patched"
