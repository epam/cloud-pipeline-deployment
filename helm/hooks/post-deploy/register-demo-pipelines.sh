#!/usr/bin/env bash
# Sourced by configure-git.sh after GitLab prefs exist (register-demo-pipelines.sh).
# Runner: tar, envsubst; git runs inside cp-git.
#
# Demo pipe-demo assets: on by default; opt out with CP_REGISTER_HOOK_DEMO_PIPELINES=false.
# System (data_loader + system_jobs): default off; opt in with CP_REGISTER_HOOK_SYSTEM_PIPELINES=true.
set -euo pipefail

NAMESPACE="${1:-}"
export CP_DOLLAR='$'

# shellcheck source=utils/cloud-pipeline-utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/utils/cloud-pipeline-utils.sh"

ASSET_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/assets" && pwd)"

if ! command -v tar >/dev/null 2>&1; then
  echo "WARNING: tar not found — skipping optional hook pipeline registration."
  return 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "WARNING: envsubst not found — skipping optional hook pipeline registration (install gettext)."
  return 1
fi

echo "Loading config from cp-config-global..."
CP_CONFIG_GLOBAL_JSON=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json)
# key filter ensures only valid bash identifiers reach eval; non-conforming keys are skipped
# (e.g. "my.key", "my-key", or "FOO=$(rm -rf /)" would be silently ignored)
eval "$(echo "$CP_CONFIG_GLOBAL_JSON" | jq -r '.data | to_entries[] | select(.value != null and .value != "") | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) | "export \(.key)=\(.value | @sh)"')"

export CP_API_JWT_ADMIN
CP_API_JWT_ADMIN=$(kubectl get secret cp-api-token -n "$NAMESPACE" -o jsonpath='{.data.CP_API_JWT_ADMIN}' | base64 -d)
[ -z "${CP_API_JWT_ADMIN:-}" ] && { echo "ERROR: CP_API_JWT_ADMIN not found in cp-api-token"; exit 1; }

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  API_CONNECT_HOST="$CP_API_SRV_INTERNAL_HOST"
  API_CONNECT_PORT="$CP_API_SRV_INTERNAL_PORT"
else
  API_CONNECT_HOST="${CP_API_SRV_EXTERNAL_HOST:-}"
  API_CONNECT_PORT="${CP_API_SRV_EXTERNAL_PORT:-}"
fi
if [ -z "${API_CONNECT_HOST:-}" ] || [ -z "${API_CONNECT_PORT:-}" ]; then
  echo "ERROR: Missing API endpoint (set CP_API_SRV_INTERNAL_* or CP_API_SRV_EXTERNAL_* in API configmaps)."
  exit 1
fi
validate_api_port "$API_CONNECT_PORT" || exit 1

API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API: $API_URL"

if [ "${CP_REGISTER_HOOK_SYSTEM_PIPELINES:-true}" = "false" ] && [ "${CP_REGISTER_HOOK_DEMO_PIPELINES:-true}" = "false" ]; then
  echo "Registration of demo pipelines is disabled. Exiting."
  exit 0
fi

for _var in GITLAB_ROOT_PASSWORD GITLAB_ROOT_USER CP_GITLAB_INTERNAL_PORT; do
  eval "_val=\${${_var}:-}"
  [ -z "$_val" ] && { echo "ERROR: Required variable $_var is not set in cp-config-global"; exit 1; }
done
unset _var _val

if [ -z "${CP_CLOUD_PLATFORM:-}" ]; then
  echo "WARNING: CP_CLOUD_PLATFORM is not set — demo pipelines will be skipped (no matching instance type)."
fi


# REST helpers (folders, pipelines, grants) for the Pipeline API.
api_get_entity_id() {
  local entity_name="$1"
  local entity_type="$2"
  [ -z "$entity_type" ] && return 1
  entity_type="$(echo "$entity_type" | tr '[:upper:]' '[:lower:]')"
  local entity_json
  entity_json=$(call_api "/${entity_type}/find?id=${entity_name}" "$CP_API_JWT_ADMIN")
  local entity_id
  entity_id=$(echo "$entity_json" | jq -r ".payload.id")
  if [ "$entity_id" ] && [ "$entity_id" != "null" ]; then
    echo "$entity_id"
    return 0
  fi
  return 1
}

