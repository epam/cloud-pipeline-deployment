#!/bin/bash
# Helmfile cleanup: block until the Cloud Pipeline API is healthy. Args: NAMESPACE
set -euo pipefail

NAMESPACE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/cloud-pipeline-utils.sh
source "$SCRIPT_DIR/utils/cloud-pipeline-utils.sh"

[ -z "$NAMESPACE" ] && usage

for cmd in kubectl curl jq base64; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

echo "Loading config from cp-config-global (ns=$NAMESPACE)..."
CP_CONFIG_GLOBAL_JSON=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json)
# key filter ensures only valid bash identifiers reach eval; non-conforming keys are skipped
# (e.g. "my.key", "my-key", or "FOO=$(rm -rf /)" would be silently ignored)
eval "$(echo "$CP_CONFIG_GLOBAL_JSON" | jq -r '.data | to_entries[] | select(.value != null and .value != "") | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) | "export \(.key)=\(.value | @sh)"')"

export CP_API_JWT_ADMIN
CP_API_JWT_ADMIN=$(kubectl get secret cp-api-token -n "$NAMESPACE" -o jsonpath='{.data.CP_API_JWT_ADMIN}' | base64 -d)
[ -z "$CP_API_JWT_ADMIN" ] && { echo "ERROR: CP_API_JWT_ADMIN not found in cp-api-token"; exit 1; }

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  validate_api_port "$CP_API_SRV_INTERNAL_PORT" || exit 1
  API_URL="https://${CP_API_SRV_INTERNAL_HOST}:${CP_API_SRV_INTERNAL_PORT}/pipeline/restapi"
else
  validate_api_port "${CP_API_SRV_EXTERNAL_PORT:-}" || exit 1
  API_URL="https://${CP_API_SRV_EXTERNAL_HOST}:${CP_API_SRV_EXTERNAL_PORT}/pipeline/restapi"
fi
echo "API: $API_URL"

api_wait_for_ready 120 10
