#!/usr/bin/env bash
# Helm post-install/post-upgrade Job on cp-git. Registers GitLab in the API (URLs, token, API version).
#
# GitLab REST uses the same URL pattern as CMBI deploy/contents/install/app/install.sh:
#   https://$CP_GITLAB_INTERNAL_HOST:$CP_GITLAB_EXTERNAL_PORT (requires the hook host to reach that URL).
# Override: CP_GITLAB_REST_URL=https://host:port (no trailing slash).
# If CP_GITLAB_INTERNAL_HOST is *.svc.cluster.local and CP_GITLAB_EXTERNAL_HOST is set, uses external host:port for REST.
#
# Root token: gitlab-rails runner via kubectl exec. Legacy session: CP_GITLAB_USE_LEGACY_SESSION_API=true.
set -euo pipefail

NAMESPACE="${1:-${NAMESPACE:-}}"

# shellcheck source=cloud-pipeline-utils.sh
source /scripts/cloud-pipeline-utils.sh

function api_preference_drop_array {
  unset __PREFERENCES_ARRAY_CURRENT__
  export __PREFERENCES_ARRAY_CURRENT__=""
}

function api_preference_get_array {
  echo "${__PREFERENCES_ARRAY_CURRENT__:-}"
}

function api_preference_append_array {
  local pref_payload="$1"
  [ -z "$pref_payload" ] && return
  local delimiter=""
  [ -n "${__PREFERENCES_ARRAY_CURRENT__:-}" ] && delimiter=","
  __PREFERENCES_ARRAY_CURRENT__="${__PREFERENCES_ARRAY_CURRENT__:-}${delimiter}${pref_payload}"
}

function api_flush_preferences_array {
  local payload resp rc
  payload="[ $(api_preference_get_array) ]"
  resp=$(call_api "/preferences" "$CP_API_JWT_ADMIN" "$payload")
  rc=$?
  api_preference_drop_array
  if [ $rc -ne 0 ]; then
    echo "ERROR: Failed to set preferences batch"
    echo "$resp"
  fi
  return $rc
}

function gitlab_root_token_via_rails {
  local raw out
  raw=$(openssl rand -hex 10)
  [ "${#raw}" -eq 20 ] || return 1
  out=$(kubectl -n "$NAMESPACE" exec deployment/cp-git -- \
    env "GL_USER=${GITLAB_ROOT_USER}" "CP_HOOK_PAT=${raw}" \
    gitlab-rails runner \
    'u = User.find_by_username(ENV["GL_USER"]); raise "root user not found" unless u; t = u.personal_access_tokens.create!(name: "cloud-pipeline-helm-" + Time.now.to_f.to_s + "-" + rand(1_000_000_000).to_s, scopes: ["api"], expires_at: 365.days.from_now); t.set_token(ENV["CP_HOOK_PAT"]); t.save!; puts "CP_TOKEN=" + ENV["CP_HOOK_PAT"]' \
    2>/dev/null | sed -n 's/^CP_TOKEN=//p' | tail -n1 | tr -d '\r')
  [ -n "$out" ] && [ "$out" = "$raw" ] && echo "$out"
}

function gitlab_root_token_via_session {
  local session_json
  session_json=$(curl -k -s -S -X POST \
    -F "login=${GITLAB_ROOT_USER}" -F "password=${GITLAB_ROOT_PASSWORD}" \
    "${GITLAB_REST_BASE}/api/v4/session" 2>/dev/null || true)
  [ -z "$session_json" ] && return 0
  if ! echo "$session_json" | jq -e . >/dev/null 2>&1; then
    echo "WARNING: GitLab /api/v4/session returned non-JSON (edge/DNS not ready or HTML error page)." >&2
    printf '%s\n' "$session_json" | head -c 500 >&2
    echo >&2
    echo ""
    return 0
  fi
  echo "$session_json" | jq -r '.private_token // empty'
}

