#!/bin/bash
# Shared utilities sourced by all helmfile hook scripts.
# Requires: $API_URL and $CP_API_JWT_ADMIN set before calling any API function.

function usage {
  echo "Usage: $0 NAMESPACE"
  exit 1
}

function validate_api_port {
  local port="${1:-}"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "ERROR: API port '$port' is not a valid TCP port (1-65535)"
    return 1
  fi
}

function check_api_response_status {
  local response_json="$1"
  local response_status
  response_status=$(echo "$response_json" | jq -r ".status")
  if [ "$response_status" = "ERROR" ] || [[ "$response_status" =~ ^[45][0-9][0-9]$ ]]; then
    return 1
  fi
  return 0
}

function call_api {
  local api_endpoint="$1"
  local jwt_token="$2"
  local payload="${3:-}"
  local is_file="${4:-}"
  local response=""
  if [ -n "$is_file" ]; then
    response=$(curl -X POST -k -s -H "Authorization: Bearer $jwt_token" -F "file=@$payload" "${API_URL}${api_endpoint}")
  elif [ -n "$payload" ]; then
    response=$(curl -X POST -k -s -H 'Content-Type: application/json' -H "Authorization: Bearer $jwt_token" -d "$payload" "${API_URL}${api_endpoint}")
  else
    response=$(curl -X GET -k -s -H "Authorization: Bearer $jwt_token" "${API_URL}${api_endpoint}")
  fi
  if [ -z "$response" ]; then
    echo "ERROR: Empty response from API: ${API_URL}${api_endpoint}" >&2
    return 1
  fi
  if ! echo "$response" | jq -e . >/dev/null 2>&1; then
    echo "ERROR: Non-JSON response from API (${API_URL}${api_endpoint}): ${response:0:200}" >&2
    return 1
  fi
  echo "$response"
  check_api_response_status "$response"
  return $?
}

function call_api_put {
  local api_endpoint="$1"
  local jwt_token="$2"
  local payload="$3"
  local response
  response=$(curl -X PUT -k -s -H 'Content-Type: application/json' -H "Authorization: Bearer $jwt_token" -d "$payload" "${API_URL}${api_endpoint}")
  echo "$response"
  check_api_response_status "$response"
  return $?
}

function api_preference_get_templated {
  local pref_name="$1"
  local pref_value="$2"
  local pref_visible="$3"
  jq -n --arg n "$pref_name" --arg v "$pref_value" --arg vis "$pref_visible" '{name:$n, value:$v, visible:$vis}'
}

function api_set_preference {
  local pref_name="$1"
  local pref_value="$2"
  local pref_visible="${3:-true}"
  local payload set_preference_response rc
  payload=$(jq -n --arg n "$pref_name" --arg v "$pref_value" --arg vis "$pref_visible" '[{name:$n, value:$v, visible:$vis}]')
  set_preference_response=$(call_api "/preferences" "$CP_API_JWT_ADMIN" "$payload")
  rc=$?
  [ $rc -ne 0 ] && echo "ERROR: Failed to set preference '$pref_name': $set_preference_response"
  return $rc
}

# Apply one preference to the API, but tolerate CP_PREF_* keys that are
# deployment settings rather than real API preferences.
function api_apply_preference {
  local pref_name="$1" pref_value="$2" pref_visible="${3:-true}"
  local payload response message

  payload="[$(api_preference_get_templated "$pref_name" "$pref_value" "$pref_visible")]"

  if response=$(call_api "/preferences" "$CP_API_JWT_ADMIN" "$payload"); then
    return 0
  fi

  message=$(printf '%s' "$response" | jq -r '.message // ""' 2>/dev/null || true)
  # This is the backend message for names that are not registered API preferences.
  if [[ "$message" == *"No preference type specified"* ]]; then
    echo "WARNING: API does not recognize preference '$pref_name'; skipping it. This CP_PREF_* key is likely a deployment-only setting." >&2
    return 0
  fi

  echo "ERROR: Failed to set preference '$pref_name': $response" >&2
  return 1
}

# Polls ${API_URL}/whoami until the API responds successfully.
function api_wait_for_ready {
  local max_attempts="${1:-30}"
  local sleep_sec="${2:-10}"
  local attempt health_response response_status
  for attempt in $(seq 1 "$max_attempts"); do
    health_response=$(curl -k -sS --connect-timeout 10 --max-time 30 \
        -H "Authorization: Bearer ${CP_API_JWT_ADMIN}" \
        "${API_URL}/whoami" 2>/dev/null || true)
    response_status=$(echo "$health_response" | jq -r '.status // ""' 2>/dev/null || true)
    if [ -n "$response_status" ] && [ "$response_status" != "ERROR" ] && [[ "$response_status" != 4* ]]; then
      echo "api_wait_for_ready: API is available."
      return 0
    fi
    echo "api_wait_for_ready: attempt ${attempt}/${max_attempts}: not ready; retrying in ${sleep_sec}s..."
    sleep "$sleep_sec"
  done
  echo "ERROR: api_wait_for_ready: API did not become available after ${max_attempts} attempts."
  return 1
}

# GET /<type>/find?id=<name> → echoes .payload.id; returns 1 if not found.
function api_get_entity_id {
  local entity_name="$1"
  local entity_type
  entity_type=$(echo "${2:-}" | tr '[:upper:]' '[:lower:]')
  local entity_lookup_response entity_id
  entity_lookup_response=$(call_api "/${entity_type}/find?id=${entity_name}" "$CP_API_JWT_ADMIN" "" || true)
  entity_id=$(echo "$entity_lookup_response" | jq -r '.payload.id // empty')
  if [ -n "$entity_id" ] && [ "$entity_id" != "null" ]; then
    echo "$entity_id"
    return 0
  fi
  return 1
}

