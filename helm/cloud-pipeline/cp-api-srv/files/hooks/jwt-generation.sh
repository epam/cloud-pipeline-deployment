#!/bin/bash
set -e

echo "Generating JWT token"
CP_DEFAULT_ADMIN_NAME="${CP_DEFAULT_ADMIN_NAME:-pipe_admin}"
CP_API_JWT_ADMIN=$(java -jar /opt/api/jwt-generator.jar --private /opt/api/pki/jwt.key.private --expires 94608000 --claim user_id=1 --claim user_name=$CP_DEFAULT_ADMIN_NAME --claim role=ROLE_ADMIN --claim group=ADMIN 2>/dev/null | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -z "$CP_API_JWT_ADMIN" ]; then
  echo "ERROR: jwt-generator.jar produced an empty token"
  exit 1
fi

echo "Adding JWT token to ${CP_API_TOKEN_SECRET_NAME} secret..."
ESCAPED_JWT=$(printf '%s' "$CP_API_JWT_ADMIN" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
PATCH_BODY="{\"stringData\": {\"CP_API_JWT_ADMIN\": \"$ESCAPED_JWT\"}}"

# This image (cp-api-srv) has no kubectl, and installing it at deploy time needs pkgs.k8s.io,
# which an intercepting proxy can block — patch the secret directly through the in-cluster API
# instead, using the same ServiceAccount token kubectl would have authenticated with.
_sa="/var/run/secrets/kubernetes.io/serviceaccount"
_api="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
curl -sSf --cacert "$_sa/ca.crt" \
  -H "Authorization: Bearer $(cat "$_sa/token")" \
  -H "Content-Type: application/merge-patch+json" \
  -X PATCH --data "$PATCH_BODY" \
  "$_api/api/v1/namespaces/${NAMESPACE}/secrets/${CP_API_TOKEN_SECRET_NAME}"