function gitlab_create_impersonation_token {
  # External GITLAB_REST_BASE may return HTML or plain text until edge/DNS is ready — jq would fail with "Invalid numeric literal".
  local max_attempts="${CP_GITLAB_IMP_TOKEN_ATTEMPTS:-30}"
  local poll_interval_seconds="${CP_GITLAB_POLL_INTERVAL:-5}"
  local attempt=0
  local impersonation_token_response token_value token_expiry_date warned_missing_expiry

  warned_missing_expiry=""
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    if [ "${CP_GITLAB_VERSION:-}" = "17" ]; then
      token_expiry_date=$(date -u -d '+1 year' +%Y-%m-%d 2>/dev/null || date -u -v+1y +%Y-%m-%d 2>/dev/null || echo "")
      if [ -n "$token_expiry_date" ]; then
        impersonation_token_response=$(curl -k -s -S -X POST -H "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}" \
          -F name=CloudPipeline -F "scopes[]=api" -F "expires_at=${token_expiry_date}" \
          "${GITLAB_REST_BASE}/api/v4/users/1/impersonation_tokens" 2>/dev/null || true)
      else
        if [ -z "$warned_missing_expiry" ]; then
          echo "WARNING: could not compute expires_at for GitLab 17; creating impersonation token without expiry field." >&2
          warned_missing_expiry=1
        fi
        impersonation_token_response=$(curl -k -s -S -X POST -H "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}" \
          -F name=CloudPipeline -F "scopes[]=api" \
          "${GITLAB_REST_BASE}/api/v4/users/1/impersonation_tokens" 2>/dev/null || true)
      fi
    else
      impersonation_token_response=$(curl -k -s -S -X POST -H "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}" \
        -F name=CloudPipeline -F "scopes[]=api" \
        "${GITLAB_REST_BASE}/api/v4/users/1/impersonation_tokens" 2>/dev/null || true)
    fi

    if [ -z "$impersonation_token_response" ]; then
      echo "GitLab impersonation_tokens: empty response (attempt ${attempt}/${max_attempts})." >&2
    elif echo "$impersonation_token_response" | jq -e . >/dev/null 2>&1; then
      token_value=$(echo "$impersonation_token_response" | jq -r '.token // empty')
      if [ -n "$token_value" ] && [ "$token_value" != "null" ]; then
        echo "$token_value"
        return 0
      fi
      echo "GitLab impersonation_tokens JSON without .token (attempt ${attempt}/${max_attempts}): $(echo "$impersonation_token_response" | jq -c . 2>/dev/null)" >&2
    else
      echo "GitLab impersonation_tokens non-JSON response (attempt ${attempt}/${max_attempts}); body preview:" >&2
      printf '%s\n' "$impersonation_token_response" | head -c 1200 >&2
      echo >&2
    fi
    sleep "$poll_interval_seconds"
  done
  return 1
}

[ -z "$NAMESPACE" ] && usage

for cmd in kubectl curl jq base64 openssl; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

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

API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API: $API_URL"

echo "Checking if git.token and git.host are already set..."
existing_git_token=$(curl -k -s -H "Authorization: Bearer $CP_API_JWT_ADMIN" "${API_URL}/preferences/git.token" \
  | jq -r '.payload.value // empty' 2>/dev/null || true)
existing_git_host=$(curl -k -s -H "Authorization: Bearer $CP_API_JWT_ADMIN" "${API_URL}/preferences/git.host" \
  | jq -r '.payload.value // empty' 2>/dev/null || true)
if [ -n "$existing_git_token" ] && [ -n "$existing_git_host" ]; then
  echo "git.token and git.host are already configured — skipping GitLab registration."
  exit 0
fi
unset existing_git_token existing_git_host

if [ -z "${CP_GITLAB_EXTERNAL_HOST:-}" ]; then
  echo "WARNING: CP_GITLAB_EXTERNAL_HOST is not set — skipping GitLab API registration."
  exit 0
fi

if [ -z "${GITLAB_ROOT_PASSWORD:-}" ]; then
  echo "WARNING: GITLAB_ROOT_PASSWORD is not set (e.g. in cp-config-global) — skipping GitLab API registration (set password for root or export CP_SKIP_GITLAB_API_REGISTER=true before helmfile)."
  exit 0
fi

GITLAB_ROOT_USER="${GITLAB_ROOT_USER:-root}"
CP_GITLAB_EXTERNAL_PORT="${CP_GITLAB_EXTERNAL_PORT:-443}"
CP_GITLAB_INTERNAL_PORT="${CP_GITLAB_INTERNAL_PORT:-443}"
CP_GITLAB_INTERNAL_HOST="${CP_GITLAB_INTERNAL_HOST:-cp-git.${NAMESPACE}.svc.cluster.local}"

if [ -n "${CP_GITLAB_REST_URL:-}" ]; then
  GITLAB_REST_BASE="${CP_GITLAB_REST_URL%/}"
elif [[ "${CP_GITLAB_INTERNAL_HOST:-}" == *.svc.cluster.local ]] && [ -n "${CP_GITLAB_EXTERNAL_HOST:-}" ]; then
  GITLAB_REST_BASE="https://${CP_GITLAB_EXTERNAL_HOST}:${CP_GITLAB_EXTERNAL_PORT}"
else
  GITLAB_REST_BASE="https://${CP_GITLAB_INTERNAL_HOST}:${CP_GITLAB_EXTERNAL_PORT}"
fi
echo "GitLab REST: ${GITLAB_REST_BASE}"

