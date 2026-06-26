#!/bin/bash
# Helmfile cleanup hook: register additional (non-default) AWS cloud regions. Args: NAMESPACE
set -euo pipefail

NAMESPACE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/cloud-pipeline-utils.sh
source "$SCRIPT_DIR/utils/cloud-pipeline-utils.sh"

[ -z "$NAMESPACE" ] && usage

for cmd in kubectl curl jq base64; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

if [ -z "${CP_POST_DEPLOY_ADDITIONAL_CLOUD_REGIONS_B64:-}" ]; then
  echo "CP_POST_DEPLOY_ADDITIONAL_CLOUD_REGIONS_B64 is not set; no additional regions to register."
  exit 0
fi
if ! printf '%s' "$CP_POST_DEPLOY_ADDITIONAL_CLOUD_REGIONS_B64" | base64 -d >/dev/null 2>&1; then
  echo "ERROR: CP_POST_DEPLOY_ADDITIONAL_CLOUD_REGIONS_B64 is not valid base64"
  exit 1
fi
REGIONS_JSON=$(printf '%s' "$CP_POST_DEPLOY_ADDITIONAL_CLOUD_REGIONS_B64" | base64 -d)
if [ -z "$REGIONS_JSON" ] || [ "$REGIONS_JSON" = "null" ]; then
  echo "No additional cloud regions configured; skipping."
  exit 0
fi
if ! echo "$REGIONS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "ERROR: CP_POST_DEPLOY_ADDITIONAL_CLOUD_REGIONS_B64 decodes to a non-array JSON value"
  exit 1
fi
if [ "$(echo "$REGIONS_JSON" | jq 'length')" -eq 0 ]; then
  echo "No additional cloud regions configured; skipping."
  exit 0
fi

echo "Loading config from cp-config-global..."
CP_CONFIG_GLOBAL_JSON=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json)
# key filter ensures only valid bash identifiers reach eval; non-conforming keys are skipped
# (e.g. "my.key", "my-key", or "FOO=$(rm -rf /)" would be silently ignored)
eval "$(echo "$CP_CONFIG_GLOBAL_JSON" | jq -r '.data | to_entries[] | select(.value != null and .value != "") | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) | "export \(.key)=\(.value | @sh)"')"

export CP_API_JWT_ADMIN
CP_API_JWT_ADMIN=$(kubectl get secret cp-api-token -n "$NAMESPACE" -o jsonpath='{.data.CP_API_JWT_ADMIN}' | base64 -d)
[ -z "$CP_API_JWT_ADMIN" ] && { echo "ERROR: CP_API_JWT_ADMIN not found in cp-api-token"; exit 1; }

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  API_CONNECT_HOST="$CP_API_SRV_INTERNAL_HOST"
  API_CONNECT_PORT="$CP_API_SRV_INTERNAL_PORT"
else
  API_CONNECT_HOST="${CP_API_SRV_EXTERNAL_HOST:-}"
  API_CONNECT_PORT="${CP_API_SRV_EXTERNAL_PORT:-}"
fi
if [ -z "$API_CONNECT_HOST" ] || [ -z "$API_CONNECT_PORT" ]; then
  echo "ERROR: Missing API endpoint (internal or external host/port)"
  exit 1
fi
validate_api_port "$API_CONNECT_PORT" || exit 1

API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API: $API_URL"

