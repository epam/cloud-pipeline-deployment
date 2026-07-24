#!/usr/bin/env bash
#
# Restart cp-api-srv and wait for the rollout to complete.
# Called as a postsync hook after all releases (including cp-edge) are synced,
# so cp-api-srv picks up any cp-config-global changes made by cp-edge hooks.
#
# The rolling strategy is terminate-first (maxSurge=0, maxUnavailable=1) because
# hard pod anti-affinity prevents a surge pod from scheduling on a 2-node cluster.
# This means the API is briefly down during restart; this script waits for the new
# pod to become Ready AND for the API to serve authenticated requests before exiting,
# so cleanup hooks see a live API.
#
# Usage: restart-cp-api-srv.sh <namespace>
# Env:   ROLLOUT_TIMEOUT     seconds to wait for rollout (default: 600)
#        API_HEALTH_TIMEOUT  seconds to poll /whoami until healthy (default: 300)
#        KUBECTL             kubectl binary (default: kubectl)
#

set -euo pipefail

NAMESPACE="${1:?namespace required}"
KUBECTL="${KUBECTL:-kubectl}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-600}"
API_HEALTH_TIMEOUT="${API_HEALTH_TIMEOUT:-300}"

echo "Restarting cp-api-srv in namespace ${NAMESPACE} (timeout: ${ROLLOUT_TIMEOUT}s)..."

if ! "$KUBECTL" get deployment/cp-api-srv -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "WARN: deployment/cp-api-srv not found in namespace ${NAMESPACE}, skipping."
  exit 0
fi

"$KUBECTL" rollout restart deployment/cp-api-srv -n "$NAMESPACE"

echo "Waiting for rollout to complete..."
"$KUBECTL" rollout status deployment/cp-api-srv -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s"

echo "Waiting for cp-api-srv pod to be Ready..."
"$KUBECTL" wait pod \
  -n "$NAMESPACE" \
  -l "cloud-pipeline/cp-api-srv=true" \
  --for=condition=Ready \
  --timeout="${ROLLOUT_TIMEOUT}s"

# Build API URL: prefer internal endpoint, fall back to external.
_api_host=$("$KUBECTL" get configmap cp-config-global -n "$NAMESPACE" \
  -o jsonpath='{.data.CP_API_SRV_INTERNAL_HOST}' 2>/dev/null || true)
_api_port=$("$KUBECTL" get configmap cp-config-global -n "$NAMESPACE" \
  -o jsonpath='{.data.CP_API_SRV_INTERNAL_PORT}' 2>/dev/null || true)
if [ -z "$_api_host" ] || [ -z "$_api_port" ]; then
  _api_host=$("$KUBECTL" get configmap cp-config-global -n "$NAMESPACE" \
    -o jsonpath='{.data.CP_API_SRV_EXTERNAL_HOST}' 2>/dev/null || true)
  _api_port=$("$KUBECTL" get configmap cp-config-global -n "$NAMESPACE" \
    -o jsonpath='{.data.CP_API_SRV_EXTERNAL_PORT}' 2>/dev/null || true)
fi

if [ -z "$_api_host" ] || [ -z "$_api_port" ]; then
  echo "WARN: cannot determine API endpoint from cp-config-global, skipping HTTP health check."
  echo "cp-api-srv restarted successfully."
  exit 0
fi

_jwt=$("$KUBECTL" get secret cp-api-token -n "$NAMESPACE" \
  -o jsonpath='{.data.CP_API_JWT_ADMIN}' 2>/dev/null | base64 -d || true)
if [ -z "$_jwt" ]; then
  echo "WARN: CP_API_JWT_ADMIN not found in cp-api-token, skipping HTTP health check."
  echo "cp-api-srv restarted successfully."
  exit 0
fi

_health_url="https://${_api_host}:${_api_port}/pipeline/restapi/whoami"
echo "Polling API health at ${_health_url} (timeout: ${API_HEALTH_TIMEOUT}s)..."
_deadline=$(( $(date +%s) + API_HEALTH_TIMEOUT ))
until _resp=$(curl -k -sS --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${_jwt}" \
    "$_health_url" 2>/dev/null) && \
    echo "$_resp" | grep -q '"status"' && \
    ! echo "$_resp" | grep -q '"status":"ERROR"'; do
  if [ "$(date +%s)" -ge "$_deadline" ]; then
    echo "ERROR: API at ${_health_url} did not respond within ${API_HEALTH_TIMEOUT}s"
    exit 1
  fi
  echo "  API not yet responding, retrying in 10s..."
  sleep 10
done

echo "Verifying all cp-api-srv pods are Ready (all containers up)..."
"$KUBECTL" wait pod \
  -n "$NAMESPACE" \
  -l "cloud-pipeline/cp-api-srv=true" \
  --for=condition=Ready \
  --timeout="${ROLLOUT_TIMEOUT}s"

echo "cp-api-srv restarted and API is responding."
