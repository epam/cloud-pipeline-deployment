#!/bin/bash
# Shared utilities sourced by all helmfile hook scripts.
# Requires: $API_URL and $CP_API_JWT_ADMIN set before calling any API function.

function check_api_response_status {
  local response_json="$1"
  local response_status
  response_status=$(echo "$response_json" | jq -r ".status")
  if [ "$response_status" = "ERROR" ] || [[ "$response_status" == "40"* ]]; then
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

