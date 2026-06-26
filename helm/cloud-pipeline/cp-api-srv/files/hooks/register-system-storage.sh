#!/usr/bin/env bash
# Helm post-install/post-upgrade Job: registers the system storage inside the SYSTEM folder.
# Config is read from cp-config-global (populated by cp-api-srv chart from apiSrv.config values):
#   CP_PREF_STORAGE_SYSTEM_STORAGE_NAME  - S3/AZ/GS bucket path (required; skip if empty)
#   CP_PREF_STORAGE_SCHEMA               - storage backend type (default: S3)
#   CP_PREF_STORAGE_FSBROWSER_*          - FSBrowser preferences
set -euo pipefail

# shellcheck source=cloud-pipeline-utils.sh
source /scripts/cloud-pipeline-utils.sh

for cmd in kubectl curl jq base64; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

[ -z "${CP_API_JWT_ADMIN:-}" ] && { echo "WARNING: CP_API_JWT_ADMIN not found; skipping."; exit 0; }

if [ -z "${CP_PREF_STORAGE_SYSTEM_STORAGE_NAME:-}" ]; then
  echo "register-system-storage: CP_PREF_STORAGE_SYSTEM_STORAGE_NAME not set; skipping."
  exit 0
fi

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  API_URL="https://${CP_API_SRV_INTERNAL_HOST}:${CP_API_SRV_INTERNAL_PORT}/pipeline/restapi"
elif [ -n "${CP_API_SRV_EXTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_EXTERNAL_PORT:-}" ]; then
  API_URL="https://${CP_API_SRV_EXTERNAL_HOST}:${CP_API_SRV_EXTERNAL_PORT}/pipeline/restapi"
else
  echo "WARNING: API endpoint not found; skipping."
  exit 0
fi
echo "register-system-storage: API=$API_URL storage=${CP_PREF_STORAGE_SYSTEM_STORAGE_NAME}"

FOLDER_NAME="${CP_API_SRV_SYSTEM_FOLDER_NAME:-SYSTEM}"
STORAGE_FRIENDLY="${CP_API_SRV_SYSTEM_STORAGE_FRIENDLY_NAME:-cloud-pipeline-etc}"
STORAGE_TYPE="${CP_PREF_STORAGE_SCHEMA:-S3}"
STORAGE_TYPE="${STORAGE_TYPE^^}"
FSBROWSER_TRANSFER="${CP_PREF_STORAGE_FSBROWSER_TRANSFER:-${CP_PREF_STORAGE_SYSTEM_STORAGE_NAME}/fsbrowser}"

api_wait_for_ready 30 10

# Idempotency: skip if storage.system.storage.name is already set
storage_name_preference_response=$(curl -k -sS --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${CP_API_JWT_ADMIN}" \
    "${API_URL}/preferences/storage.system.storage.name" 2>/dev/null || true)
existing_storage_name=$(echo "$storage_name_preference_response" | jq -r '.payload.value // ""' 2>/dev/null || true)
if [ -n "$existing_storage_name" ]; then
  echo "register-system-storage: storage.system.storage.name already set to '${existing_storage_name}'; skipping."
  exit 0
fi

folder_id=$(api_get_entity_id "$FOLDER_NAME" "folder") || {
  echo "ERROR: SYSTEM folder '${FOLDER_NAME}' not found; run register-system-folder.sh first."
  exit 1
}
echo "register-system-storage: using folder '${FOLDER_NAME}' (id=${folder_id})."

echo "register-system-storage: registering storage '${CP_PREF_STORAGE_SYSTEM_STORAGE_NAME}' (type=${STORAGE_TYPE})..."
api_register_datastorage "$folder_id" "$STORAGE_FRIENDLY" "$CP_PREF_STORAGE_SYSTEM_STORAGE_NAME" "$STORAGE_TYPE"
echo "register-system-storage: storage '${CP_PREF_STORAGE_SYSTEM_STORAGE_NAME}' registered."

api_set_preference "storage.system.storage.name" "$CP_PREF_STORAGE_SYSTEM_STORAGE_NAME"         "true"
api_set_preference "storage.fsbrowser.enabled"   "${CP_PREF_STORAGE_FSBROWSER_ENABLED:-true}"   "true"
api_set_preference "storage.fsbrowser.port"      "${CP_PREF_STORAGE_FSBROWSER_PORT:-8091}"      "true"
api_set_preference "storage.fsbrowser.wd"        "${CP_PREF_STORAGE_FSBROWSER_WD:-/}"           "true"
api_set_preference "storage.fsbrowser.tmp"       "${CP_PREF_STORAGE_FSBROWSER_TMP:-/tmp}"       "true"
api_set_preference "storage.fsbrowser.transfer"  "$FSBROWSER_TRANSFER"                          "true"

echo "register-system-storage: done."
