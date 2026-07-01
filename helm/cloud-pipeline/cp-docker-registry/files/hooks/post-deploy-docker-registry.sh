#!/bin/bash
set -e
cd /tmp

# CP_API_JWT_ADMIN from env is fixed at pod start. jwt-token-generator may patch cp-api-token
# after this Job is scheduled; re-read from the cluster so we never call the API with an
# empty or stale token (manifests as 401 on /dockerRegistry/register).
fetch_cp_api_jwt_admin() {
  local j i
  for i in $(seq 1 72); do
    j=$(kubectl get secret cp-api-token -n "$NAMESPACE" -o jsonpath='{.data.CP_API_JWT_ADMIN}' 2>/dev/null | base64 -d || true)
    if [ -n "$j" ]; then
      printf '%s' "$j"
      return 0
    fi
    echo "Waiting for non-empty CP_API_JWT_ADMIN in secret cp-api-token ($i/72)..."
    sleep 5
  done
  return 1
}
CP_API_JWT_ADMIN="$(fetch_cp_api_jwt_admin)" || {
  echo "ERROR: cp-api-token has no CP_API_JWT_ADMIN. Ensure cp-api-srv post-upgrade hook jwt-token-generator completed successfully before this Job."
  exit 1
}
export CP_API_JWT_ADMIN

REGISTRY_PATH="${CP_DOCKER_INTERNAL_HOST}:${CP_DOCKER_INTERNAL_PORT}"
API_URL="https://${CP_API_SRV_INTERNAL_HOST}:${CP_API_SRV_INTERNAL_PORT}/pipeline/restapi"
# curl without timeouts can hang indefinitely on TLS/TCP issues; Bearer must expand at call time (token refresh).
curl_opts=( -k -s --connect-timeout 20 --max-time 120 )
curl_opts_long=( -k -s --connect-timeout 20 --max-time 300 )
# Build current trusted chain that autoscaled nodes must receive via /dockerRegistry/loadCerts.
docker_caCert=/etc/post-deploy/docker-cert/docker-public-cert.pem
api_caCert=/etc/post-deploy/api-cert/ssl-public-cert.pem
public_certificate=$(cat "$docker_caCert" "$api_caCert" | awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}')

function api_get_docker_registry_id {
  local docker_path="$1"
  local docker_path_enc
  docker_path_enc=$(printf '%s' "$docker_path" | jq -sRr @uri)
  local docker_registries_json
  docker_registries_json=$(curl "${curl_opts[@]}" -H "Authorization: Bearer ${CP_API_JWT_ADMIN}" "${API_URL}/entities?identifier=${docker_path_enc}&aclClass=DOCKER_REGISTRY")
  local docker_id
  docker_id=$(echo "$docker_registries_json" | jq -r ".payload.id // empty")
  if [ -n "$docker_id" ] && [ "$docker_id" != "null" ]; then
      echo "$docker_id"
  fi
  return 0
}

