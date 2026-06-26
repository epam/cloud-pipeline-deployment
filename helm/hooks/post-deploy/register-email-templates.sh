#!/bin/bash
# Helmfile cleanup: register email notification templates and settings via API. Args: NAMESPACE
set -euo pipefail

NAMESPACE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/cloud-pipeline-utils.sh
source "$SCRIPT_DIR/utils/cloud-pipeline-utils.sh"

[ -z "$NAMESPACE" ] && usage

if [ -n "${CP_POST_DEPLOY_EMAIL_NOTIFICATIONS_SPEC_B64:-}" ]; then
  _enabled=$(printf '%s' "$CP_POST_DEPLOY_EMAIL_NOTIFICATIONS_SPEC_B64" | base64 -d | jq -r 'if .enabled == false then "false" else "true" end')
  if [ "$_enabled" = "false" ]; then
    echo "Email notifications disabled (emailNotifications.enabled=false); skipping."
    exit 0
  fi
fi

CONFIGS_DIR="${CP_EMAIL_TEMPLATES_CONFIGS_PATH:-${SCRIPT_DIR}/assets/email-templates/configs}"
CONTENTS_DIR="${CP_EMAIL_TEMPLATES_CONTENTS_PATH:-${SCRIPT_DIR}/assets/email-templates/contents}"

for cmd in kubectl curl jq base64 envsubst; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

if [ ! -d "$CONFIGS_DIR" ] || [ ! -d "$CONTENTS_DIR" ]; then
  echo "ERROR: Email templates directory not found at $CONFIGS_DIR or $CONTENTS_DIR"
  exit 1
fi

echo "Loading config from cp-config-global..."
CP_CONFIG_GLOBAL_JSON=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json)
# key filter ensures only valid bash identifiers reach eval; non-conforming keys are skipped
# (e.g. "my.key", "my-key", or "FOO=$(rm -rf /)" would be silently ignored)
eval "$(echo "$CP_CONFIG_GLOBAL_JSON" | jq -r '.data | to_entries[] | select(.value != null and .value != "") | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) | "export \(.key)=\(.value | @sh)"')"

export CP_API_JWT_ADMIN
CP_API_JWT_ADMIN=$(kubectl get secret cp-api-token -n "$NAMESPACE" -o jsonpath='{.data.CP_API_JWT_ADMIN}' | base64 -d)
[ -z "$CP_API_JWT_ADMIN" ] && { echo "CP_API_JWT_ADMIN not found in cp-api-token"; exit 1; }

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  API_CONNECT_HOST="$CP_API_SRV_INTERNAL_HOST"
  API_CONNECT_PORT="$CP_API_SRV_INTERNAL_PORT"
else
  API_CONNECT_HOST="${CP_API_SRV_EXTERNAL_HOST:-}"
  API_CONNECT_PORT="${CP_API_SRV_EXTERNAL_PORT:-}"
fi
[ -z "$API_CONNECT_HOST" ] || [ -z "$API_CONNECT_PORT" ] && { echo "Missing API endpoint"; exit 1; }
validate_api_port "$API_CONNECT_PORT" || exit 1

API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API: $API_URL"

duplicate_templates=$(find "$CONFIGS_DIR" -maxdepth 1 -type f -name '*.json' -exec basename {} .json \; | sort | uniq -d || true)
if [ -n "$duplicate_templates" ]; then
  echo "WARNING: Duplicate template names detected in $CONFIGS_DIR: $duplicate_templates"
fi

echo "Fetching notification type-to-id mapping from API..."
notification_settings_list=$(call_api "/notification/settings" "$CP_API_JWT_ADMIN") || {
  echo "ERROR: Unable to get notification settings: $notification_settings_list"
  exit 1
}
if ! echo "$notification_settings_list" | jq -e '.payload | type == "array"' >/dev/null 2>&1; then
  echo "ERROR: /notification/settings response .payload is not an array"
  exit 1
fi

DEPLOYMENT_NAME="${CP_PREF_UI_PIPELINE_DEPLOYMENT_NAME:-Cloud Pipeline}"

# Optional enableOnly list from helmfile postDeploy.emailNotifications (base64 JSON).
EMAIL_NOTIF_SPEC_JSON='{}'
if [ -n "${CP_POST_DEPLOY_EMAIL_NOTIFICATIONS_SPEC_B64:-}" ]; then
  decoded_email_notif_spec=""
  if decoded_email_notif_spec=$(printf '%s' "$CP_POST_DEPLOY_EMAIL_NOTIFICATIONS_SPEC_B64" | base64 -d 2>/dev/null); then
    if echo "$decoded_email_notif_spec" | jq -e 'type == "object"' >/dev/null 2>&1; then
      EMAIL_NOTIF_SPEC_JSON="$decoded_email_notif_spec"
      echo "Loaded postDeploy.emailNotifications from Helmfile."
    else
      echo "WARNING: CP_POST_DEPLOY_EMAIL_NOTIFICATIONS_SPEC_B64 decoded to non-object JSON; ignoring."
    fi
  else
    echo "WARNING: CP_POST_DEPLOY_EMAIL_NOTIFICATIONS_SPEC_B64 is not valid base64."
  fi
  unset decoded_email_notif_spec
fi

EMAIL_NOTIF_ENABLE_ONLY_JSON=$(printf '%s' "$EMAIL_NOTIF_SPEC_JSON" | jq -c '.enableOnly // []')

