#!/bin/bash
# Helmfile postsync (cp-docker-registry release): push manifest images to the in-cluster registry and register tools in the API.
# Uses kubectl to read ConfigMaps/secrets from the target namespace.
set -euo pipefail

function usage {
  echo "Usage: $0 NAMESPACE MANIFEST_DIR [TOOLS_FILTER_JSON]"
  echo "  NAMESPACE      - Kubernetes namespace for cp-config-global, cp-api-token, cp-docker-registry, cp-api-srv"
  echo "  MANIFEST_DIR   - Path to dockers manifest dir on host (e.g. /var/lib/cloud-pipeline/deploy/dockers-manifest)"
  echo "  TOOLS_FILTER_JSON - Optional JSON array of tools to push, e.g. [\"rockylinux:latest\"]. Empty [] = push all."
  exit 1
}

NAMESPACE="${1:-}"
MANIFEST_DIR="${2:-}"
TOOLS_FILTER_JSON="${3:-[]}"

[ -z "$NAMESPACE" ] || [ -z "$MANIFEST_DIR" ] && usage

for cmd in kubectl docker jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

# shellcheck source=utils/cloud-pipeline-utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/utils/cloud-pipeline-utils.sh"

MANIFEST_FILE="$MANIFEST_DIR/manifest.txt"
if [ ! -f "$MANIFEST_FILE" ]; then
  echo "Manifest not found at $MANIFEST_FILE, skipping push"
  exit 0
fi

echo "Loading config from cp-config-global..."
CP_CONFIG_GLOBAL_JSON=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json)
# key filter ensures only valid bash identifiers reach eval; non-conforming keys are skipped
# (e.g. "my.key", "my-key", or "FOO=$(rm -rf /)" would be silently ignored)
eval "$(echo "$CP_CONFIG_GLOBAL_JSON" | jq -r '.data | to_entries[] | select(.value != null and .value != "") | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) | "export \(.key)=\(.value | @sh)"')"

# Admin JWT from cp-api-token
export CP_API_JWT_ADMIN
CP_API_JWT_ADMIN=$(kubectl get secret cp-api-token -n "$NAMESPACE" -o jsonpath='{.data.CP_API_JWT_ADMIN}' | base64 -d)
[ -z "$CP_API_JWT_ADMIN" ] && { echo "CP_API_JWT_ADMIN not found in cp-api-token"; exit 1; }

# Temp dir: extract TLS material from Secrets
TMP_CERTS_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_CERTS_DIR"' EXIT

kubectl get secret cp-pki-secret -n "$NAMESPACE" -o jsonpath='{.data.ssl-public-cert\.pem}' | base64 -d > "$TMP_CERTS_DIR/ssl-public-cert.pem"
if [ ! -s "$TMP_CERTS_DIR/ssl-public-cert.pem" ]; then
  echo "ERROR: ssl-public-cert.pem from cp-pki-secret is empty or missing"
  exit 1
fi
cp "$TMP_CERTS_DIR/ssl-public-cert.pem" "$TMP_CERTS_DIR/docker-public-cert.pem"

export CP_DOCKER_CERT_DIR="$TMP_CERTS_DIR"
export CP_API_SRV_CERT_DIR="$TMP_CERTS_DIR"

for v in CP_DOCKER_INTERNAL_HOST CP_DOCKER_INTERNAL_PORT CP_DEFAULT_ADMIN_NAME CP_API_JWT_ADMIN; do
  eval "val=\${$v}"
  [ -z "$val" ] && { echo "Missing required variable: $v"; exit 1; }
done

REGISTRY_IDENTIFIER="${CP_DOCKER_INTERNAL_HOST}:${CP_DOCKER_INTERNAL_PORT}"
if [ -n "$CP_DOCKER_EXTERNAL_HOST" ] && [ -n "$CP_DOCKER_EXTERNAL_PORT" ]; then
  REGISTRY_PATH="${CP_DOCKER_EXTERNAL_HOST}:${CP_DOCKER_EXTERNAL_PORT}"
  echo "Docker client will use external registry endpoint $REGISTRY_PATH"
else
  REGISTRY_PATH="${CP_DOCKER_INTERNAL_HOST}:${CP_DOCKER_INTERNAL_PORT}"
fi

if [ -n "$CP_API_SRV_INTERNAL_HOST" ] && [ -n "$CP_API_SRV_INTERNAL_PORT" ]; then
  API_CONNECT_HOST="$CP_API_SRV_INTERNAL_HOST"
  API_CONNECT_PORT="$CP_API_SRV_INTERNAL_PORT"