echo "Waiting for GitLab API token (rails PAT, legacy session optional)..."
GITLAB_ROOT_TOKEN=""
root_token_attempts="${CP_GITLAB_ROOT_TOKEN_ATTEMPTS:-36}"
while [ -z "$GITLAB_ROOT_TOKEN" ] || [ "$GITLAB_ROOT_TOKEN" = "null" ]; do
  if [ "$root_token_attempts" -le 0 ]; then
    echo "ERROR: Could not obtain GitLab root API token after retries (rails PAT or session)."
    exit 1
  fi
  GITLAB_ROOT_TOKEN=""
  if [ "${CP_GITLAB_USE_LEGACY_SESSION_API:-}" != "true" ]; then
    GITLAB_ROOT_TOKEN=$(gitlab_root_token_via_rails || true)
  fi
  if [ -z "$GITLAB_ROOT_TOKEN" ] || [ "$GITLAB_ROOT_TOKEN" = "null" ]; then
    session_token=$(gitlab_root_token_via_session || true)
    if [ -n "$session_token" ] && [ "$session_token" != "null" ]; then
      GITLAB_ROOT_TOKEN="$session_token"
    fi
  fi
  if [ -z "$GITLAB_ROOT_TOKEN" ] || [ "$GITLAB_ROOT_TOKEN" = "null" ]; then
    sleep "${CP_GITLAB_POLL_INTERVAL:-5}"
  fi
  root_token_attempts=$((root_token_attempts - 1))
done

echo "Got GitLab root token (len=${#GITLAB_ROOT_TOKEN})."
sleep "${CP_GITLAB_INIT_TIMEOUT:-30}"

echo "Creating impersonation token..."
GITLAB_IMP_TOKEN=$(gitlab_create_impersonation_token) || GITLAB_IMP_TOKEN=""

if [ -z "$GITLAB_IMP_TOKEN" ] || [ "$GITLAB_IMP_TOKEN" = "null" ]; then
  echo "ERROR: Failed to create GitLab impersonation token."
  exit 1
fi

if [ "${CP_GITLAB_VERSION:-}" != "9" ]; then
  echo "Applying GitLab application settings (webhooks / signup)..."
  curl -k -s -S -X PUT -H "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}" \
    "${GITLAB_REST_BASE}/api/v4/application/settings?allow_local_requests_from_web_hooks_and_services=true"
  curl -k -s -S -X PUT -H "PRIVATE-TOKEN: ${GITLAB_ROOT_TOKEN}" \
    "${GITLAB_REST_BASE}/api/v4/application/settings?signup_enabled=false"
fi

echo "Registering GitLab integration in API preferences..."
api_preference_drop_array
api_preference_append_array "$(api_preference_get_templated "git.external.url" "https://${CP_GITLAB_EXTERNAL_HOST}:${CP_GITLAB_EXTERNAL_PORT}" "true")"
api_preference_append_array "$(api_preference_get_templated "git.user.name" "$GITLAB_ROOT_USER" "false")"
api_preference_append_array "$(api_preference_get_templated "git.token" "$GITLAB_IMP_TOKEN" "false")"
api_preference_append_array "$(api_preference_get_templated "git.user.id" "1" "false")"
api_preference_append_array "$(api_preference_get_templated "git.host" "https://${CP_GITLAB_INTERNAL_HOST}:${CP_GITLAB_INTERNAL_PORT}" "true")"
if [ "${CP_GITLAB_VERSION:-}" != "9" ]; then
  gitlab_api_version="${CP_GITLAB_API_VERSION:-v4}"
  api_preference_append_array "$(api_preference_get_templated "git.gitlab.api.version" "$gitlab_api_version" "false")"
fi
api_flush_preferences_array

echo "GitLab API preferences registration finished."

if [ "${CP_GITLAB_NORMALIZE_ADMIN_DISPLAY_NAME:-true}" = "true" ] && [ -n "${CP_DEFAULT_ADMIN_NAME:-}" ]; then
  if [[ "${CP_DEFAULT_ADMIN_NAME}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "Normalizing GitLab user.name (profile) for '${CP_DEFAULT_ADMIN_NAME}' to match username..."
    kubectl -n "$NAMESPACE" exec deployment/cp-git -- \
      env ADMIN="$CP_DEFAULT_ADMIN_NAME" \
      gitlab-rails runner 'u = User.find_by_username(ENV["ADMIN"]); u&.update!(name: ENV["ADMIN"]) if u' \
      || echo "WARNING: could not normalize GitLab display name (user may not exist until first SSO login)."
  else
    echo "WARNING: CP_DEFAULT_ADMIN_NAME is not a simple identifier — skipping GitLab name normalize."
  fi
fi