# CP_DOLLAR is used in templates as ${CP_DOLLAR} to produce a literal $ for the Velocity engine
export CP_DOLLAR='$'

while IFS= read -r config_file; do
  template_name=$(basename "$config_file" .json)

  template_html_file="${CONTENTS_DIR}/${template_name}.html"

  if ! jq -e . "$config_file" >/dev/null 2>&1; then
    echo "ERROR: $config_file is not valid JSON; skipping template $template_name."
    continue
  fi

  if [ ! -f "$template_html_file" ]; then
    echo "WARNING: HTML contents not found for $template_name at $template_html_file; skipping."
    continue
  fi
  if [ ! -s "$template_html_file" ]; then
    echo "WARNING: HTML file for $template_name is empty at $template_html_file; skipping."
    continue
  fi

  template_id=$(echo "$notification_settings_list" | jq -r --arg t "$template_name" '.payload[] | select(.type == $t) | .id')
  if [ -z "$template_id" ] || [ "$template_id" = "null" ]; then
    echo "WARNING: No notification type entry found for \"$template_name\"; skipping."
    continue
  fi

  # enabled=false when enableOnly is non-empty and template is not in it
  merged_config=$(jq \
    --arg t "$template_name" \
    --argjson enable_only "$EMAIL_NOTIF_ENABLE_ONLY_JSON" \
    'if (($enable_only | length) > 0) and (($enable_only | index($t)) == null) then .enabled = false
     else .
     end' \
    "$config_file")

  # envsubst only ${VAR} and bare $CP_* references; bare $CP_* are deployment vars, not Velocity syntax
  envsubst_vars=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$CP_[A-Za-z0-9_]+' "$template_html_file" | sort -u | paste -sd' ' - || true)
  if [ -n "$envsubst_vars" ]; then
    html_body=$(envsubst "$envsubst_vars" <"$template_html_file")
  else
    html_body=$(cat "$template_html_file")
  fi
  # JSON-encode: escape backslashes, double-quotes, and newlines
  body_json=$(printf '%s' "$html_body" | jq -Rs .)

  keep_informed_admins=$(printf '%s' "$merged_config" | jq -r 'if .keepInformedAdmins == false then "false" else "true" end')
  keep_informed_owner=$(printf '%s' "$merged_config" | jq -r 'if .keepInformedOwner == false then "false" else "true" end')
  enabled=$(printf '%s' "$merged_config" | jq -r 'if .enabled == false then "false" else "true" end')
  threshold=$(printf '%s' "$merged_config" | jq -r '.threshold // "-1"')
  resend=$(printf '%s' "$merged_config" | jq -r '.resendDelay // "-1"')

  for _bool_field in "$keep_informed_admins" "$keep_informed_owner" "$enabled"; do
    if [ "$_bool_field" != "true" ] && [ "$_bool_field" != "false" ]; then
      echo "ERROR: $config_file has a boolean field with non-boolean value '$_bool_field'; skipping $template_name."
      continue 2
    fi
  done
  if ! printf '%s' "$threshold" | jq -e 'type == "number"' >/dev/null 2>&1; then
    echo "WARNING: $template_name threshold='$threshold' is not a number; defaulting to -1."
    threshold="-1"
  fi
  if ! printf '%s' "$resend" | jq -e 'type == "number"' >/dev/null 2>&1; then
    echo "WARNING: $template_name resendDelay='$resend' is not a number; defaulting to -1."
    resend="-1"
  fi
  raw_subject=$(printf '%s' "$merged_config" | jq -r '.subject // "Event Notification"')
  subject_json=$(jq -n --arg s "[${DEPLOYMENT_NAME}] ${raw_subject}" '$s')

  # Set template body + subject
  template_body_payload=$(jq -n \
    --argjson id "$template_id" \
    --arg name "$template_name" \
    --argjson body "$body_json" \
    --argjson subject "$subject_json" \
    '{id:$id,name:$name,body:$body,subject:$subject}')

  template_body_response=$(call_api "/notification/template" "$CP_API_JWT_ADMIN" "$template_body_payload") || {
    echo "ERROR: Failed to set template body for $template_name: $template_body_response"
    continue
  }
  echo "Template body set: $template_name"

  # Set notification settings (enabled, thresholds, recipients)
  notification_settings_payload=$(jq -n \
    --argjson id "$template_id" \
    --arg type "$template_name" \
    --argjson keepAdmins "$keep_informed_admins" \
    --argjson keepOwner "$keep_informed_owner" \
    --argjson enabled "$enabled" \
    --argjson threshold "$threshold" \
    --argjson resend "$resend" \
    '{id:$id,informedUserIds:[],keepInformedAdmins:$keepAdmins,keepInformedOwner:$keepOwner,templateId:$id,type:$type,enabled:$enabled,resendDelay:$resend,threshold:$threshold}')

  notification_settings_update_response=$(call_api "/notification/settings" "$CP_API_JWT_ADMIN" "$notification_settings_payload") || {
    echo "ERROR: Failed to set notification settings for $template_name: $notification_settings_update_response"
    continue
  }
  echo "Notification settings set: $template_name (enabled=$enabled)"

done < <(find "$CONFIGS_DIR" -maxdepth 1 -type f -name '*.json' | sort)

echo "Email templates registration finished."
