#!/bin/bash
# Helm post-install/post-upgrade Job: register data.sharing.base.api preference via API.
set -euo pipefail

# shellcheck source=cloud-pipeline-utils.sh
source /scripts/cloud-pipeline-utils.sh

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

[ -z "${CP_API_JWT_ADMIN:-}" ] && { echo "ERROR: CP_API_JWT_ADMIN not found in cp-api-token"; exit 1; }
[ -z "${CP_SHARE_SRV_EXTERNAL_HOST:-}" ] && { echo "ERROR: CP_SHARE_SRV_EXTERNAL_HOST not set in cp-config-global"; exit 1; }
[ -z "${CP_SHARE_SRV_EXTERNAL_PORT:-}" ] && { echo "ERROR: CP_SHARE_SRV_EXTERNAL_PORT not set in cp-config-global"; exit 1; }

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  API_CONNECT_HOST="$CP_API_SRV_INTERNAL_HOST"
  API_CONNECT_PORT="$CP_API_SRV_INTERNAL_PORT"
else
  API_CONNECT_HOST="${CP_API_SRV_EXTERNAL_HOST:-}"
  API_CONNECT_PORT="${CP_API_SRV_EXTERNAL_PORT:-}"
fi
[ -z "$API_CONNECT_HOST" ] || [ -z "$API_CONNECT_PORT" ] && { echo "Missing API endpoint (internal or external host/port)"; exit 1; }

API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API: $API_URL"

PREF_VALUE="https://${CP_SHARE_SRV_EXTERNAL_HOST}:${CP_SHARE_SRV_EXTERNAL_PORT}/proxy/?id=%d"
echo "Setting preference data.sharing.base.api=${PREF_VALUE}"
api_set_preference "data.sharing.base.api" "$PREF_VALUE" "false"
echo "data.sharing.base.api preference set successfully."

[ -z "${CP_SHARE_SRV_SHARED_STORAGE_NAME:-}" ] && { echo "ERROR: CP_SHARE_SRV_SHARED_STORAGE_NAME not set"; exit 1; }
SHARED_STORAGE_NAME="$CP_SHARE_SRV_SHARED_STORAGE_NAME"
echo "Creating/locating shared storage directory: ${SHARED_STORAGE_NAME}"
SHARED_STORAGE_ID=$(api_get_entity_id "$SHARED_STORAGE_NAME" "folder") || SHARED_STORAGE_ID=$(api_create_folder "$SHARED_STORAGE_NAME")
[ -z "${SHARED_STORAGE_ID:-}" ] && { echo "ERROR: could not create or find folder '${SHARED_STORAGE_NAME}'"; exit 1; }
echo "Setting preference data.sharing.storage.folders.directory=${SHARED_STORAGE_ID}"
api_set_preference "data.sharing.storage.folders.directory" "$SHARED_STORAGE_ID" "false"
echo "data.sharing.storage.folders.directory preference set to folder ID ${SHARED_STORAGE_ID}."