REGISTRY_PATH_ENC=$(printf '%s' "$REGISTRY_PATH" | jq -sRr @uri)
EXISTING_REGISTRY_JSON=$(curl "${curl_opts[@]}" -H "Authorization: Bearer ${CP_API_JWT_ADMIN}" "${API_URL}/entities?identifier=${REGISTRY_PATH_ENC}&aclClass=DOCKER_REGISTRY")
EXISTING_ID=$(echo "$EXISTING_REGISTRY_JSON" | jq -r '.payload.id // empty' 2>/dev/null)
if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
  echo "Docker registry $REGISTRY_PATH already registered (id=$EXISTING_ID). Refreshing cert chain via dockerRegistry/update (non-destructive)."
  UPDATE_PAYLOAD=$(echo "$EXISTING_REGISTRY_JSON" \
    | jq -c --arg cert "$public_certificate" --arg ext "${CP_DOCKER_EXTERNAL_HOST}:${CP_DOCKER_EXTERNAL_PORT}" '
        .payload
        | .caCert=$cert
        | .externalUrl=$ext
      ' 2>/dev/null || true)
  if [ -z "$UPDATE_PAYLOAD" ] || [ "$UPDATE_PAYLOAD" = "null" ]; then
    echo "ERROR: cannot build dockerRegistry/update payload for id=$EXISTING_ID."
    exit 1
  fi
  UPDATE_JSON=$(curl "${curl_opts_long[@]}" \
    -H "Authorization: Bearer ${CP_API_JWT_ADMIN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$UPDATE_PAYLOAD" \
    "${API_URL}/dockerRegistry/update")
  echo "$UPDATE_JSON" | jq . 2>/dev/null || echo "$UPDATE_JSON"
  if ! echo "$UPDATE_JSON" | jq -e '.status == "OK"' >/dev/null 2>&1; then
    echo "ERROR: dockerRegistry/update failed for $REGISTRY_PATH (id=$EXISTING_ID)."
    exit 1
  fi
  echo "Docker registry $REGISTRY_PATH (id=$EXISTING_ID) cert chain refreshed."
  exit 0
fi

LEGACY_PATH="cp-docker-registry.${NAMESPACE}.svc.cluster.local:${CP_DOCKER_INTERNAL_PORT}"
if [ "$REGISTRY_PATH" != "$LEGACY_PATH" ]; then
  LEGACY_ID=$(api_get_docker_registry_id "$LEGACY_PATH")
  if [ -n "$LEGACY_ID" ]; then
    echo "Deleting legacy docker registry entity $LEGACY_PATH (id=$LEGACY_ID); registry path must match TLS certificate ($REGISTRY_PATH)."
    DEL_JSON=$(curl "${curl_opts[@]}" -H "Authorization: Bearer ${CP_API_JWT_ADMIN}" -X DELETE "${API_URL}/dockerRegistry/${LEGACY_ID}/delete?force=true")
    echo "$DEL_JSON" | jq . 2>/dev/null || echo "$DEL_JSON"
    if echo "$DEL_JSON" | jq -e '.status == "OK"' >/dev/null 2>&1; then
      echo "Legacy registry removed."
    else
      echo "WARNING: legacy registry delete may have failed; verify in API/GUI or clear pipeline.docker_registry for the old path."
    fi
  fi
fi

echo "Waiting for cp-docker-registry pod to be Ready..."
for i in $(seq 1 60); do
  READY=$(kubectl get pods -n "$NAMESPACE" -l cloud-pipeline/cp-docker-registry=true -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
  if [ "$READY" = "true" ]; then
    echo "cp-docker-registry pod is ready"
    break
  fi
  [ $i -eq 60 ] && { echo "Timeout waiting for cp-docker-registry pod"; exit 1; }
  sleep 5
done

echo "Waiting for cp-docker-registry HTTP endpoint to respond..."
_registry_url="https://${CP_DOCKER_INTERNAL_HOST}:${CP_DOCKER_INTERNAL_PORT}/v2/"
_deadline=$(( $(date +%s) + 600 ))
_delay=5
_attempt=0
while true; do
  _attempt=$(( _attempt + 1 ))
  _http_code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$_registry_url" 2>/dev/null || echo "000")
  if [ "$_http_code" = "200" ] || [ "$_http_code" = "401" ]; then
    echo "Docker registry endpoint responded (HTTP $_http_code, attempt $_attempt)"
    break
  fi
  _now=$(date +%s)
  if [ "$_now" -ge "$_deadline" ]; then
    echo "ERROR: Docker registry at $_registry_url did not respond after 10 minutes (last HTTP code: $_http_code)"
    exit 1
  fi
  _remaining=$(( _deadline - _now ))
  _wait=$(( _delay < _remaining ? _delay : _remaining ))
  echo "Attempt $_attempt: registry not ready (HTTP $_http_code), retrying in ${_wait}s..."
  sleep "$_wait"
  _delay=$(( _delay * 2 ))
  [ "$_delay" -gt 60 ] && _delay=60
done

echo "Registering docker registry in API (${REGISTRY_PATH})..."

function check_api_response_status {
  local response_json="$1"
  local response_status
  response_status=$(echo "$response_json" | jq -r ".status")
  local result=0
  if [ "$response_status" == "ERROR" ] || [[ "$response_status" == "40"* ]]; then
      result=1
  fi
  return $result
}

function api_entity_grant {
  local entity_id="$1"
  local entity_class="$2"
  local entity_mask="$3"
  local entity_principal="$4"
  local entity_user="$5"

  local payload
  payload=$(jq -n --arg acl "$entity_class" --argjson id "$entity_id" --arg m "$entity_mask" --argjson p "$entity_principal" --arg u "$entity_user" '{aclClass:$acl, id:$id, mask:($m|tonumber), principal:$p, userName:$u}')

  call_api_entity_grant_response=$(call_api "/grant" "$CP_API_JWT_ADMIN" "$payload")
  call_api_entity_grant_result=$?
  if [ $call_api_entity_grant_result -ne 0 ]; then
      echo "ERROR: Grant failed for $entity_user permissions ($entity_mask) to $entity_id ($entity_class) entity:"
      echo "========"
      echo "Request:"
      echo "$payload"
      echo "========"
      echo "Response:"
      echo "$call_api_entity_grant_response"
      echo "========"
  else
      echo "OK: Permissions ($entity_mask) to $entity_id ($entity_class) entity are granted for $entity_user"
  fi
  return $call_api_entity_grant_result
}

function call_api {
  local api_endpoint="$1"
  local jwt_token="$2"
  local payload="$3"
  local is_file="$4"

  local api_url="https://$CP_API_SRV_INTERNAL_HOST:$CP_API_SRV_INTERNAL_PORT/pipeline/restapi"
  local response=""
  if [ "$is_file" ]; then
      response=$(curl "${curl_opts_long[@]}" -H "Authorization: Bearer $jwt_token" -X POST -F "file=@$payload" "${api_url}${api_endpoint}")
  else
      if [ "$payload" ]; then
          response=$(curl "${curl_opts_long[@]}" -H "Authorization: Bearer $jwt_token" -H "Content-Type: application/json" -X POST -d "$payload" "${api_url}${api_endpoint}")
      else
          response=$(curl "${curl_opts[@]}" -H "Authorization: Bearer $jwt_token" -X GET "${api_url}${api_endpoint}")
      fi
  fi
  echo "$response"
  check_api_response_status "$response"
  return $?
}

function api_register_docker_registry {
  local docker_role_grant="ROLE_USER"

  local docker_path=$CP_DOCKER_INTERNAL_HOST:$CP_DOCKER_INTERNAL_PORT
  local docker_externalUrl=$CP_DOCKER_EXTERNAL_HOST:$CP_DOCKER_EXTERNAL_PORT
  # Use mounted secrets (not CP_*_CERT_DIR paths — this Job has no hostPath to /opt/.../pki)
  local docker_caCert=/etc/post-deploy/docker-cert/docker-public-cert.pem
  local api_caCert=/etc/post-deploy/api-cert/ssl-public-cert.pem
  local docker_securityScanEnabled="true"
  local docker_description=${CP_DOCKER_DEFAULT_NAME:-"Default registry"}
  local docker_pipelineAuth="true"
  local docker_userName="$CP_DEFAULT_ADMIN_NAME"
  # api + docker registry certificates are added as trusted (api is required to pipeline auth)
  local public_certificate
  public_certificate=$(cat $docker_caCert $api_caCert | awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}')

  local docker_id
  docker_id=$(api_get_docker_registry_id "$docker_path")
  if [ "$docker_id" ]; then
      echo "Docker registry \"$docker_path\" with id \"$docker_id\" already exists, it will NOT be deleted and a new registry will NOT be registered"
      export CP_DOCKER_REGISTRY_ID=$docker_id
      return 0
  fi

  local attempt docker_password payload call_api_register_response call_api_register_result
  call_api_register_result=1
  for attempt in 1 2; do
    docker_password="$CP_API_JWT_ADMIN"
    payload="{
                    \"path\": \"$docker_path\",
                    \"description\": \"$docker_description\",
                    \"caCert\": \"$public_certificate\",
                    \"externalUrl\":\"$docker_externalUrl\",
                    \"securityScanEnabled\":$docker_securityScanEnabled,
                    \"userName\":\"$docker_userName\",
                    \"password\":\"$docker_password\",
                    \"pipelineAuth\": $docker_pipelineAuth
                }"
    call_api_register_response=$(call_api "/dockerRegistry/register" "$CP_API_JWT_ADMIN" "$payload")
    call_api_register_result=$?
    [ "$call_api_register_result" -eq 0 ] && break
    if [ "$attempt" -eq 1 ] && echo "$call_api_register_response" | grep -q '"status":401'; then
      echo "dockerRegistry/register returned 401; re-reading cp-api-token and retrying once..."
      CP_API_JWT_ADMIN="$(fetch_cp_api_jwt_admin)" || true
      export CP_API_JWT_ADMIN
      continue
    fi
    break
  done

  if [ $call_api_register_result -ne 0 ]; then
      echo "Error occured while registering a docker registry ($docker_path):"
      echo "$call_api_register_response"
  else
      docker_id=$(api_get_docker_registry_id "$docker_path")
      export CP_DOCKER_REGISTRY_ID=$docker_id
      echo "Docker registry added with id \"${docker_id}\""

      api_entity_grant "$docker_id" \
                      "DOCKER_REGISTRY" \
                      "25" \
                      "false" \
                      "$docker_role_grant"

      call_api_grant_registry_result=$?
      if [ $call_api_grant_registry_result -ne 0 ]; then
          echo "Error occured while granting permissions for $docker_role_grant to $docker_path docker registry (id: $docker_id):"
          return 1
      else
          echo "$docker_role_grant was granted access to region $docker_path (id: $docker_id)"
      fi
  fi
  return $call_api_register_result
}

DOCKER_PULL_SECRET=$(printf '%s' "$REGISTRY_PATH" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+|-+$//g')
if kubectl get secret "$DOCKER_PULL_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Deleting orphan docker-registry pull secret \"$DOCKER_PULL_SECRET\" (e.g. after empty DB / reinstall)..."
  kubectl delete secret "$DOCKER_PULL_SECRET" -n "$NAMESPACE"
fi

CP_DOCKER_INSTALLED=0
api_register_docker_registry || CP_DOCKER_INSTALLED=$?
if [ $CP_DOCKER_INSTALLED -ne 0 ]; then
    echo "ERROR: Default docker registry registration failed. You can configure it manually through the Cloud Pipeline GUI/API"
    exit 1
fi

echo "Post-deploy docker registry hook complete."