# POST /filesharemount to register a fileshare mount on an existing cloud region.
function api_register_fileshare {
  local region_id="$1"
  local mount_point="$2"
  local mount_type="${3:-}"
  local mount_options="${4:-}"
  local payload response rc
  payload=$(jq -nc \
    --argjson rid "$region_id" \
    --arg root "$mount_point" \
    --arg type "$mount_type" \
    --arg opts "$mount_options" \
    '{"regionId":$rid,"mountRoot":$root,"mountType":$type,"mountOptions":$opts}')
  response=$(call_api "/filesharemount" "$CP_API_JWT_ADMIN" "$payload" || true)
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "ERROR: api_register_fileshare: failed for $mount_point: $response" >&2
  fi
  return $rc
}

# GET /entities?identifier=<region_name>&aclClass=CLOUD_REGION → echoes .payload.id; returns 1 if not found.
function api_get_cloud_region_id {
  local region_name="$1"
  local encoded_name response region_id
  [ -z "$region_name" ] && return 1
  encoded_name=$(printf '%s' "$region_name" | jq -sRr @uri)
  response=$(call_api "/entities?identifier=${encoded_name}&aclClass=CLOUD_REGION" "$CP_API_JWT_ADMIN" "" || true)
  region_id=$(echo "$response" | jq -r '.payload.id // empty')
  if [ -n "$region_id" ] && [ "$region_id" != "null" ]; then
    echo "$region_id"
    return 0
  fi
  return 1
}

# GET /entities?identifier=<id>&aclClass=DOCKER_REGISTRY → echoes .payload.id; returns 1 if not found.
function api_get_docker_registry_id {
  local identifier="$1"
  local encoded_identifier response registry_id
  [ -z "$identifier" ] && return 1
  encoded_identifier=$(printf '%s' "$identifier" | jq -sRr @uri)
  response=$(call_api "/entities?identifier=${encoded_identifier}&aclClass=DOCKER_REGISTRY" "$CP_API_JWT_ADMIN" "" || true)
  registry_id=$(echo "$response" | jq -r '.payload.id // empty')
  if [ -n "$registry_id" ] && [ "$registry_id" != "null" ]; then
    echo "$registry_id"
    return 0
  fi
  return 1
}

# POST /folder/register → echoes created folder id; returns 1 on failure.
function api_create_folder {
  local entity_name="$1"
  local parent_folder_id="${2:-}"
  local payload create_folder_response folder_id
  if [ -n "$parent_folder_id" ]; then
    payload=$(jq -nc --arg n "$entity_name" --argjson p "$parent_folder_id" '{"name":$n,"parentId":$p}')
  else
    payload=$(jq -nc --arg n "$entity_name" '{"name":$n}')
  fi
  create_folder_response=$(call_api "/folder/register" "$CP_API_JWT_ADMIN" "$payload" || true)
  folder_id=$(echo "$create_folder_response" | jq -r '.payload.id // empty')
  if [ -n "$folder_id" ] && [ "$folder_id" != "null" ]; then
    echo "$folder_id"
    return 0
  fi
  echo "ERROR: api_create_folder: failed to create '$entity_name': $create_folder_response" >&2
  return 1
}

# POST /metadata/update to set a string attribute on an entity.
function api_set_entity_attribute {
  local entity_id="$1"
  local entity_class="$2"
  local attr_name="$3"
  local attr_value="$4"
  local payload set_attribute_response
  payload=$(jq -nc \
      --argjson eid "$entity_id" \
      --arg cls "$entity_class" \
      --arg key "$attr_name" \
      --arg val "$attr_value" \
      '{"entity":{"entityId":$eid,"entityClass":$cls},"data":{($key):{"value":$val,"type":"string"}}}')
  set_attribute_response=$(call_api "/metadata/update" "$CP_API_JWT_ADMIN" "$payload" || true)
  if ! check_api_response_status "$set_attribute_response"; then
    echo "WARNING: api_set_entity_attribute: failed for $entity_class/$entity_id [$attr_name]: $set_attribute_response" >&2
    return 1
  fi
  return 0
}

# POST /datastorage/save?cloud=false → echoes storage id; returns 1 on failure.
function api_register_datastorage {
  local parent_id="$1"
  local friendly_name="$2"
  local path="$3"
  local storage_type="$4"
  local payload register_storage_response storage_id
  payload=$(jq -nc \
      --argjson pid "$parent_id" \
      --arg name "$friendly_name" \
      --arg path "$path" \
      --arg type "$storage_type" \
      '{"parentFolderId":$pid,"name":$name,"path":$path,"shared":false,"storagePolicy":{"versioningEnabled":false},"type":$type}')
  register_storage_response=$(call_api "/datastorage/save?cloud=false" "$CP_API_JWT_ADMIN" "$payload" || true)
  if ! check_api_response_status "$register_storage_response"; then
    echo "ERROR: api_register_datastorage: failed for path='$path': $register_storage_response" >&2
    return 1
  fi
  storage_id=$(echo "$register_storage_response" | jq -r '.payload.id // empty')
  if [ -n "$storage_id" ] && [ "$storage_id" != "null" ]; then
    echo "$storage_id"
    return 0
  fi
  echo "ERROR: api_register_datastorage: no id in response for path='$path': $register_storage_response" >&2
  return 1
}

