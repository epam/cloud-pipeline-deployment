#!/bin/bash
# Helmfile postsync: set system API preferences. Args: NAMESPACE
set -euo pipefail

NAMESPACE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/cloud-pipeline-utils.sh
source "$SCRIPT_DIR/utils/cloud-pipeline-utils.sh"

[ -z "$NAMESPACE" ] && usage

for cmd in kubectl curl jq base64 find; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

echo "Loading config from cp-config-global..."
CP_CONFIG_GLOBAL_JSON=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json)
# key filter ensures only valid bash identifiers reach eval; non-conforming keys are skipped
# (e.g. "my.key", "my-key", or "FOO=$(rm -rf /)" would be silently ignored)
eval "$(echo "$CP_CONFIG_GLOBAL_JSON" | jq -r '.data | to_entries[] | select(.value != null and .value != "") | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) | "export \(.key)=\(.value | @sh)"')"

# Browser-friendly external API HTTPS origin for preference text (omit default :443).
external_api_port="${CP_API_SRV_EXTERNAL_PORT:-443}"
if [ -n "${CP_API_SRV_EXTERNAL_HOST:-}" ]; then
  if [ "$external_api_port" = "443" ]; then
    export CP_API_SRV_EXTERNAL_HTTPS_BASE="https://${CP_API_SRV_EXTERNAL_HOST}"
  else
    export CP_API_SRV_EXTERNAL_HTTPS_BASE="https://${CP_API_SRV_EXTERNAL_HOST}:${external_api_port}"
  fi
else
  export CP_API_SRV_EXTERNAL_HTTPS_BASE=""
fi
unset external_api_port

# Preserve literal $ in templates (e.g. $PATH) when running envsubst on preference JSON.
export CP_DOLLAR='$'

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
if [ -z "$API_CONNECT_HOST" ] || [ -z "$API_CONNECT_PORT" ]; then
  echo "Missing API endpoint (internal or external host/port)"
  exit 1
fi
validate_api_port "$API_CONNECT_PORT" || exit 1

API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API: $API_URL"

# Global preference registry: JSON object {pref_name: extended_format_entry}.
# Populated in phases by api_setup_base_preferences, then flushed once by prefs_registry_apply.
__PREF_REGISTRY__='{}'

function prefs_registry_reset {
  __PREF_REGISTRY__='{}'
}

# Merge a JSON dict into the registry; incoming entries win on conflict.
function prefs_registry_merge_json {
  local incoming="$1"
  __PREF_REGISTRY__=$(printf '%s\n%s' "$__PREF_REGISTRY__" "$incoming" | jq -sc '.[0] * .[1]')
}

# Add or overwrite a single computed preference.
# value_str is the already-serialized string that will be sent to the API as the preference value.
function prefs_registry_set {
  local name="$1" value_str="$2" visible="$3"
  local vis_bool
  [ "$visible" = "true" ] && vis_bool=true || vis_bool=false
  __PREF_REGISTRY__=$(printf '%s' "$__PREF_REGISTRY__" | \
    jq -c --arg n "$name" --arg v "$value_str" --argjson vis "$vis_bool" \
    '.[$n] = {value: $v, visible: $vis}')
}

function cp_pref_var_to_preference_name {
  local var_name="$1"
  local pref_suffix

  # Generic conversion:
  #   CP_PREF_UI_PIPELINE_DEPLOYMENT_NAME -> ui.pipeline.deployment.name
  pref_suffix="${var_name#CP_PREF_}"
  printf '%s' "$pref_suffix" | tr '[:upper:]' '[:lower:]' | tr '_' '.'
}

function prefs_registry_visible_for {
  local pref_name="$1"
  printf '%s' "$__PREF_REGISTRY__" | jq -r --arg n "$pref_name" '
    if has($n) and (.[$n] | type) == "object" and (.[$n] | has("visible")) then
      .[$n].visible | tostring
    else
      "true"
    end'
}

function queue_preference_override {
  local pref_name="$1" pref_value="$2"
  local pref_visible
  pref_visible=$(prefs_registry_visible_for "$pref_name")
  prefs_registry_set "$pref_name" "$pref_value" "$pref_visible"
}

function queue_cp_pref_variable {
  local var_name="$1" pref_value="$2"
  local pref_name

  pref_name=$(cp_pref_var_to_preference_name "$var_name")
  echo "Queueing preference from cp-config-global: $var_name -> $pref_name"
  queue_preference_override "$pref_name" "$pref_value"
  return 0
}