function id_from_arn {
  echo "$1" | cut -d/ -f2
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
  local region_name kms_arn kms_id ssh_key_name temp_credentials_role backup_duration
  local omics_service_role omics_ecr_registry cors_rules fileshares_json existing_id
  local mount_credentials_rule mount_storage_rule mount_file_storage_rule

  region_name=$(printf '%s' "$entry" | jq -r '.regionId')
  kms_arn=$(printf '%s' "$entry" | jq -r '.kmsKeyArn // ""')
  kms_id=$(printf '%s' "$entry" | jq -r '.kmsKeyId // ""')
  ssh_key_name=$(printf '%s' "$entry" | jq -r '.sshKeyName // ""')
  temp_credentials_role=$(printf '%s' "$entry" | jq -r '.tempCredentialsRole // ""')
  backup_duration=$(printf '%s' "$entry" | jq -r '.backupDuration // "20"')
  omics_service_role=$(printf '%s' "$entry" | jq -r '.omicsServiceRole // ""')
  omics_ecr_registry=$(printf '%s' "$entry" | jq -r '.omicsEcrUrl // ""')
  fileshares_json=$(printf '%s' "$entry" | jq -c '.fileShareMounts // []')
  cors_rules=$(printf '%s' "$entry" | jq -r '.corsRules // ""')
  if [ -z "$cors_rules" ]; then
    local _cors_file="$SCRIPT_DIR/assets/storage.cors.policy.json"
    cors_rules=$(jq -c . "$_cors_file" 2>/dev/null || echo '[]')
  else
    local _cors_unescaped
    _cors_unescaped=$(printf '%s' "$cors_rules" | jq -r '.' 2>/dev/null) && cors_rules="$_cors_unescaped"
    if ! printf '%s' "$cors_rules" | jq -e . >/dev/null 2>&1; then
      echo "WARNING: corsRules for region '$region_name' is not valid JSON; using []."
      cors_rules='[]'
    else
      cors_rules=$(printf '%s' "$cors_rules" | jq -c .)
    fi
  fi
  mount_credentials_rule=$(printf '%s' "$entry" | jq -r '.mountCredentialsRule // "CLOUD"')
  mount_storage_rule=$(printf '%s' "$entry" | jq -r '.mountStorageRule // "CLOUD"')
  mount_file_storage_rule=$(printf '%s' "$entry" | jq -r '.mountFileStorageRule // "CLOUD"')

  if [ -z "$region_name" ] || [ "$region_name" = "null" ]; then
    echo "ERROR: region entry is missing regionId; skipping: $entry"
    return 1
  fi
  if [ -z "$kms_arn" ] || [ "$kms_arn" = "null" ]; then
    echo "ERROR: region '$region_name' is missing kmsKeyArn; skipping."
    return 1
  fi
  if ! [[ "$kms_arn" =~ ^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9_/-]+$ ]]; then
    echo "ERROR: region '$region_name' kmsKeyArn does not match expected ARN format: $kms_arn"
    return 1
  fi
  if ! [[ "$backup_duration" =~ ^[0-9]+$ ]]; then
    echo "ERROR: region '$region_name' backupDuration='$backup_duration' is not a non-negative integer"
    return 1
  fi
  if [ -n "$temp_credentials_role" ] && [ "$temp_credentials_role" != "null" ]; then
    if ! [[ "$temp_credentials_role" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+ ]]; then
      echo "WARNING: region '$region_name' tempCredentialsRole does not look like an IAM role ARN: $temp_credentials_role"
    fi
  fi
  if [ -n "$omics_service_role" ] && [ "$omics_service_role" != "null" ]; then
    if ! [[ "$omics_service_role" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+ ]]; then
      echo "WARNING: region '$region_name' omicsServiceRole does not look like an IAM role ARN: $omics_service_role"
    fi
  fi
  if ! printf '%s' "$cors_rules" | jq -e . >/dev/null 2>&1; then
    echo "WARNING: region '$region_name' corsRules is not valid JSON; using []."
    cors_rules='[]'
  fi
  cors_rules=$(printf '%s' "$cors_rules" | jq -c .)

  echo "Processing additional cloud region: $region_name"

  if existing_id=$(api_get_cloud_region_id "$region_name"); then
    echo "Region '$region_name' already exists (id=$existing_id); updating via PUT."
    local get_response updated_region_json update_response rc
    get_response=$(call_api "/cloud/region/$existing_id" "$CP_API_JWT_ADMIN" "")
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "WARNING: GET /cloud/region/$existing_id failed; leaving region unchanged."
      echo "$get_response"
      return 0
    fi
    updated_region_json=$(printf '%s' "$get_response" | jq '.payload')
    if [ -n "$temp_credentials_role" ] && [ "$temp_credentials_role" != "null" ]; then
      updated_region_json=$(printf '%s' "$updated_region_json" | jq --arg tempCredentialsRole "$temp_credentials_role" '.tempCredentialsRole = $tempCredentialsRole')
    fi
    # AWSRegionDTO.corsRules is typed String server-side: pass as a JSON-encoded string, not an array.
    updated_region_json=$(printf '%s' "$updated_region_json" | jq \
      --arg corsRules "$cors_rules" \
      --arg mountCredentialsRule "$mount_credentials_rule" \
      --arg mountStorageRule "$mount_storage_rule" \
      --arg mountFileStorageRule "$mount_file_storage_rule" \
      '.corsRules = $corsRules | .mountCredentialsRule = $mountCredentialsRule | .mountStorageRule = $mountStorageRule | .mountFileStorageRule = $mountFileStorageRule')
    update_response=$(call_api_put "/cloud/region/$existing_id" "$CP_API_JWT_ADMIN" "$updated_region_json")
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "WARNING: PUT /cloud/region/$existing_id failed."
      echo "$update_response"
    fi
    local existing_mounts
    existing_mounts=$(printf '%s' "$updated_region_json" | jq -r '[.fileShareMounts[]?.mountRoot // empty]' 2>/dev/null || echo "[]")
    register_fileshares "$existing_id" "$region_name" "$fileshares_json" "$existing_mounts"
    return 0
  fi

  local payload register_response rc
  payload=$(jq -n \
    --arg regionId "$region_name" \
    --arg name "$region_name" \
    --arg sshKeyName "$ssh_key_name" \
    --arg tempCredentialsRole "$temp_credentials_role" \
    --argjson backupDuration "$((backup_duration))" \
    --arg omicsServiceRole "$omics_service_role" \
    --arg omicsEcrUrl "$omics_ecr_registry" \
    --arg kmsKeyId "$kms_id" \
    --arg kmsKeyArn "$kms_arn" \
    --arg corsRules "$cors_rules" \
    --arg mountCredentialsRule "$mount_credentials_rule" \
    --arg mountStorageRule "$mount_storage_rule" \
    --arg mountFileStorageRule "$mount_file_storage_rule" \
    '{
      regionId: $regionId,
      provider: "AWS",
      name: $name,
      default: false,
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

  register_response=$(call_api "/cloud/region" "$CP_API_JWT_ADMIN" "$payload")
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: POST /cloud/region failed for '$region_name'."
    echo "$register_response"
    return 1
  fi
  echo "Cloud region '$region_name' registered successfully."

  local region_id
  if ! region_id=$(api_get_cloud_region_id "$region_name"); then
    echo "WARNING: Region '$region_name' was created but id lookup failed; skipping fileshare registration."
    return 0
  fi
  register_fileshares "$region_id" "$region_name" "$fileshares_json"
}

region_count=$(printf '%s' "$REGIONS_JSON" | jq 'length')
duplicate_regions=$(printf '%s' "$REGIONS_JSON" | jq -r '[.[].regionId] | group_by(.) | map(select(length > 1)) | .[][] | .' 2>/dev/null || true)
if [ -n "$duplicate_regions" ]; then
  echo "WARNING: Duplicate regionId entries detected — only the last entry will take effect: $duplicate_regions"
fi
echo "Registering $region_count additional cloud region(s)..."

errors=0
while IFS= read -r region_entry; do
  register_region "$region_entry" || errors=$((errors + 1))
done < <(printf '%s' "$REGIONS_JSON" | jq -c '.[]')

if [ "$errors" -gt 0 ]; then
  echo "WARNING: $errors additional cloud region(s) failed to register. Check the output above."
  exit 1
fi

echo "Additional cloud regions registration finished."