else
  API_CONNECT_HOST="$CP_API_SRV_EXTERNAL_HOST"
  API_CONNECT_PORT="$CP_API_SRV_EXTERNAL_PORT"
fi
if [ -z "$API_CONNECT_HOST" ] || [ -z "$API_CONNECT_PORT" ]; then
  echo "Missing API endpoint"
  exit 1
fi
validate_api_port "$API_CONNECT_PORT" || exit 1
API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API (curl): $API_URL"

REGISTRY_ID=$(curl -k -s -H "Authorization: Bearer $CP_API_JWT_ADMIN" "${API_URL}/entities?identifier=${REGISTRY_IDENTIFIER}&aclClass=DOCKER_REGISTRY" | jq -r '.payload.id // empty')
[ -z "$REGISTRY_ID" ] || [ "$REGISTRY_ID" = "null" ] && { echo "Docker registry $REGISTRY_PATH not registered in API"; exit 1; }

CP_DOCKERS_TO_INIT=()
if [ "$TOOLS_FILTER_JSON" != "[]" ] && [ -n "$TOOLS_FILTER_JSON" ]; then
  if ! echo "$TOOLS_FILTER_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "ERROR: TOOLS_FILTER_JSON is not a JSON array: $TOOLS_FILTER_JSON"
    exit 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && CP_DOCKERS_TO_INIT+=("$line")
  done < <(echo "$TOOLS_FILTER_JSON" | jq -r '.[]')
fi

