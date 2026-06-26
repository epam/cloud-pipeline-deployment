#!/bin/bash
# Validation for postDeploy hooks (additionalCloudRegions, clusterNetworksConfig, emailNotifications).
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

CP_CLOUD_PLATFORM=$(jq_val '.resources.config.CP_CLOUD_PLATFORM // ""')

# ---------------------------------------------------------------------------
# postDeploy.additionalCloudRegions
# ---------------------------------------------------------------------------
ADDITIONAL_REGIONS_COUNT=$(jq_val \
  '.postDeploy.additionalCloudRegions | if type == "array" then length else 0 end')

if [ "${ADDITIONAL_REGIONS_COUNT:-0}" -gt 0 ]; then
  while IFS= read -r dup_id; do
    [ -n "$dup_id" ] && add_error "postDeploy.additionalCloudRegions has duplicate regionId: '$dup_id'"
  done < <(printf '%s' "${VALUES_JSON:-}" | jq -r '
    [.postDeploy.additionalCloudRegions[]?.regionId // ""]
    | group_by(.) | map(select(length > 1)) | .[][] | .
  ' 2>/dev/null || true)

  if [ "$CP_CLOUD_PLATFORM" = "aws" ]; then
    while IFS= read -r entry_json; do
      region_id=$(printf '%s' "$entry_json" | jq -r '.regionId // "(unknown)"')
      kms_arn=$(printf '%s' "$entry_json" | jq -r '.kmsKeyArn // ""')
      storage_role=$(printf '%s' "$entry_json" | jq -r '.tempCredentialsRole // ""')
      omics_role=$(printf '%s' "$entry_json" | jq -r '.omicsServiceRole // ""')
      backup_dur=$(printf '%s' "$entry_json" | jq -r '.backupDuration // ""')

      if [ -z "$kms_arn" ]; then
        add_error "postDeploy.additionalCloudRegions[$region_id].kmsKeyArn is required"
      elif ! [[ "$kms_arn" =~ ^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9_/-]+ ]]; then
        add_error "postDeploy.additionalCloudRegions[$region_id].kmsKeyArn='$kms_arn' does not match ARN format"
      fi

      if [ -n "$storage_role" ] && ! [[ "$storage_role" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+ ]]; then
        add_warning "postDeploy.additionalCloudRegions[$region_id].tempCredentialsRole='$storage_role' does not match IAM role ARN format"
      fi

      if [ -n "$omics_role" ] && ! [[ "$omics_role" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+ ]]; then
        add_warning "postDeploy.additionalCloudRegions[$region_id].omicsServiceRole='$omics_role' does not match IAM role ARN format"
      fi

      if [ -n "$backup_dur" ] && ! [[ "$backup_dur" =~ ^[0-9]+$ ]]; then
        add_error "postDeploy.additionalCloudRegions[$region_id].backupDuration='$backup_dur' must be a non-negative integer"
      fi

      while IFS= read -r fs_json; do
        mount_type=$(printf '%s' "$fs_json" | jq -r '.mountType // ""')
        mount_root=$(printf '%s' "$fs_json" | jq -r '.mountRoot // ""')
        if [ -n "$mount_type" ] && ! [[ "$mount_type" =~ ^(NFS|SMB)$ ]]; then
          add_warning "postDeploy.additionalCloudRegions[$region_id] fileshare '$mount_root' mountType='$mount_type' should be NFS or SMB"
        fi
      done < <(printf '%s' "$entry_json" | jq -c '.fileShareMounts[]? // empty' 2>/dev/null || true)
    done < <(printf '%s' "${VALUES_JSON:-}" | jq -c '.postDeploy.additionalCloudRegions[]?' 2>/dev/null || true)
  fi
fi

# ---------------------------------------------------------------------------
# postDeploy.clusterNetworksConfig
# ---------------------------------------------------------------------------
NETWORKS_COUNT=$(jq_val \
  '(.postDeploy.clusterNetworksConfig.regions // []) | length')

if [ "${NETWORKS_COUNT:-0}" -gt 0 ]; then
  STRING_DEFAULT_COUNT=$(jq_val \
    '[.postDeploy.clusterNetworksConfig.regions[]? | select((.default | type) == "string")] | length')
  if [ "${STRING_DEFAULT_COUNT:-0}" -gt 0 ]; then
    add_error "postDeploy.clusterNetworksConfig has entry(s) where 'default' is a string — it must be a boolean (true/false)"
  fi

  if [ "${NETWORKS_COUNT:-0}" -gt 1 ]; then
    DEFAULT_COUNT=$(jq_val \
      '[.postDeploy.clusterNetworksConfig.regions[]? | select(.default == true)] | length')
    if [ "${DEFAULT_COUNT:-0}" -eq 0 ]; then
      add_error "postDeploy.clusterNetworksConfig has $NETWORKS_COUNT entries but none has default: true; exactly one is required"
    elif [ "${DEFAULT_COUNT:-0}" -gt 1 ]; then
      add_error "postDeploy.clusterNetworksConfig has $DEFAULT_COUNT entries with default: true; exactly one is required"
    fi
  fi

  while IFS= read -r msg; do
    [ -n "$msg" ] && add_error "postDeploy.clusterNetworksConfig $msg"
  done < <(printf '%s' "${VALUES_JSON:-}" | jq -r '
    .postDeploy.clusterNetworksConfig.regions[]? | . as $entry |
    .amis[]? | select(.ami == null or .ami == "" or .ami == "auto") |
    "region \($entry.name // "(default)"): AMI entry has placeholder ami value (null/empty/\"auto\")"
  ' 2>/dev/null || true)

  while IFS= read -r msg; do
    [ -n "$msg" ] && add_error "postDeploy.clusterNetworksConfig $msg"
  done < <(printf '%s' "${VALUES_JSON:-}" | jq -r '
    .postDeploy.clusterNetworksConfig.regions[]? | . as $entry |
    .amis[]? | select(.platform != null and .platform != "linux" and .platform != "windows") |
    "region \($entry.name // "(default)"): AMI platform \(.platform | @json) is invalid; must be linux or windows"
  ' 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# postDeploy.emailNotifications
# ---------------------------------------------------------------------------
EMAIL_NOTIF_ENABLED=$(jq_val 'if .postDeploy.emailNotifications.enabled == false then "false" else (.postDeploy.emailNotifications.enabled // true | tostring) end')
if [ "$EMAIL_NOTIF_ENABLED" != "true" ] && [ "$EMAIL_NOTIF_ENABLED" != "false" ]; then
  add_error "postDeploy.emailNotifications.enabled must be true or false (got '$EMAIL_NOTIF_ENABLED')"
fi

EMAIL_TEMPLATES_CONFIGS_DIR="$(cd "$SCRIPT_DIR/../../post-deploy/assets/email-templates/configs" 2>/dev/null && pwd || true)"
KNOWN_EMAIL_TEMPLATE_NAMES='[]'
if [ -n "$EMAIL_TEMPLATES_CONFIGS_DIR" ] && [ -d "$EMAIL_TEMPLATES_CONFIGS_DIR" ]; then
  KNOWN_EMAIL_TEMPLATE_NAMES=$(find "$EMAIL_TEMPLATES_CONFIGS_DIR" -maxdepth 1 -type f -name '*.json' -exec basename {} .json \; | jq -R -s -c 'split("\n") | map(select(length > 0))')
fi

validate_email_notif_name_list() {
  local jq_filter="$1"
  local label="$2"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! printf '%s' "$KNOWN_EMAIL_TEMPLATE_NAMES" | jq -e --arg n "$name" 'index($n) != null' >/dev/null 2>&1; then
      add_error "postDeploy.emailNotifications.$label contains unknown notification type '$name'"
    fi
  done < <(printf '%s' "${VALUES_JSON:-}" | jq -r "$jq_filter" 2>/dev/null || true)
}

validate_email_notif_name_list '.postDeploy.emailNotifications.enableOnly[]?' 'enableOnly'
