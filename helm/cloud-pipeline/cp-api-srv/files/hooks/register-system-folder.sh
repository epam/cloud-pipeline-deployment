#!/usr/bin/env bash
# Helm post-install/post-upgrade Job: creates the SYSTEM folder in the Pipeline API.
set -euo pipefail

# shellcheck source=cloud-pipeline-utils.sh
source /scripts/cloud-pipeline-utils.sh

for cmd in kubectl curl jq base64; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

[ -z "${CP_API_JWT_ADMIN:-}" ] && { echo "WARNING: CP_API_JWT_ADMIN not found; skipping."; exit 0; }

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  API_URL="https://${CP_API_SRV_INTERNAL_HOST}:${CP_API_SRV_INTERNAL_PORT}/pipeline/restapi"
elif [ -n "${CP_API_SRV_EXTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_EXTERNAL_PORT:-}" ]; then
  API_URL="https://${CP_API_SRV_EXTERNAL_HOST}:${CP_API_SRV_EXTERNAL_PORT}/pipeline/restapi"
else
  echo "WARNING: API endpoint not found; skipping."
  exit 0
fi
echo "register-system-folder: API=$API_URL"

FOLDER_NAME="${CP_API_SRV_SYSTEM_FOLDER_NAME:-SYSTEM}"
FOLDER_DESC="${CP_API_SRV_SYSTEM_FOLDER_DESCRIPTION:-Folder for system-level entities not accessed directly by users}"

api_wait_for_ready 30 10

if folder_id=$(api_get_entity_id "$FOLDER_NAME" "folder" 2>/dev/null); then
  echo "register-system-folder: folder '${FOLDER_NAME}' already exists (id=${folder_id}); skipping."
  exit 0
fi

echo "register-system-folder: creating folder '${FOLDER_NAME}'..."
folder_id=$(api_create_folder "$FOLDER_NAME")
echo "register-system-folder: folder '${FOLDER_NAME}' created (id=${folder_id})."

api_set_entity_attribute "$folder_id" "FOLDER" "Description" "$FOLDER_DESC" \
  || echo "WARNING: register-system-folder: could not set folder description."

echo "register-system-folder: done."
