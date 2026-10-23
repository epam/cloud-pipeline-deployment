#!/usr/bin/env bash
# Helm post-install/post-upgrade Job: registers the system storage inside the SYSTEM folder.
# Re-run on every deploy; no state is tracked outside the API itself:
#   - looks up a storage matching the configured path (CP_PREF_STORAGE_SYSTEM_STORAGE_NAME) or, failing
#     that, one matching the configured friendly name (CP_API_SRV_SYSTEM_STORAGE_FRIENDLY_NAME) — each a
#     single indexed /datastorage/find lookup, not a full listing. Matching by path first (rather than
#     only by name) means a friendly-name-only change is detected as "same storage, just relabel it"
#     instead of registering a duplicate for the same path.
#   - no storage matches either: registers a new storage.
#   - a storage matches the path: that's the system storage; its name is updated if the friendly name
#     changed, and it's moved back into the SYSTEM folder if it ended up elsewhere (e.g. the folder was
#     recreated). FSBrowser preferences are re-applied either way.
#   - no storage matches the path, but one matches the friendly name: the configured path changed. That
#     storage is renamed to its own path (freeing up the friendly name so it's no longer picked up as the
#     system storage next run) but is otherwise left registered as-is; a new storage is then registered
#     under the friendly name with the new path.
#
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
DESIRED_PATH="$CP_PREF_STORAGE_SYSTEM_STORAGE_NAME"
FSBROWSER_TRANSFER="${CP_PREF_STORAGE_FSBROWSER_TRANSFER:-${DESIRED_PATH}/fsbrowser}"

api_wait_for_ready 30 10

folder_id=$(api_get_entity_id "$FOLDER_NAME" "folder") || {
  echo "ERROR: SYSTEM folder '${FOLDER_NAME}' not found; run register-system-folder.sh first."
  exit 1
}
echo "register-system-storage: using folder '${FOLDER_NAME}' (id=${folder_id})."

storage_by_path_json=$(api_find_datastorage "$DESIRED_PATH" 2>/dev/null || true)
storage_by_name_json=""
if [ -z "$storage_by_path_json" ]; then
  storage_by_name_json=$(api_find_datastorage "$STORAGE_FRIENDLY" 2>/dev/null || true)
fi

if [ -n "$storage_by_path_json" ]; then
  # A storage for this exact path already exists — that's the system storage, regardless of its current name.
  storage_id=$(echo "$storage_by_path_json" | jq -r '.id')
  current_name=$(echo "$storage_by_path_json" | jq -r '.name // empty')
  current_parent_id=$(echo "$storage_by_path_json" | jq -r '.parentFolderId // empty')

  if [ "$current_name" != "$STORAGE_FRIENDLY" ]; then
    # Another storage (e.g. a previously-active system storage for a different path) may still be
    # squatting on the friendly name from an earlier config change; free it first or this rename
    # fails on a uniqueness conflict.
    conflicting_storage_json=$(api_find_datastorage "$STORAGE_FRIENDLY" 2>/dev/null || true)
    if [ -n "$conflicting_storage_json" ]; then
      conflicting_id=$(echo "$conflicting_storage_json" | jq -r '.id')
      if [ "$conflicting_id" != "$storage_id" ]; then
        conflicting_path=$(echo "$conflicting_storage_json" | jq -r '.path // empty')
        echo "register-system-storage: storage (id=${conflicting_id}) currently holds the friendly name" \
             "'${STORAGE_FRIENDLY}'; renaming it back to its own path '${conflicting_path}' and moving it" \
             "out of '${FOLDER_NAME}' to free the name."
        freed_storage_json=$(echo "$conflicting_storage_json" | jq --arg n "$conflicting_path" '.name = $n | .parentFolderId = null')
        api_update_datastorage "$freed_storage_json" \
          || echo "WARNING: register-system-storage: failed to free '${STORAGE_FRIENDLY}' from storage (id=${conflicting_id}); rename below may fail."
      fi
    fi

    echo "register-system-storage: storage (id=${storage_id}, path='${DESIRED_PATH}') is named '${current_name}';" \
         "renaming it to the configured friendly name '${STORAGE_FRIENDLY}'."
    renamed_storage_json=$(echo "$storage_by_path_json" | jq --arg n "$STORAGE_FRIENDLY" '.name = $n')
    api_update_datastorage "$renamed_storage_json" \
      || echo "WARNING: register-system-storage: failed to rename storage (id=${storage_id}) to '${STORAGE_FRIENDLY}'."
  fi

  if [ "$current_parent_id" != "$folder_id" ]; then
    echo "register-system-storage: storage (id=${storage_id}) is not in the SYSTEM folder '${FOLDER_NAME}'" \
         "(parentFolderId=${current_parent_id:-none}); moving it there."
    moved_storage_json=$(echo "$storage_by_path_json" | jq --argjson pid "$folder_id" '.parentFolderId = $pid')
    api_update_datastorage "$moved_storage_json" \
      || echo "WARNING: register-system-storage: failed to move storage (id=${storage_id}) into folder '${FOLDER_NAME}'."
  else
    echo "register-system-storage: storage (id=${storage_id}) already registered for '${DESIRED_PATH}' in folder '${FOLDER_NAME}'."
  fi
