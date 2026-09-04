#!/bin/bash
# Helm post-install/post-upgrade Job: register the default AWS cloud region via API.
set -euo pipefail

# shellcheck source=cloud-pipeline-utils.sh
source /scripts/cloud-pipeline-utils.sh

for cmd in kubectl curl jq base64; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

[ -z "${CP_API_JWT_ADMIN:-}" ] && { echo "ERROR: CP_API_JWT_ADMIN not found in cp-api-token"; exit 1; }
[ -z "${CP_CLOUD_REGION_JSON:-}" ] && { echo "ERROR: CP_CLOUD_REGION_JSON is not set"; exit 1; }

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  API_CONNECT_HOST="$CP_API_SRV_INTERNAL_HOST"
  API_CONNECT_PORT="$CP_API_SRV_INTERNAL_PORT"
else
  API_CONNECT_HOST="${CP_API_SRV_EXTERNAL_HOST:-}"
  API_CONNECT_PORT="${CP_API_SRV_EXTERNAL_PORT:-}"
fi
if [ -z "$API_CONNECT_HOST" ] || [ -z "$API_CONNECT_PORT" ]; then
  echo "Missing API endpoint (internal or external host/port)"
  exit 1
fi

API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API: $API_URL"

function id_from_arn {
  echo "$1" | cut -d/ -f2
}

function api_get_cloud_region_id {
  local region_name="$1"
  local region_name_url_encoded region_lookup_response region_id
  region_name_url_encoded=$(printf '%s' "$region_name" | jq -sRr @uri)
  region_lookup_response=$(call_api "/entities?identifier=${region_name_url_encoded}&aclClass=CLOUD_REGION" "$CP_API_JWT_ADMIN" "")
  region_id=$(echo "$region_lookup_response" | jq -r '.payload.id')
  if [ -n "$region_id" ] && [ "$region_id" != "null" ]; then
    echo "$region_id"
    return 0
  fi
  return 1
}

function api_entity_grant {
  local entity_id="$1"
  local entity_class="$2"
  local entity_mask="$3"
  local entity_principal="$4"
  local entity_user="$5"
  local payload
  read -r -d '' payload <<-EOF || true
{
    "aclClass":"$entity_class",
    "id":$entity_id,
    "mask":$entity_mask,
    "principal":$entity_principal,
    "userName":"$entity_user"
}
EOF
  local grant_response rc
  grant_response=$(call_api "/grant" "$CP_API_JWT_ADMIN" "$payload")
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: grant failed for $entity_user on $entity_class id=$entity_id"
    echo "$grant_response"
  fi
  return $rc
}

function api_register_fileshare {
  local region_id="$1"
  local mount_point="$2"
  local fs_type="$3"
  local fs_options="$4"
  local payload
  read -r -d '' payload <<-EOF || true
{
    "regionId":$region_id,
    "mountRoot":"$mount_point",
    "mountType":"$fs_type",
    "mountOptions":"$fs_options"
}
EOF
  local register_fileshare_response rc
  register_fileshare_response=$(call_api "/filesharemount" "$CP_API_JWT_ADMIN" "$payload")
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: fileshare mount registration failed for $mount_point"
    echo "$register_fileshare_response"
  fi
  return $rc
}

function register_fileshares {
  local region_id="$1"
  local region_name="$2"
  local fileshares_json="$3"
  local existing_mounts="${4:-[]}"
  [ -z "$fileshares_json" ] || [ "$fileshares_json" = "[]" ] || [ "$fileshares_json" = "null" ] && return 0
  while IFS= read -r fs_entry; do
    local fs_mount fs_type fs_options
    fs_mount=$(printf '%s' "$fs_entry" | jq -r '.mountRoot // ""')
    fs_type=$(printf '%s' "$fs_entry" | jq -r '.mountType // ""')
    fs_options=$(printf '%s' "$fs_entry" | jq -r '.mountOptions // ""')
    [ -z "$fs_mount" ] && continue
    if printf '%s' "$existing_mounts" | jq -e --arg m "$fs_mount" 'index($m) != null' >/dev/null 2>&1; then
      echo "Fileshare '$fs_mount' already registered for region '$region_name'; skipping."
      continue
    fi
    if [ -n "$fs_type" ] && [ "$fs_type" != "NFS" ] && [ "$fs_type" != "SMB" ]; then
      echo "WARNING: fileshare '$fs_mount' has unknown mountType '$fs_type' (expected NFS or SMB)."
    fi
    api_register_fileshare "$region_id" "$fs_mount" "$fs_type" "$fs_options" \
      || echo "WARNING: fileshare '$fs_mount' registration failed for region '$region_name'."
  done < <(printf '%s' "$fileshares_json" | jq -c '.[]')
}