api_create_folder() {
  local folder_name="$1"
  local folder_parent_id="$2"
  local payload
  if [ -n "${folder_parent_id:-}" ]; then
    payload=$(jq -n --arg n "$folder_name" --argjson pid "$folder_parent_id" '{name:$n, parentId:$pid}')
  else
    payload=$(jq -n --arg n "$folder_name" '{name:$n}')
  fi
  local create_folder_response
  create_folder_response=$(call_api "/folder/register" "$CP_API_JWT_ADMIN" "$payload")
  if ! check_api_response_status "$create_folder_response"; then
    echo "ERROR: folder/register failed for '$folder_name' (parentId='${folder_parent_id:-root}')"
    echo "$create_folder_response"
    return 1
  fi
  local folder_id
  folder_id=$(echo "$create_folder_response" | jq -r ".payload.id")
  [ "$folder_id" ] && [ "$folder_id" != "null" ]
}

api_create_folder_path() {
  local folder_path="$1"
  [ -z "$folder_path" ] && return 1
  local path_segments current_folder_path="" current_folder_id parent_folder_id=""
  IFS="/" read -ra path_segments <<< "$folder_path"
  for path_segment in "${path_segments[@]}"; do
    [ -z "$path_segment" ] && continue
    current_folder_path="${current_folder_path}/${path_segment}"
    current_folder_path=${current_folder_path#/}
    current_folder_id=$(api_get_entity_id "$current_folder_path" "folder" || true)
    if [ -n "$current_folder_id" ]; then
      parent_folder_id=$current_folder_id
      continue
    fi
    api_create_folder "$path_segment" "$parent_folder_id" || return 1
    parent_folder_id=$(api_get_entity_id "$current_folder_path" "folder") || return 1
  done
  return 0
}

api_create_pipeline() {
  local pipeline_name="$1"
  local pipeline_description="$2"
  local pipeline_parent_id="$3"
  local payload
  if [ "$pipeline_parent_id" ]; then
    payload=$(jq -n --arg n "$pipeline_name" --arg d "$pipeline_description" --argjson pid "$pipeline_parent_id" \
      '{name:$n, description:$d, parentFolderId:$pid}')
  else
    payload=$(jq -n --arg n "$pipeline_name" --arg d "$pipeline_description" '{name:$n, description:$d}')
  fi
  local register_pipeline_response
  register_pipeline_response=$(call_api "/pipeline/register" "$CP_API_JWT_ADMIN" "$payload")
  if ! check_api_response_status "$register_pipeline_response"; then
    echo "ERROR: pipeline/register failed for '$pipeline_name'"
    echo "$register_pipeline_response"
    return 1
  fi
  local pipeline_id
  pipeline_id=$(echo "$register_pipeline_response" | jq -r ".payload.id")
  [ "$pipeline_id" ] && [ "$pipeline_id" != "null" ]
}

api_entity_grant() {
  local entity_id="$1"
  local entity_class="$2"
  local entity_mask="$3"
  local entity_user="$4"
  local payload
  payload=$(jq -n \
    --arg c "$entity_class" \
    --argjson id "$entity_id" \
    --argjson mask "$entity_mask" \
    --argjson principal false \
    --arg u "$entity_user" \
    '{aclClass:$c, id:$id, mask:$mask, principal:$principal, userName:$u}')
  local grant_response
  grant_response=$(call_api "/grant" "$CP_API_JWT_ADMIN" "$payload")
  if ! check_api_response_status "$grant_response"; then
    echo "ERROR: grant failed for entityId=$entity_id class=$entity_class user=$entity_user mask=$entity_mask"
    echo "$grant_response"
    return 1
  fi
  return 0
}

api_release_pipeline() {
  local pipeline_id="$1"
  local pipeline_commit="$2"
  local pipeline_version_name="$3"
  local payload
  payload=$(jq -n --argjson pid "$pipeline_id" --arg c "$pipeline_commit" --arg v "$pipeline_version_name" \
    '{pipelineId:$pid, commit:$c, versionName:$v}')
  local release_pipeline_response
  release_pipeline_response=$(call_api "/pipeline/version/register" "$CP_API_JWT_ADMIN" "$payload")
  if ! check_api_response_status "$release_pipeline_response"; then
    echo "ERROR: pipeline/version/register failed for pipelineId=$pipeline_id commit=$pipeline_commit version=$pipeline_version_name"
    echo "$release_pipeline_response"
    return 1
  fi
  return 0
}

api_get_pipeline_id_by_path() {
  local parent_folder_name="$1"
  local pipeline_name="$2"
  local full_path="${parent_folder_name}/${pipeline_name}"
  local full_path_url_encoded
  full_path_url_encoded=$(printf '%s' "$full_path" | jq -sRr @uri)
  local pipeline_lookup_response
  pipeline_lookup_response=$(call_api "/entities?identifier=${full_path_url_encoded}&aclClass=PIPELINE" "$CP_API_JWT_ADMIN") || true
  local pipeline_id
  pipeline_id=$(echo "$pipeline_lookup_response" | jq -r '.payload.id // empty' 2>/dev/null || true)
  if [ -n "$pipeline_id" ] && [ "$pipeline_id" != "null" ]; then
    echo "$pipeline_id"
    return 0
  fi
  return 1
}

# Stream sources into cp-git, commit/push from inside the pod, then register a pipeline version.
api_register_pipeline_with_git_in_pod() {
  local parent_folder_name="$1"
  local pipeline_name="$2"
  local pipeline_description="$3"
  local pipeline_sources_dir="$4"
  local pipeline_role_grant="${5:-ROLE_USER}"
  local pipeline_role_permissions="${6:-21}"
  local pipeline_version="${7:-v1}"

  if existing_id=$(api_get_entity_id "$pipeline_name" "pipeline" 2>/dev/null); then
    if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
      echo "Pipeline \"$pipeline_name\" already exists (id=$existing_id) — skipping."
      return 0
    fi
  fi

  local parent_folder_id
  parent_folder_id=$(api_get_entity_id "$parent_folder_name" "folder") || {
    echo "ERROR: folder \"$parent_folder_name\" not found"
    return 1
  }

  [ -d "$pipeline_sources_dir" ] || {
    echo "ERROR: sources dir missing: $pipeline_sources_dir"
    return 1
  }

  local pipeline_id=""
  if ! api_create_pipeline "$pipeline_name" "$pipeline_description" "$parent_folder_id"; then
    # Idempotency: on fresh-ish installs API can already contain demo pipelines but /pipeline/find by name
    # may not resolve them reliably. If create fails with duplicate path/name, reuse existing pipeline.
    pipeline_id=$(api_get_pipeline_id_by_path "$parent_folder_name" "$pipeline_name" || true)
    if [ -z "$pipeline_id" ] || [ "$pipeline_id" = "null" ]; then
      pipeline_id=$(api_get_entity_id "$pipeline_name" "pipeline" || true)
    fi
    if [ -z "$pipeline_id" ] || [ "$pipeline_id" = "null" ]; then
      return 1
    fi
    echo "Pipeline \"$pipeline_name\" already exists at path \"$parent_folder_name/$pipeline_name\" (id=$pipeline_id); continuing."
  else
    pipeline_id=$(api_get_pipeline_id_by_path "$parent_folder_name" "$pipeline_name" || true)
    if [ -z "$pipeline_id" ] || [ "$pipeline_id" = "null" ]; then
      pipeline_id=$(api_get_entity_id "$pipeline_name" "pipeline" || true)
    fi
    if [ -z "$pipeline_id" ] || [ "$pipeline_id" = "null" ]; then
      echo "ERROR: could not resolve pipeline id for $pipeline_name"
      return 1
    fi
  fi

  api_entity_grant "$pipeline_id" "PIPELINE" "$pipeline_role_permissions" "$pipeline_role_grant" || {
    echo "WARNING: grant failed for $pipeline_name"
  }

  local repo_slug timestamp_suffix work_dir_in_pod
  repo_slug=$(echo "$pipeline_name" | sed 's/[^0-9a-zA-Z]//g' | tr '[:upper:]' '[:lower:]')
  timestamp_suffix=$(date +%s%N)
  work_dir_in_pod="/tmp/cp-hook-src-${timestamp_suffix}"

  # One exec session: tar on stdin + git in the same pod. Two separate execs can target
  # different cp-git replicas (Deployment) so SRC_DIR from the first exec may not exist on the second.
  local push_attempts push_err_file
  push_attempts="${CP_HOOK_DEMO_PUSH_ATTEMPTS:-5}"
  if ! [[ "$push_attempts" =~ ^[1-9][0-9]*$ ]]; then
    echo "WARNING: CP_HOOK_DEMO_PUSH_ATTEMPTS='$push_attempts' is not a positive integer; using 5."
    push_attempts=5
  fi
  push_err_file=$(mktemp)
  rm -f "$push_err_file"
  for attempt in $(seq 1 "$push_attempts"); do
    clone_dir="/tmp/cp-hook-clone-${timestamp_suffix}-try${attempt}"
    if tar czf - -C "$pipeline_sources_dir" . | kubectl -n "$NAMESPACE" exec -i deployment/cp-git -- \
      env \
        GL_PASS="$GITLAB_ROOT_PASSWORD" \
        GL_PORT="$CP_GITLAB_INTERNAL_PORT" \
        GL_USER="$GITLAB_ROOT_USER" \
        REPO_SLUG="$repo_slug" \
        SRC_DIR="$work_dir_in_pod" \
        CLONE_DIR="$clone_dir" \
        GL_EMAIL="${GITLAB_ROOT_USER}@cloud-pipeline.local" \
      bash -ec '
        set -e
        mkdir -p "$SRC_DIR"
        tar xzf - -C "$SRC_DIR"
        # stdin is still the tarball pipe; detach it before git so clone/config/commit do not read it.
        exec 0</dev/null
        export GIT_SSL_NO_VERIFY=true
        export GIT_TERMINAL_PROMPT=0
        GIT_URL="https://${GL_USER}:${GL_PASS}@127.0.0.1:${GL_PORT}/${GL_USER}/${REPO_SLUG}.git"
        rm -rf -- "$CLONE_DIR"
        # A failed clone can leave a directory without .git; fixed name "regrepo" also collided across retries.
        git clone "$GIT_URL" "$CLONE_DIR"
        test -d "$CLONE_DIR/.git" || { echo "git clone did not create a valid repo under $CLONE_DIR" >&2; exit 1; }
        cd "$CLONE_DIR"
        rm -rf docs src config.json 2>/dev/null || true
        cp -a "$SRC_DIR"/. ./
        rm -f spec.json 2>/dev/null || true
        git config user.email "$GL_EMAIL"
        git config user.name "$GL_USER"
        git add -A
        git commit -m "Initial commit" || git commit -m "Initial commit" --allow-empty
        git push -f
        rm -rf "$SRC_DIR" "$CLONE_DIR"
      ' 2>"$push_err_file"; then
      rm -f "$push_err_file"
      break
    fi
    if [ "$attempt" -eq "$push_attempts" ]; then
      echo "ERROR: git push failed for $pipeline_name after $push_attempts attempt(s)."
      [ -s "$push_err_file" ] && { echo "--- git error ---"; cat "$push_err_file"; echo "-----------------"; }
      rm -f "$push_err_file"
      return 1
    fi
    echo "Retrying git push for $pipeline_name ($attempt/$push_attempts)..."
    sleep 5
  done

  local pipeline_details_json pipeline_commit_id load_attempts
  load_attempts="${CP_HOOK_DEMO_LOAD_ATTEMPTS:-12}"
  if ! [[ "$load_attempts" =~ ^[1-9][0-9]*$ ]]; then
    echo "WARNING: CP_HOOK_DEMO_LOAD_ATTEMPTS='$load_attempts' is not a positive integer; using 12."
    load_attempts=12
  fi
  pipeline_commit_id=""
  for attempt in $(seq 1 "$load_attempts"); do
    pipeline_details_json=$(call_api "/pipeline/${pipeline_id}/load" "$CP_API_JWT_ADMIN") || true
    if check_api_response_status "$pipeline_details_json"; then
      pipeline_commit_id=$(echo "$pipeline_details_json" | jq -r '.payload.currentVersion.commitId // empty')
    fi
    if [ -n "$pipeline_commit_id" ] && [ "$pipeline_commit_id" != "null" ]; then
      break
    fi
    [ "$attempt" -lt "$load_attempts" ] && sleep 5
  done
  [ -n "$pipeline_commit_id" ] && [ "$pipeline_commit_id" != "null" ] || {
    echo "ERROR: missing commitId for $pipeline_name"
    [ -n "${pipeline_details_json:-}" ] && { echo "--- pipeline/load response ---"; echo "$pipeline_details_json"; echo "------------------------------"; }
    return 1
  }
  api_release_pipeline "$pipeline_id" "$pipeline_commit_id" "$pipeline_version" || return 1
  echo "Registered pipeline \"$pipeline_name\" (id=$pipeline_id, version=$pipeline_version)"
  return 0
}

api_upload_demo_pipelines() {
  local demo_root="${1:-$ASSET_ROOT_DIR/pipe-demo}"
  [ -d "$demo_root" ] || {
    echo "WARNING: demo root not found: $demo_root"
    return 0
  }
  local spec_file
  local pipeline_spec
  local parent_folder pipeline_name pipeline_description pipeline_version grant_role grant_permissions instance_type
  local work_dir
  while IFS= read -r -d '' spec_file; do
    work_dir=$(mktemp -d)
    cp -a "$(dirname "$spec_file")/." "$work_dir/"
    if ! jq -e . "$work_dir/spec.json" >/dev/null 2>&1; then
      echo "WARNING: spec.json is not valid JSON in $(dirname "$spec_file"); skipping."
      rm -rf "$work_dir"
      continue
    fi
    pipeline_spec=$(cat "$work_dir/spec.json")
    parent_folder=$(echo "$pipeline_spec"    | jq -r '.parent_folder // "Pipelines"')
    pipeline_name=$(echo "$pipeline_spec"    | jq -r '.name // "NA"')
    pipeline_description=$(echo "$pipeline_spec" | jq -r '.description // ""')
    pipeline_version=$(echo "$pipeline_spec" | jq -r '.version // "v1"')
    grant_role=$(echo "$pipeline_spec"       | jq -r '.grant_role_name // "ROLE_USER"')
    grant_permissions=$(echo "$pipeline_spec" | jq -r '.grant_role_permissions // "21"')
    if ! [[ "$grant_permissions" =~ ^[0-9]+$ ]]; then
      echo "WARNING: spec.json grant_role_permissions='$grant_permissions' is not a non-negative integer; using 21."
      grant_permissions="21"
    fi
    instance_type=$(echo "$pipeline_spec"    | jq -r ".[\"${CP_CLOUD_PLATFORM:-}\"] // \"NA\"")
    if [ -z "$pipeline_description" ]; then
      echo "WARNING: skip demo (no description): $(dirname "$spec_file")"
      rm -rf "$work_dir"
      continue
    fi
    if [ -z "$instance_type" ] || [ "$instance_type" = "NA" ]; then
      echo "WARNING: skip demo (no instance type for ${CP_CLOUD_PLATFORM}): $(dirname "$spec_file")"
      rm -rf "$work_dir"
      continue
    fi
    export CP_CONFIG_JSON_INSTANCE_TYPE="$instance_type"
    envsubst < "$work_dir/config.json" > "$work_dir/config.json.__new" && mv "$work_dir/config.json.__new" "$work_dir/config.json"
    unset CP_CONFIG_JSON_INSTANCE_TYPE
    if ! jq -e . "$work_dir/config.json" >/dev/null 2>&1; then
      echo "WARNING: config.json is invalid JSON after envsubst for '$pipeline_name'; skipping."
      rm -rf "$work_dir"
      continue
    fi

    echo "Demo pipeline: $pipeline_name ($(dirname "$spec_file"))"
    api_create_folder_path "$parent_folder" || {
      echo "WARNING: folder path failed for $pipeline_name"
      rm -rf "$work_dir"
      continue
    }
    api_register_pipeline_with_git_in_pod "$parent_folder" "$pipeline_name" "$pipeline_description" "$work_dir" "$grant_role" "$grant_permissions" "$pipeline_version" || {
      echo "WARNING: demo registration failed: $pipeline_name"
      rm -rf "$work_dir"
      continue
    }
    rm -rf "$work_dir"
  done < <(find "$demo_root" -type f -name spec.json -print0)
}

api_register_data_transfer_pipeline() {
  local role_grant="ROLE_USER"
  local role_permissions="26"
  local pipeline_version
  pipeline_version=$(echo "${CP_API_SRV_SYSTEM_TRANSFER_PIPELINE_VERSION:-v1}" | tr -d '"')
  local source_dir="$ASSET_ROOT_DIR/data_loader"
  [ -f "$source_dir/config.json" ] || {
    echo "WARNING: data_loader assets missing under $source_dir — skip."
    return 0
  }
  local work_dir
  work_dir=$(mktemp -d)
  cp -a "$source_dir/." "$work_dir/"
  envsubst < "$work_dir/config.json" > "$work_dir/config.json.__new" && mv "$work_dir/config.json.__new" "$work_dir/config.json"
  if ! jq -e . "$work_dir/config.json" >/dev/null 2>&1; then
    echo "ERROR: data_loader config.json is invalid JSON after envsubst"
    rm -rf "$work_dir"
    return 1
  fi
  local system_folder="${CP_API_SRV_SYSTEM_FOLDER_NAME:-SYSTEM}"
  local pipeline_friendly_name="${CP_API_SRV_SYSTEM_TRANSFER_PIPELINE_FRIENDLY_NAME:-data-transfer-pipeline}"
  local pipeline_description="${CP_API_SRV_SYSTEM_TRANSFER_PIPELINE_DESCRIPTION:-Data transfer pipeline}"
  api_register_pipeline_with_git_in_pod "$system_folder" "$pipeline_friendly_name" "$pipeline_description" "$work_dir" "$role_grant" "$role_permissions" "$pipeline_version" || {
    rm -rf "$work_dir"
    return 1
  }
  local pipeline_id
  pipeline_id=$(api_get_entity_id "$pipeline_friendly_name" "pipeline") || {
    rm -rf "$work_dir"
    return 1
  }
  api_set_preference "storage.transfer.pipeline.id" "$pipeline_id" "true" || true
  api_set_preference "storage.transfer.pipeline.version" "$pipeline_version" "true" || true
  rm -rf "$work_dir"
  echo "Data transfer pipeline registered (id=$pipeline_id)."
}

api_register_system_jobs_pipeline() {
  local role_grant="ROLE_ADMIN"
  local role_permissions="21"
  local pipeline_version
  pipeline_version=$(echo "${CP_API_SRV_SYSTEM_JOBS_PIPELINE_VERSION:-v1}" | tr -d '"')
  local source_dir="$ASSET_ROOT_DIR/system_jobs"
  [ -f "$source_dir/config.json" ] || {
    echo "WARNING: system_jobs assets missing under $source_dir — skip."
    return 0
  }
  local work_dir
  work_dir=$(mktemp -d)
  cp -a "$source_dir/." "$work_dir/"
  envsubst < "$work_dir/config.json" > "$work_dir/config.json.__new" && mv "$work_dir/config.json.__new" "$work_dir/config.json"
  if ! jq -e . "$work_dir/config.json" >/dev/null 2>&1; then
    echo "ERROR: system_jobs config.json is invalid JSON after envsubst"
    rm -rf "$work_dir"
    return 1
  fi
  local system_folder="${CP_API_SRV_SYSTEM_FOLDER_NAME:-SYSTEM}"
  local pipeline_friendly_name="${CP_API_SRV_SYSTEM_JOBS_PIPELINE_FRIENDLY_NAME:-system-jobs-pipeline}"
  local pipeline_description="${CP_API_SRV_SYSTEM_JOBS_PIPELINE_DESCRIPTION:-System jobs pipeline}"
  api_register_pipeline_with_git_in_pod "$system_folder" "$pipeline_friendly_name" "$pipeline_description" "$work_dir" "$role_grant" "$role_permissions" "$pipeline_version" || {
    rm -rf "$work_dir"
    return 1
  }
  local pipeline_id
  pipeline_id=$(api_get_entity_id "$pipeline_friendly_name" "pipeline") || {
    rm -rf "$work_dir"
    return 1
  }
  api_set_preference "system.jobs.pipeline.id" "$pipeline_id" "true" || true
  rm -rf "$work_dir"
  echo "System jobs pipeline registered (id=$pipeline_id)."
}

if [ "${CP_REGISTER_HOOK_SYSTEM_PIPELINES:-true}" = "true" ]; then
  echo "CP_REGISTER_HOOK_SYSTEM_PIPELINES=true — registering system pipelines..."
  set +e
  api_register_data_transfer_pipeline
  api_register_system_jobs_pipeline
  set -e
fi

if [ "${CP_REGISTER_HOOK_DEMO_PIPELINES:-true}" != "false" ]; then
  echo "Uploading demo pipelines from assets/pipe-demo (set CP_REGISTER_HOOK_DEMO_PIPELINES=false to skip)..."
  set +e
  api_upload_demo_pipelines "$ASSET_ROOT_DIR/pipe-demo"
  set -e
fi