function queue_cp_pref_preferences_from_configmap {
  local config_json="$1"
  local item var_name pref_value discovered_count
  discovered_count=0

  echo "Loading CP_PREF_* values from cp-config-global..."
  while IFS= read -r item; do
    var_name=$(printf '%s' "$item" | jq -r '.key')
    pref_value=$(printf '%s' "$item" | jq -r '.value')
    queue_cp_pref_variable "$var_name" "$pref_value"
    discovered_count=$((discovered_count + 1))
  done < <(
    printf '%s' "$config_json" | jq -c '
      (.data // {})
      | to_entries[]
      | select(.key | startswith("CP_PREF_"))
      | select(.value != null and .value != "")
    '
  )

  echo "Discovered $discovered_count CP_PREF_* values in cp-config-global."
}

# Iterate the accumulated registry and POST every preference to the API in one pass.
function prefs_registry_apply {
  local total
  total=$(printf '%s' "$__PREF_REGISTRY__" | jq 'keys | length')
  echo "Applying $total accumulated preferences to the API..."

  local pref_name entry visible val_type pref_value
  while IFS= read -r pref_name; do
    entry=$(printf '%s' "$__PREF_REGISTRY__" | jq -c --arg k "$pref_name" '.[$k]')

    if printf '%s' "$entry" | jq -e 'type == "object" and has("value") and has("visible") and (.visible | type) == "boolean"' >/dev/null 2>&1; then
      visible=$(printf '%s' "$entry" | jq -r '.visible | tostring')
      entry=$(printf '%s' "$entry" | jq -c '.value')
    else
      visible="false"
    fi

    val_type=$(printf '%s' "$entry" | jq -r 'type')
    case "$val_type" in
      string)         pref_value=$(printf '%s' "$entry" | jq -r .) ;;
      number|boolean) pref_value=$(printf '%s' "$entry" | jq -r 'tostring') ;;
      object|array)   pref_value=$(printf '%s' "$entry" | jq -c .) ;;
      null)           echo "WARNING: null value for preference '$pref_name'; skipping."; continue ;;
      *)              echo "WARNING: unknown type '$val_type' for preference '$pref_name'; skipping."; continue ;;
    esac

    echo "Applying preference: $pref_name (visible=$visible)"
    if ! api_apply_preference "$pref_name" "$pref_value" "$visible"; then
      echo "ERROR: Failed to set preference '$pref_name'"
      return 1
    fi
  done < <(printf '%s' "$__PREF_REGISTRY__" | jq -r 'keys[]')
}

# Merge a non-empty list of validated JSON-object files into the global preference registry.
# Applies envsubst on ${VAR} references only (not bare $VAR or UI {placeholder} patterns).
function _prefs_registry_load_files {
  local merged merged_text envsubst_vars
  merged=$(jq -s 'reduce .[] as $f ({}; . * $f)' "$@")

  merged_text=$(printf '%s' "$merged")
  envsubst_vars=$(printf '%s' "$merged_text" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | sort -u | paste -sd' ' -)
  if [ -n "$envsubst_vars" ]; then
    merged_text=$(printf '%s' "$merged_text" | envsubst "$envsubst_vars")
  fi
  if ! merged=$(printf '%s' "$merged_text" | jq -e .); then
    echo "ERROR: Preferences JSON invalid after envsubst — check for unset or mis-formatted variables."
    return 1
  fi

  prefs_registry_merge_json "$merged"
}