function register_region {
  local entry="$1"
  local region_role_grant="${2:-ROLE_USER}"
  local region_name kms_arn kms_id ssh_key_name temp_credentials_role backup_duration
  local omics_service_role omics_ecr_registry fileshares_json region_id
  local mount_credentials_rule mount_storage_rule mount_file_storage_rule

  region_name=$(printf '%s' "$entry" | jq -r '.regionId // ""')
  kms_arn=$(printf '%s' "$entry" | jq -r '.kmsKeyArn // ""')
  kms_id=$(printf '%s' "$entry" | jq -r '.kmsKeyId // ""')
  ssh_key_name=$(printf '%s' "$entry" | jq -r '.sshKeyName // ""')
  temp_credentials_role=$(printf '%s' "$entry" | jq -r '.tempCredentialsRole // ""')
  backup_duration=$(printf '%s' "$entry" | jq -r '.backupDuration // "20"')
  omics_service_role=$(printf '%s' "$entry" | jq -r '.omicsServiceRole // ""')
  omics_ecr_registry=$(printf '%s' "$entry" | jq -r '.omicsEcrUrl // ""')
  fileshares_json=$(printf '%s' "$entry" | jq -c '.fileShareMounts // []')
  mount_credentials_rule=$(printf '%s' "$entry" | jq -r '.mountCredentialsRule // "CLOUD"')
  mount_storage_rule=$(printf '%s' "$entry" | jq -r '.mountStorageRule // "CLOUD"')
  mount_file_storage_rule=$(printf '%s' "$entry" | jq -r '.mountFileStorageRule // "CLOUD"')

  [ -z "$region_name" ] || [ "$region_name" = "null" ] && region_name="${CP_CLOUD_REGION_ID:-}"
  if [ -z "$region_name" ]; then
    echo "ERROR: CP_CLOUD_REGION_ID is not set; cannot register cloud region."
    return 1
  fi
  if [ -z "$kms_arn" ] || [ "$kms_arn" = "null" ]; then
    echo "ERROR: kmsKeyArn is not set in CP_CLOUD_REGION_JSON; cannot register AWS cloud region."
    return 1
  fi
  if ! [[ "$backup_duration" =~ ^[0-9]+$ ]]; then
    echo "ERROR: backupDuration='$backup_duration' is not a non-negative integer"
    return 1
  fi
  [ -z "$temp_credentials_role" ] && echo "WARNING: tempCredentialsRole is not set; 'pipe storage' temp credentials may not work."
  [ -z "$ssh_key_name" ]          && echo "WARNING: sshKeyName is not set; SSH key name will be empty in region registration."

  local cors_rules
  cors_rules=$(printf '%s' "$CP_CLOUD_REGION_JSON" | jq -r '.corsRules // ""')
  if [ -z "$cors_rules" ]; then
    cors_rules=$(jq -c . /assets/storage.cors.policy.json 2>/dev/null || echo '[]')
  else
    local _cors_unescaped
    _cors_unescaped=$(printf '%s' "$cors_rules" | jq -r '.' 2>/dev/null) && cors_rules="$_cors_unescaped"
    if ! printf '%s' "$cors_rules" | jq -e . >/dev/null 2>&1; then
      echo "WARNING: CORS rules are not valid JSON; using []."
      cors_rules='[]'
    fi
  fi
  local cors_compact
  cors_compact=$(printf '%s' "$cors_rules" | jq -c .)

  region_id=$(api_get_cloud_region_id "$region_name" || true)

  if [ -n "$region_id" ]; then
    echo "Cloud region \"$region_name\" already exists (id=$region_id); applying env overrides via PUT if present."
    export CP_CLOUD_REGION_INTERNAL_ID=$region_id
    local get_region_response updated_region_json update_region_response rc
    get_region_response=$(call_api "/cloud/region/$region_id" "$CP_API_JWT_ADMIN" "")
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "WARNING: GET /cloud/region/$region_id failed; leaving region unchanged."
      echo "$get_region_response"
      return 0
    fi
    updated_region_json=$(printf '%s' "$get_region_response" | jq '.payload')
    if [ -n "$temp_credentials_role" ]; then
      updated_region_json=$(printf '%s' "$updated_region_json" | jq --arg tempCredentialsRole "$temp_credentials_role" '.tempCredentialsRole = $tempCredentialsRole')
    fi
    # AWSRegionDTO.corsRules is typed String server-side: pass as a JSON-encoded string, not an array.
    updated_region_json=$(printf '%s' "$updated_region_json" | jq \
      --arg corsRules "$cors_compact" \
      --arg mountCredentialsRule "$mount_credentials_rule" \
      --arg mountStorageRule "$mount_storage_rule" \
      --arg mountFileStorageRule "$mount_file_storage_rule" \
      '.corsRules = $corsRules | .mountCredentialsRule = $mountCredentialsRule | .mountStorageRule = $mountStorageRule | .mountFileStorageRule = $mountFileStorageRule')
    update_region_response=$(call_api_put "/cloud/region/$region_id" "$CP_API_JWT_ADMIN" "$updated_region_json")
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "WARNING: PUT /cloud/region/$region_id failed (temp role / CORS may be unchanged)."
      echo "$update_region_response"
    fi
    local existing_mounts
    existing_mounts=$(printf '%s' "$updated_region_json" | jq -r '[.fileShareMounts[]?.mountRoot // empty]' 2>/dev/null || echo "[]")
    register_fileshares "$region_id" "$region_name" "$fileshares_json" "$existing_mounts"
    return 0
  fi

  local payload register_region_response rc
  payload=$(jq -n \
    --arg regionId "$region_name" \
    --arg name "$region_name" \
    --arg sshKeyName "$ssh_key_name" \
    --arg tempCredentialsRole "$temp_credentials_role" \
    --argjson backupDuration "$((backup_duration))" \
    --arg omicsServiceRole "$omics_service_role" \
    --arg omicsEcrUrl "$omics_ecr_registry" \
    --arg kmsKeyId "${kms_id:-$(id_from_arn "$kms_arn")}" \
    --arg kmsKeyArn "$kms_arn" \
    --arg corsRules "$cors_compact" \
    --arg mountCredentialsRule "$mount_credentials_rule" \
    --arg mountStorageRule "$mount_storage_rule" \
    --arg mountFileStorageRule "$mount_file_storage_rule" \
    '{
      regionId: $regionId,
      provider: "AWS",
      name: $name,
      default: true,
      sshKeyName: $sshKeyName,
      tempCredentialsRole: $tempCredentialsRole,
      versioningEnabled: true,
      backupDuration: $backupDuration,
      omicsServiceRole: $omicsServiceRole,
      omicsEcrUrl: $omicsEcrUrl,
      kmsKeyId: $kmsKeyId,
      kmsKeyArn: $kmsKeyArn,
      corsRules: $corsRules,
      mountCredentialsRule: $mountCredentialsRule,
      mountStorageRule: $mountStorageRule,
      mountFileStorageRule: $mountFileStorageRule
    }')

  register_region_response=$(call_api "/cloud/region" "$CP_API_JWT_ADMIN" "$payload")
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: POST /cloud/region failed for $region_name"
    echo "$register_region_response"
    return 1
  fi

  region_id=$(api_get_cloud_region_id "$region_name" || true)
  if [ -z "$region_id" ]; then
    echo "ERROR: Region was created but could not resolve id for $region_name"
    return 1
  fi
  export CP_CLOUD_REGION_INTERNAL_ID=$region_id
  echo "Cloud region $region_name registered (id=$region_id)."

  api_entity_grant "$CP_CLOUD_REGION_INTERNAL_ID" \
    "CLOUD_REGION" \
    "1" \
    "false" \
    "$region_role_grant" || echo "WARNING: ACL grant for $region_role_grant on region $region_name failed."

  register_fileshares "$region_id" "$region_name" "$fileshares_json"

  return 0
}

api_wait_for_ready 30 10 || { echo "ERROR: API did not become ready; aborting cloud region registration."; exit 1; }

echo "Registering default cloud region (POST /cloud/region)..."
max_registration_attempts=5
registration_attempt=0
while [ "$registration_attempt" -lt "$max_registration_attempts" ]; do
  registration_attempt=$((registration_attempt + 1))
  if register_region "$CP_CLOUD_REGION_JSON"; then
    break
  fi
  if [ "$registration_attempt" -ge "$max_registration_attempts" ]; then
    echo "WARNING: Cloud region registration failed after $max_registration_attempts attempts. Add the region via GUI/API. Verify CP_CLOUD_REGION_ID, CP_CLOUD_REGION_JSON (kmsKeyArn, sshKeyName), and API logs for POST /cloud/region."
    break
  fi
  echo "WARNING: Cloud region registration attempt $registration_attempt/$max_registration_attempts failed; retrying in 15s..."
  sleep 15
done
unset max_registration_attempts registration_attempt

echo "Cloud region registration finished."