elif [ -n "$storage_by_name_json" ]; then
  # The friendly name belongs to a storage with a different path — the configured path changed.
  storage_id=$(echo "$storage_by_name_json" | jq -r '.id')
  old_path=$(echo "$storage_by_name_json" | jq -r '.path // empty')
  echo "register-system-storage: configured path changed ('${old_path}' -> '${DESIRED_PATH}');" \
       "renaming storage (id=${storage_id}) to its own path '${old_path}' and moving it out of" \
       "'${FOLDER_NAME}' to free up the friendly name '${STORAGE_FRIENDLY}' (it remains registered," \
       "just no longer the system storage) and registering a new '${STORAGE_FRIENDLY}' storage for" \
       "'${DESIRED_PATH}'."
  retired_storage_json=$(echo "$storage_by_name_json" | jq --arg n "$old_path" '.name = $n | .parentFolderId = null')
  api_update_datastorage "$retired_storage_json" \
    || echo "WARNING: register-system-storage: failed to retire old storage (id=${storage_id}); registration of the new one may fail due to a name clash."
  new_storage_id=$(api_register_datastorage "$folder_id" "$STORAGE_FRIENDLY" "$DESIRED_PATH" "$STORAGE_TYPE")
  echo "register-system-storage: storage '${DESIRED_PATH}' registered (id=${new_storage_id})."
else
  echo "register-system-storage: no existing storage found for path '${DESIRED_PATH}' or name '${STORAGE_FRIENDLY}'; registering it (type=${STORAGE_TYPE})..."
  new_storage_id=$(api_register_datastorage "$folder_id" "$STORAGE_FRIENDLY" "$DESIRED_PATH" "$STORAGE_TYPE")
  echo "register-system-storage: storage '${DESIRED_PATH}' registered (id=${new_storage_id})."
fi

api_set_preference "storage.system.storage.name" "$DESIRED_PATH" "true"
api_set_preference "storage.fsbrowser.enabled"   "${CP_PREF_STORAGE_FSBROWSER_ENABLED:-true}" "true"
api_set_preference "storage.fsbrowser.port"      "${CP_PREF_STORAGE_FSBROWSER_PORT:-8091}"    "true"
api_set_preference "storage.fsbrowser.wd"        "${CP_PREF_STORAGE_FSBROWSER_WD:-/}"         "true"
api_set_preference "storage.fsbrowser.tmp"       "${CP_PREF_STORAGE_FSBROWSER_TMP:-/tmp}"     "true"
api_set_preference "storage.fsbrowser.transfer"  "$FSBROWSER_TRANSFER"                        "true"

echo "register-system-storage: done."