# Accumulate all *.json preference files from a directory into the registry.
# File format: top-level JSON object; values use extended format {"value": <any JSON>, "visible": <bool>}.
# "visible" defaults to false when absent. envsubst restricted to ${VAR} form only.
function api_load_prefs_dir {
  local root_path="$1"
  if [ ! -d "$root_path" ]; then
    echo "ERROR: Preferences directory $root_path does not exist."
    return 1
  fi

  local json_files=()
  while IFS= read -r -d '' f; do
    json_files+=("$f")
  done < <(find "$root_path" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)

  if [ ${#json_files[@]} -eq 0 ]; then
    echo "WARNING: No JSON preference files found in $root_path"
    return 0
  fi

  local f
  for f in "${json_files[@]}"; do
    if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
      echo "ERROR: $f is not a JSON object — each preference file must be a top-level {} dict."
      return 1
    fi
  done

  _prefs_registry_load_files "${json_files[@]}"
}

# Accumulate a single JSON preference file into the registry. Same format as api_load_prefs_dir files.
function api_load_prefs_file {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "ERROR: Preference file not found: $file"
    return 1
  fi
  if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    echo "ERROR: $file is not a JSON object — preference file must be a top-level {} dict."
    return 1
  fi
  _prefs_registry_load_files "$file"
}

function api_setup_base_preferences {
  prefs_registry_reset

  # Phase 1: file-based defaults (lowest priority)
  local default_prefs_dir="${CP_PREFERENCES_CONFIG_PATH:-$SCRIPT_DIR/assets/preferences}"
  if [ -d "$default_prefs_dir" ]; then
    echo "Loading preferences from $default_prefs_dir..."
    api_load_prefs_dir "$default_prefs_dir" || return 1
  elif [ -n "${CP_PREFERENCES_CONFIG_PATH:-}" ]; then
    echo "ERROR: CP_PREFERENCES_CONFIG_PATH is not a directory: $default_prefs_dir"
    return 1
  else
    echo "WARNING: Default preferences directory not found: $default_prefs_dir — skipping (deploy hooks/assets beside this script or set CP_PREFERENCES_CONFIG_PATH)."
  fi

  if [ -n "${CP_CLOUD_PREFERENCES_CONFIG_PATH:-}" ]; then
    if [ -d "$CP_CLOUD_PREFERENCES_CONFIG_PATH" ]; then
      echo "Loading preferences from cloud path $CP_CLOUD_PREFERENCES_CONFIG_PATH..."
      api_load_prefs_dir "$CP_CLOUD_PREFERENCES_CONFIG_PATH" || return 1
    else
      echo "WARNING: CP_CLOUD_PREFERENCES_CONFIG_PATH not a directory: $CP_CLOUD_PREFERENCES_CONFIG_PATH (skipping)."
    fi
  fi

  # Phase 2: user overrides — win over file-based defaults
  if [ -n "${CP_SYSTEM_PREFERENCE_CONFIG:-}" ]; then
    if [ -f "${CP_SYSTEM_PREFERENCE_CONFIG}" ]; then
      echo "Loading user preference overrides from file: ${CP_SYSTEM_PREFERENCE_CONFIG}"
      api_load_prefs_file "${CP_SYSTEM_PREFERENCE_CONFIG}" || return 1
    elif [ -d "${CP_SYSTEM_PREFERENCE_CONFIG}" ]; then
      echo "Loading user preference overrides from directory: ${CP_SYSTEM_PREFERENCE_CONFIG}"
      api_load_prefs_dir "${CP_SYSTEM_PREFERENCE_CONFIG}" || return 1
    else
      echo "ERROR: CP_SYSTEM_PREFERENCE_CONFIG='${CP_SYSTEM_PREFERENCE_CONFIG}' is neither a file nor a directory."
      return 1
    fi
  fi

  # Phase 3: CP_PREF_* values from cp-config-global — win over file-based sources above
  queue_cp_pref_preferences_from_configmap "$CP_CONFIG_GLOBAL_JSON" || return 1

  # Phase 4: computed preferences — win over file-based and direct CP_PREF_* sources above

  # Keep system.default.docker.registry.id in shell:
  # the value must be resolved dynamically via API lookup after the registry exists.
  if [ -n "${CP_DOCKER_INTERNAL_HOST:-}" ] && [ -n "${CP_DOCKER_INTERNAL_PORT:-}" ]; then
    local docker_registry_identifier docker_registry_id
    docker_registry_identifier="${CP_DOCKER_INTERNAL_HOST}:${CP_DOCKER_INTERNAL_PORT}"
    if docker_registry_id=$(api_get_docker_registry_id "$docker_registry_identifier"); then
      prefs_registry_set "system.default.docker.registry.id" "$docker_registry_id" "true"
      echo "Queued preference system.default.docker.registry.id=$docker_registry_id (registry $docker_registry_identifier)."
    else
      echo "WARNING: Docker registry not found in API for $docker_registry_identifier; skipping system.default.docker.registry.id (ensure cp-docker-registry post-deploy completed)."
    fi
  else
    echo "WARNING: CP_DOCKER_INTERNAL_HOST or CP_DOCKER_INTERNAL_PORT unset; skipping system.default.docker.registry.id."
  fi

  # Keep commit.deploy.key in shell:
  # file-based templates would still load an empty string when the key is unset,
  # but this preference must stay conditional until template loading can skip empty values.
  if [ "${CP_PREF_COMMIT_DEPLOY_KEY:-}" ]; then
    prefs_registry_set "commit.deploy.key" "${CP_PREF_COMMIT_DEPLOY_KEY}" "false"
  else
    echo "\"commit.deploy.key\" preference is NOT set. Runs COMMIT will NOT be available. Set CP_PREF_COMMIT_DEPLOY_KEY in cp-api-srv config."
  fi

  # Phase 5: apply the complete accumulated registry to the API
  prefs_registry_apply || return 1
}

echo "Setting system preferences ..."
api_setup_base_preferences

echo "Post-deploy API preferences upload finished."
