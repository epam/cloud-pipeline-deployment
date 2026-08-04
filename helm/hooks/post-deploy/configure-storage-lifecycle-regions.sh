#!/bin/bash
# Helmfile cleanup hook: set storageLifecycleServiceProperties on all AWS cloud regions.
# Report bucket:  CP_PREF_STORAGE_SYSTEM_STORAGE_NAME from cp-config-global (skip if empty).
# Role ARN:       tempCredentialsRole from each region's API object (skip region if not set).
# Args: NAMESPACE
set -euo pipefail

NAMESPACE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/cloud-pipeline-utils.sh
source "$SCRIPT_DIR/utils/cloud-pipeline-utils.sh"

[ -z "$NAMESPACE" ] && usage

for cmd in kubectl curl jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

echo "Loading config from cp-config-global..."
CP_CONFIG_GLOBAL_JSON=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json)
eval "$(echo "$CP_CONFIG_GLOBAL_JSON" | jq -r '.data | to_entries[] | select(.value != null and .value != "") | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) | "export \(.key)=\(.value | @sh)"')"

if [ -z "${CP_PREF_STORAGE_SYSTEM_STORAGE_NAME:-}" ]; then
  echo "CP_PREF_STORAGE_SYSTEM_STORAGE_NAME is not set in cp-config-global; skipping storageLifecycleServiceProperties configuration."
  exit 0
fi

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
[ -z "$API_CONNECT_HOST" ] || [ -z "$API_CONNECT_PORT" ] && { echo "ERROR: Missing API endpoint (internal or external host/port)"; exit 1; }
validate_api_port "$API_CONNECT_PORT" || exit 1

API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API: $API_URL"

echo "Fetching all cloud regions..."
ALL_REGIONS_RESPONSE=$(call_api "/cloud/region" "$CP_API_JWT_ADMIN" "")
if ! check_api_response_status "$ALL_REGIONS_RESPONSE"; then
  echo "ERROR: Failed to list cloud regions: $ALL_REGIONS_RESPONSE"
  exit 1
fi

AWS_REGIONS=$(echo "$ALL_REGIONS_RESPONSE" | jq -c '[.payload[] | select(.provider == "AWS") | {id: .id, regionId: .regionId}]')
if [ "$(echo "$AWS_REGIONS" | jq 'length')" -eq 0 ]; then
  echo "No AWS cloud regions found; skipping."
  exit 0
fi

errors=0
while IFS= read -r region_entry; do
  region_id=$(echo "$region_entry" | jq -r '.id')
  aws_region_id=$(echo "$region_entry" | jq -r '.regionId')
  [ -z "$region_id" ] && continue
  echo "Configuring storageLifecycleServiceProperties for region $aws_region_id (id=$region_id)..."

  cloud_region_current_settings=$(call_api "/cloud/region/$region_id" "$CP_API_JWT_ADMIN" "")
  if ! check_api_response_status "$cloud_region_current_settings"; then
    echo "WARNING: GET /cloud/region/$region_id failed; skipping."
    echo "$cloud_region_current_settings"
    errors=$((errors + 1))
    continue
  fi

  sls_region_override=$(echo "$CP_POST_DEPLOY_SLS_REGIONS_B64" | base64 -d \
    | jq -c --arg rid "$aws_region_id" '.[] | select(.awsRegionId == $rid)' 2>/dev/null || true)

  # If a full slsProperties object is provided for this region, use it as-is.
  sls_properties=$(echo "$sls_region_override" | jq -c '.slsProperties // empty' 2>/dev/null || true)

  if [ -z "$sls_properties" ]; then
    # Build sls_properties from role ARN (per-region override or tempCredentialsRole fallback).
    sls_role_arn=$(echo "$sls_region_override" | jq -r '.slsRoleArn // ""' 2>/dev/null || true)
    if [ -z "$sls_role_arn" ]; then
      sls_role_arn=$(echo "$cloud_region_current_settings" | jq -r '.payload.tempCredentialsRole // ""')
    fi
    if [ -z "$sls_role_arn" ]; then
      echo "WARNING: region id=$region_id has no slsProperties, slsRoleArn, or tempCredentialsRole; skipping."
      continue
    fi

    sls_aws_account_id=$(echo "$sls_role_arn" | grep -oP '(?<=::)\d{12}(?=:role/)')
    if [ -z "$sls_aws_account_id" ]; then
      echo "WARNING: Cannot extract AWS account ID from role ARN '$sls_role_arn' for region id=$region_id; skipping."
      errors=$((errors + 1))
      continue
    fi

    sls_report_bucket_prefix="${CP_POST_DEPLOY_SLS_REPORT_BUCKET_PREFIX:-${CP_PREF_STORAGE_LIFECYCLE_SERVICE_REPORT_BUCKET_PREFIX:-storage-lifecycle-service/tagging-job-reports}}"

    sls_properties=$(jq -n \
      --arg acct "$sls_aws_account_id" \
      --arg role "$sls_role_arn" \
      --arg bucket "$CP_PREF_STORAGE_SYSTEM_STORAGE_NAME" \
      --arg prefix "$sls_report_bucket_prefix" \
      '{
        properties: {
          batch_operation_job_aws_account_id: $acct,
          batch_operation_job_role_arn: $role,
          batch_operation_job_report_bucket: $bucket,
          batch_operation_job_report_bucket_prefix: $prefix,
          batch_operation_job_poll_status_retry_count: "30",
          batch_operation_job_poll_status_sleep_sec: "5",
          storage_skip_archiving_tag: "disable_storage_lifecycle"
        }
      }')
  fi

  cloud_region_updated_settings=$(echo "$cloud_region_current_settings" | jq --argjson sls "$sls_properties" '.payload.storageLifecycleServiceProperties = $sls | .payload')

  cloud_region_update_check=$(call_api_put "/cloud/region/$region_id" "$CP_API_JWT_ADMIN" "$cloud_region_updated_settings")
  if ! check_api_response_status "$cloud_region_update_check"; then
    echo "WARNING: PUT /cloud/region/$region_id failed."
    echo "$cloud_region_update_check"
    errors=$((errors + 1))
    continue
  fi
  echo "Region id=$region_id storageLifecycleServiceProperties configured."
done < <(echo "$AWS_REGIONS" | jq -c '.[]')

if [ "$errors" -gt 0 ]; then
  echo "WARNING: $errors region(s) failed to configure. Check output above."
  exit 1
fi

echo "storageLifecycleServiceProperties configuration finished."