function array_contains_or_empty {
  local search="$1"; shift
  local arr=("$@")
  [ ${#arr[@]} -eq 0 ] && return 0
  for item in "${arr[@]}"; do
    [ "$item" = "$search" ] && return 0
    [[ "$search" == *"/$item" ]] && return 0
  done
  return 1
}

function docker_get_spec_value {
  local field="$1" spec_path="$2"
  [ ! -f "$spec_path" ] && return 1
  local val
  val=$(envsubst < "$spec_path" 2>/dev/null | jq -r ".$field // empty")
  [ -n "$val" ] && [ "$val" != "null" ] && { echo "$val"; return 0; }
  return 1
}

function api_register_docker_image {
  local registry_id="$1" registry_path="$2" image_name="$3" disk_size="${4:-50}" instance_type="${5:-NA}" default_cmd="${6:-sleep infinity}" short_desc="${7:-NA}" full_desc="${8:-NA}" endpoints="${9:-[]}"
  [ "$short_desc" = "NA" ] && short_desc=""
  [ "$full_desc" = "NA" ] && full_desc=""
  # jq --arg JSON-escapes newlines and quotes; do not pre-escape (would store literal \n in API).
  if ! [[ "$disk_size" =~ ^[0-9]+$ ]] || [ "$disk_size" -lt 1 ]; then disk_size=50; fi
  echo "$endpoints" | jq -e . >/dev/null 2>&1 || endpoints="[]"
  local image_without_tag
  image_without_tag=$(echo "$image_name" | cut -d: -f1)
  local payload
  if [ -n "$instance_type" ] && [ "$instance_type" != "NA" ]; then
    payload=$(jq -n --arg img "$image_without_tag" --arg reg "$registry_path" --argjson rid "$registry_id" --arg sd "$short_desc" --arg fd "$full_desc" --argjson disk "$disk_size" --argjson ep "$endpoints" --arg cmd "$default_cmd" --arg it "$instance_type" \
      '{image:$img, registry:$reg, registryId:$rid, shortDescription:$sd, description:$fd, disk:$disk, endpoints:$ep, defaultCommand:$cmd, instanceType:$it}')
  else
    payload=$(jq -n --arg img "$image_without_tag" --arg reg "$registry_path" --argjson rid "$registry_id" --arg sd "$short_desc" --arg fd "$full_desc" --argjson disk "$disk_size" --argjson ep "$endpoints" --arg cmd "$default_cmd" \
      '{image:$img, registry:$reg, registryId:$rid, shortDescription:$sd, description:$fd, disk:$disk, endpoints:$ep, defaultCommand:$cmd}')
  fi
  call_api "/tool/update" "$CP_API_JWT_ADMIN" "$payload"
  return $?
}

function api_find_docker_image {
  local image_name="$1" registry="${2:-}"
  local url
  if [ -n "$registry" ]; then
    url="/tool/load?registry=$(printf '%s' "$registry" | jq -sRr @uri)&image=$(printf '%s' "$image_name" | jq -sRr @uri)"
  else
    url="/tool/load?image=$(printf '%s' "$image_name" | jq -sRr @uri)"
  fi
  local tool_lookup_response tool_id
  tool_lookup_response=$(curl -k -s -H "Authorization: Bearer $CP_API_JWT_ADMIN" "${API_URL}${url}")
  tool_id=$(echo "$tool_lookup_response" | jq -r '.payload.id // empty')
  [ -n "$tool_id" ] && [ "$tool_id" != "null" ] && { echo "$tool_id"; return 0; }
  return 1
}

function api_get_or_create_tool_group {
  local registry_id="$1" registry_path="$2" group_name="$3"
  local tool_group_list_response group_id
  tool_group_list_response=$(curl -k -s -H "Authorization: Bearer $CP_API_JWT_ADMIN" "${API_URL}/toolGroup/list?registry=$(printf '%s' "$registry_path" | jq -sRr @uri)")
  group_id=$(echo "$tool_group_list_response" | jq -r --arg g "$group_name" '.payload[] | select(.name == $g) | .id // empty')
  if [ -n "$group_id" ] && [ "$group_id" != "null" ]; then
    echo "$group_id"
    return 0
  fi
  local tool_group_create_response
  tool_group_create_response=$(curl -X POST -k -s -H 'Content-Type: application/json' -H "Authorization: Bearer $CP_API_JWT_ADMIN" \
    -d "$(jq -n --arg n "$group_name" --argjson rid "$registry_id" '{name:$n, registryId:$rid}')" \
    "${API_URL}/toolGroup")
  check_api_response_status "$tool_group_create_response" || return 1
  group_id=$(echo "$tool_group_create_response" | jq -r '.payload.id // empty')
  [ -n "$group_id" ] && [ "$group_id" != "null" ] && { echo "$group_id"; return 0; }
  return 1
}

function api_register_tool {
  local registry_id="$1" registry_path="$2" image_full="$3"
  local group_name img_for_tool
  if [[ "$image_full" == */* ]]; then
    group_name="${image_full%%/*}"
    img_for_tool="$image_full"
  else
    group_name="library"
    img_for_tool="$image_full"
  fi
  local group_id
  group_id=$(api_get_or_create_tool_group "$registry_id" "$registry_path" "$group_name") || return 1
  local payload tool_register_response tool_id
  payload=$(jq -n --arg img "$img_for_tool" --argjson gid "$group_id" --arg reg "$registry_path" \
    '{image:$img, toolGroupId:$gid, registry:$reg, cpu:"0mi", ram:"0Gi"}')
  tool_register_response=$(curl -X POST -k -s -H 'Content-Type: application/json' -H "Authorization: Bearer $CP_API_JWT_ADMIN" -d "$payload" "${API_URL}/tool/register")
  check_api_response_status "$tool_register_response" || return 1
  tool_id=$(echo "$tool_register_response" | jq -r '.payload.id // empty')
  [ -n "$tool_id" ] && [ "$tool_id" != "null" ] && { echo "$tool_id"; return 0; }
  return 1
}

function api_set_docker_image_icon {
  local img_id="$1" icon_path="$2"
  [ ! -f "$icon_path" ] && return 1
  call_api "/tool/$img_id/icon" "$CP_API_JWT_ADMIN" "$icon_path" "file"
  return $?
}

function docker_register_image {
  local docker_image_name="$1" docker_manifest_path="$2" docker_registry_id="$3" docker_registry_path="$4"
  local image_without_tag
  image_without_tag="${docker_image_name%%:*}"
  [ -z "$image_without_tag" ] && image_without_tag="$docker_image_name"
  local docker_image_id
  docker_image_id=$(api_find_docker_image "$image_without_tag" "$docker_registry_path")
  if [ -z "$docker_image_id" ]; then
    echo "Tool not found, registering via /tool/register..."
    docker_image_id=$(api_register_tool "$docker_registry_id" "$docker_registry_path" "$image_without_tag") || { echo "Cannot register docker image \"$docker_image_name\""; return 1; }
  fi
  local docker_icon_path="$docker_manifest_path/icon.png"
  [ ! -f "$docker_icon_path" ] && unset docker_icon_path
  local docker_readme_path="$docker_manifest_path/README.md"
  local full_description=""
  # README may be CRLF; normalize newlines for consistent API markdown.
  [ -f "$docker_readme_path" ] && full_description=$(tr -d '\r' < "$docker_readme_path")
  local docker_spec_path="$docker_manifest_path/spec.json"
  if [ -f "$docker_spec_path" ] && ! jq -e . "$docker_spec_path" >/dev/null 2>&1; then
    echo "WARNING: $docker_spec_path is not valid JSON; using defaults for all spec fields."
    docker_spec_path=""
  fi
  local short_description
  short_description=$(docker_get_spec_value "short_description" "$docker_spec_path") || short_description="NA"
  local instance_type
  instance_type=$(docker_get_spec_value "instance_type" "$docker_spec_path") || instance_type="NA"
  local disk_size
  disk_size=$(docker_get_spec_value "disk_size" "$docker_spec_path") || disk_size="50"
  local default_command
  default_command=$(docker_get_spec_value "default_command" "$docker_spec_path") || default_command="sleep infinity"
  local endpoints
  endpoints=$(docker_get_spec_value "endpoints" "$docker_spec_path") || endpoints="[]"
  if ! [[ "$disk_size" =~ ^[0-9]+$ ]] || [ "$disk_size" -lt 1 ]; then disk_size=50; fi
  [[ "$endpoints" =~ ^\[.*\]$ ]] || endpoints="[]"
  api_register_docker_image "$docker_registry_id" "$docker_registry_path" "$docker_image_name" "$disk_size" "$instance_type" "$default_command" "$short_description" "${full_description:-NA}" "$endpoints" || return 1
  [ -f "${docker_icon_path:-}" ] && api_set_docker_image_icon "$docker_image_id" "$docker_icon_path" || true
  return 0
}

echo "Setting up registry trust for $REGISTRY_PATH..."
REGISTRY_CERTS_DIR="/etc/docker/certs.d/$REGISTRY_PATH"
CERTS_CONTENT=$(cat "$CP_API_SRV_CERT_DIR/ssl-public-cert.pem" "$CP_DOCKER_CERT_DIR/docker-public-cert.pem")
if ! (mkdir -p "$REGISTRY_CERTS_DIR" 2>/dev/null && echo "$CERTS_CONTENT" > "$REGISTRY_CERTS_DIR/ca.crt"); then
  if command -v sudo >/dev/null; then
    sudo mkdir -p "$REGISTRY_CERTS_DIR" && echo "$CERTS_CONTENT" | sudo tee "$REGISTRY_CERTS_DIR/ca.crt" >/dev/null || { echo "Cannot write certs to $REGISTRY_CERTS_DIR (try running with sudo)"; exit 1; }
  else
    echo "Cannot write to $REGISTRY_CERTS_DIR (need root or sudo)"
    exit 1
  fi
fi

docker login -u "$CP_DEFAULT_ADMIN_NAME" -p "$CP_API_JWT_ADMIN" "$REGISTRY_PATH" || { echo "docker login failed"; exit 1; }

push_result=0
while IFS=, read -r docker_name docker_pretty_name; do
  docker_pretty_name=$(echo "$docker_pretty_name" | tr -d ' ')
  if ! array_contains_or_empty "$docker_pretty_name" "${CP_DOCKERS_TO_INIT[@]}"; then
    echo "Skipping docker $docker_pretty_name (not in filter)"
    continue
  fi
  image_name_without_tag="${docker_pretty_name%%:*}"
  if api_find_docker_image "$image_name_without_tag" "$REGISTRY_IDENTIFIER" >/dev/null 2>&1; then
    echo "Tool $docker_pretty_name already exists in Cloud Pipeline — skipping."
    continue
  fi

  if [ -d "$MANIFEST_DIR/$docker_name" ]; then
    docker_tool_manifest_path="$MANIFEST_DIR/$docker_name"
  else
    docker_tool_manifest_path="$MANIFEST_DIR/$docker_pretty_name"
  fi
  docker_full_pretty_name="$REGISTRY_PATH/$docker_pretty_name"
  echo "Pushing docker image from \"$docker_name\" to \"$docker_full_pretty_name\""
  if docker pull "$docker_name" && docker tag "$docker_name" "$docker_full_pretty_name" && docker push "$docker_full_pretty_name"; then
    echo "Waiting 15s for registry to index before API registration..."
    sleep 15
    if ! docker_register_image "$docker_pretty_name" "$docker_tool_manifest_path" "$REGISTRY_ID" "$REGISTRY_IDENTIFIER"; then
      push_result=1
    fi
  else
    echo "Pull/Push failed, image settings will NOT be applied"
    push_result=1
  fi
done < "$MANIFEST_FILE"

echo "Pushing tools completed with result: $push_result"
exit $push_result
