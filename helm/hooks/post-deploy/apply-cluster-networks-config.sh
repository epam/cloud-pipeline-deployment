#!/bin/bash
# Helmfile cleanup hook: register cluster.networks.config API preference. Args: NAMESPACE
set -euo pipefail

NAMESPACE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils/cloud-pipeline-utils.sh
source "$SCRIPT_DIR/utils/cloud-pipeline-utils.sh"

[ -z "$NAMESPACE" ] && usage

[ "${CP_SKIP_CLUSTER_NETWORKS_CONFIG:-}" = "true" ] && { echo "Skipped (CP_SKIP_CLUSTER_NETWORKS_CONFIG=true)"; exit 0; }

for cmd in kubectl curl jq base64 envsubst; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd required but not installed"; exit 1; }
done

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------

echo "Loading config from cp-config-global..."
CP_CONFIG_GLOBAL_JSON=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json)
eval "$(echo "$CP_CONFIG_GLOBAL_JSON" | jq -r \
  '.data | to_entries[] | select(.value != null and .value != "") | "export \(.key)=\(.value | @sh)"')"

# Decode cluster networks config: { regions: [...], tags: {...} }  (tags optional)
if [ -n "${CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC_B64:-}" ]; then
  _decoded_cluster_networks_spec=""
  if _decoded_cluster_networks_spec=$(printf '%s' "$CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC_B64" | base64 -d 2>/dev/null); then
    if printf '%s' "$_decoded_cluster_networks_spec" | jq -e 'type == "object"' >/dev/null 2>&1; then
      export CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC
      CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC=$(printf '%s' "$_decoded_cluster_networks_spec" | jq '.regions // []')
      _tags=$(printf '%s' "$_decoded_cluster_networks_spec" | jq 'if (.tags | type) == "object" then .tags else null end')
      [ "$_tags" != "null" ] && export CP_POST_DEPLOY_CLUSTER_NETWORKS_TAGS="$_tags"
      unset _tags
      echo "Loaded clusterNetworksConfig from Helmfile."
    else
      echo "WARNING: CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC_B64 decoded to non-object JSON; ignoring."
    fi
  else
    echo "WARNING: CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC_B64 is not valid base64."
  fi
  unset _decoded_cluster_networks_spec
fi

# DNS resolver used by worker nodes after launch; defaults to the in-cluster CoreDNS address.
fallback_dns_resolver="${CP_EDGE_CLUSTER_RESOLVER:-10.96.0.10}"
[ -z "${CP_PREF_CLUSTER_PROXIES_DNS_POST:-}" ] && export CP_PREF_CLUSTER_PROXIES_DNS_POST="$fallback_dns_resolver"
unset fallback_dns_resolver

# ---------------------------------------------------------------------------
# API credentials and endpoint
# ---------------------------------------------------------------------------

export CP_API_JWT_ADMIN
CP_API_JWT_ADMIN=$(kubectl get secret cp-api-token -n "$NAMESPACE" \
  -o jsonpath='{.data.CP_API_JWT_ADMIN}' | base64 -d)
[ -z "$CP_API_JWT_ADMIN" ] && { echo "ERROR: CP_API_JWT_ADMIN not found in cp-api-token secret"; exit 1; }

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  API_CONNECT_HOST="$CP_API_SRV_INTERNAL_HOST"
  API_CONNECT_PORT="$CP_API_SRV_INTERNAL_PORT"
else
  API_CONNECT_HOST="${CP_API_SRV_EXTERNAL_HOST:-}"
  API_CONNECT_PORT="${CP_API_SRV_EXTERNAL_PORT:-}"
fi
if [ -z "$API_CONNECT_HOST" ] || [ -z "$API_CONNECT_PORT" ]; then
  echo "ERROR: Missing API endpoint — set CP_API_SRV_INTERNAL_HOST/PORT or CP_API_SRV_EXTERNAL_HOST/PORT"
  exit 1
fi
validate_api_port "$API_CONNECT_PORT" || exit 1

API_URL="https://${API_CONNECT_HOST}:${API_CONNECT_PORT}/pipeline/restapi"
echo "API: $API_URL"

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Proxy list assembly
# Builds CP_PREF_CLUSTER_PROXIES — a JSON array fragment used only as an
# envsubst variable when rendering a cluster.networks template file.
# ---------------------------------------------------------------------------

proxy_json_entries=""

function add_proxy_entry {
  local proxy_name="$1"
  local proxy_path="$2"
  local entry
  entry=$(jq -nc --arg name "$proxy_name" --arg path "$proxy_path" '{name: $name, path: $path}')
  [ -n "$proxy_json_entries" ] && proxy_json_entries="${proxy_json_entries},"
  proxy_json_entries="${proxy_json_entries}${entry}"
}

[ -n "${CP_PREF_CLUSTER_PROXIES_DNS:-}" ]      && add_proxy_entry "dns_proxy"      "$CP_PREF_CLUSTER_PROXIES_DNS"
[ -n "${CP_PREF_CLUSTER_PROXIES_DNS_POST:-}" ] && add_proxy_entry "dns_proxy_post" "$CP_PREF_CLUSTER_PROXIES_DNS_POST"
[ -n "${CP_PREF_CLUSTER_PROXIES_HTTP:-}" ]     && add_proxy_entry "http_proxy"     "$CP_PREF_CLUSTER_PROXIES_HTTP"
[ -n "${CP_PREF_CLUSTER_PROXIES_HTTPS:-}" ]    && add_proxy_entry "https_proxy"    "$CP_PREF_CLUSTER_PROXIES_HTTPS"
[ -n "${CP_PREF_CLUSTER_PROXIES_NO:-}" ]       && add_proxy_entry "no_proxy"       "$CP_PREF_CLUSTER_PROXIES_NO"

export CP_PREF_CLUSTER_PROXIES="$proxy_json_entries"
unset proxy_json_entries

# ---------------------------------------------------------------------------
# Cluster network document building
# ---------------------------------------------------------------------------

# Verify that exactly one region has default=true and all region names are unique.
function validate_regions {
  local networks_file="$1"
  [ -f "$networks_file" ] || return 0

  local string_default_count
  if ! string_default_count=$(jq '[.regions[]? | select((.default | type) == "string")] | length' "$networks_file" 2>/dev/null); then
    echo "ERROR: cluster.networks.config JSON is unreadable: $networks_file"
    return 1
  fi
  if [ "${string_default_count:-0}" -gt 0 ]; then
    echo "ERROR: cluster.networks.config has region(s) where 'default' is a string instead of a boolean."
    return 1
  fi

  local default_count
  if ! default_count=$(jq '[.regions[]? | select(.default == true)] | length' "$networks_file" 2>/dev/null); then
    echo "ERROR: cluster.networks.config JSON is unreadable: $networks_file"
    return 1
  fi
  if [ "${default_count:-0}" -ne 1 ]; then
    echo "ERROR: cluster.networks.config must have exactly one region with default=true (found ${default_count:-0})."
    return 1
  fi

  local duplicate_count
  if ! duplicate_count=$(jq '[.regions[]?.name] | (length - (unique | length))' "$networks_file" 2>/dev/null); then
    echo "ERROR: cluster.networks.config JSON is unreadable: $networks_file"
    return 1
  fi
  if [ "${duplicate_count:-0}" -gt 0 ]; then
    echo "ERROR: cluster.networks.config has duplicate region names. All region names must be unique."
    return 1
  fi
}

# Verify that every AMI entry in the rendered document has an explicit AMI ID.
# Placeholder values (null, empty string, "auto") are rejected to prevent
# launching instances with an unresolved image.
function validate_no_placeholder_amis {
  local networks_file="$1"
  local placeholder_ami_count
  [ -f "$networks_file" ] || return 0
  if ! placeholder_ami_count=$(jq \
      '[.regions[]?.amis[]? | select(.ami == null or .ami == "" or .ami == "auto")] | length' \
      "$networks_file" 2>/dev/null); then
    echo "ERROR: cluster.networks.config JSON is unreadable: $networks_file"
    return 1
  fi
  if [ "${placeholder_ami_count:-0}" -gt 0 ]; then
    echo "ERROR: Every AMI entry in cluster.networks.config must have an explicit AMI ID." \
         "Null, empty string, and \"auto\" are not accepted." \
         "Fix postDeploy.clusterNetworksConfig in values.yaml, or the template file / CP_CLOUD_NETWORK_CONFIG_FILE."
    return 1
  fi
}

# Build a cluster.networks.config document from CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC (JSON array) and
# write it to a temp file.  Prints the temp file path on success; returns non-zero when
# the list is absent or empty.
function build_networks_document_from_spec {
  local spec_list="${CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC:-}"
  [ -n "$spec_list" ] || return 1
  local region_count
  region_count=$(echo "$spec_list" | jq 'if type == "array" then length else 0 end' 2>/dev/null || echo "0")
  [ "$region_count" -gt 0 ] || return 1

  local spec_errors
  if ! spec_errors=$(echo "$spec_list" | jq -r '
    .[] | . as $e |
    if (.networks != null and (.networks | type) != "object") then
      "networks must be an object in region \($e.name // "unknown")"
    elif (.amis != null and (.amis | type) != "array") then
      "amis must be an array in region \($e.name // "unknown")"
    elif (.security_group_ids != null and (.security_group_ids | type) != "array") then
      "security_group_ids must be an array in region \($e.name // "unknown")"
    else empty end
  ' 2>/dev/null); then
    echo "ERROR: clusterNetworksConfig spec is not readable"
    return 1
  fi
  if [ -n "$spec_errors" ]; then
    echo "ERROR: clusterNetworksConfig spec has structural errors:"
    echo "$spec_errors"
    return 1
  fi

  local dns_post_resolver="${CP_PREF_CLUSTER_PROXIES_DNS_POST:-10.96.0.10}"

  # Instance tags: use the dedicated monitor tag name/value when both are configured,
  # otherwise fall back to a generic "monitored=true" marker.
  local default_tags_json
  default_tags_json=$(jq -nc \
    --arg tag_name  "${CP_VM_MONITOR_INSTANCE_TAG_NAME:-}" \
    --arg tag_value "${CP_VM_MONITOR_INSTANCE_TAG_VALUE:-}" \
    'if ($tag_name != "" and $tag_value != "")
     then {($tag_name): $tag_value}
     else {"monitored": "true"}
     end')

  local custom_tags_json="${CP_POST_DEPLOY_CLUSTER_NETWORKS_TAGS:-null}"

  local output_file
  output_file=$(mktemp)

  # Build regions array: one entry per element of the input list.
  # AMI entries are normalized with default platform (linux), instance_mask (*), and init_script.
  if ! echo "$spec_list" | jq -c \
    --arg   region_placeholder '${CP_CLOUD_REGION_ID}' \
    --arg   dns_post_resolver  "$dns_post_resolver" \
    --argjson default_tags    "$default_tags_json" \
    --argjson custom_tags      "$custom_tags_json" \
    '
    def normalize_ami_entry(ami_entry):
      (ami_entry.platform      // "linux") as $platform      |
      if ($platform != "linux" and $platform != "windows") then
        error("invalid AMI platform: " + $platform + " — must be linux or windows")
      else . end |
      (ami_entry.instance_mask // "*")     as $instance_mask  |
      (ami_entry.init_script //
        (if $platform == "windows"
         then "/opt/api/scripts/init_multicloud.ps1"
         else "/opt/api/scripts/init_multicloud_v1.15.4.sh"
         end)
      ) as $init_script |
      {
        platform:      $platform,
        instance_mask: $instance_mask,
        ami:           ami_entry.ami,
        init_script:   $init_script
      };

    (length == 1) as $single_region |
    ($custom_tags // $default_tags) as $tags |
    {
      regions: [.[] | {
        name:               (if ((.name // "") | length) > 0 then .name else $region_placeholder end),
        default:            (if has("default") then .default else $single_region end),
        networks:           (.networks // {}),
        proxies:            (.proxies // [{name: "dns_proxy_post", path: $dns_post_resolver}]),
        amis:               [(.amis // [])[] | normalize_ami_entry(.)],
        swap:               (.swap    // [{name: "swap_ratio", path: "0.01"}]),
        security_group_ids: (.security_group_ids // [])
      }],
      tags: $tags
    }
    ' >"$output_file"; then
    rm -f "$output_file"
    return 1
  fi

  echo "$output_file"
}

echo "Registering cluster.networks.config preference..."

# Variables substituted when rendering a template file.
# (When building from spec, values are embedded directly; envsubst still runs
# to resolve ${CP_CLOUD_REGION_ID} when a spec omits the region field.)
TEMPLATE_SUBSTITUTION_VARS='${CP_CLOUD_REGION_ID} ${CP_PREF_CLUSTER_INSTANCE_IMAGE_GPU} ${CP_PREF_CLUSTER_INSTANCE_IMAGE} ${CP_PREF_CLUSTER_INSTANCE_IMAGE_WIN} ${CP_PREF_CLUSTER_INSTANCE_SECURITY_GROUPS} ${CP_PREF_CLUSTER_PROXIES} ${CP_PREF_CLUSTER_PROXIES_DNS_POST} ${CP_PREF_CLUSTER_INSTANCE_NETWORK} ${CP_PREF_CLUSTER_INSTANCE_SUBNETWORK}'

networks_source_file=""
spec_generated_file=""

if [ -n "${CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC:-}" ]; then
  if spec_generated_file="$(build_networks_document_from_spec)"; then
    networks_source_file="$spec_generated_file"
    echo "cluster.networks.config: built from clusterNetworksConfig..."
  else
    echo "NOTE: clusterNetworksConfig is empty or has no entries; trying file template..."
  fi
fi

if [ -z "$networks_source_file" ] || [ ! -f "$networks_source_file" ]; then
  if [ -n "${CP_CLOUD_NETWORK_CONFIG_FILE:-}" ] && [ -f "$CP_CLOUD_NETWORK_CONFIG_FILE" ]; then
    networks_source_file="$CP_CLOUD_NETWORK_CONFIG_FILE"
  elif [ -f "$SCRIPT_DIR/assets/cluster.networks.config.json" ]; then
    networks_source_file="$SCRIPT_DIR/assets/cluster.networks.config.json"
  fi
  [ -n "$networks_source_file" ] && [ -f "$networks_source_file" ] && \
    echo "cluster.networks.config: applying variable substitution on $networks_source_file..."
fi

if [ -n "$networks_source_file" ] && [ -f "$networks_source_file" ]; then
  envsubst_output_file=$(mktemp)
  envsubst "$TEMPLATE_SUBSTITUTION_VARS" <"$networks_source_file" >"$envsubst_output_file"

  if ! jq -e . <"$envsubst_output_file" >/dev/null 2>&1; then
    echo "ERROR: cluster networks JSON is invalid after variable substitution."
    rm -f "$envsubst_output_file" "$spec_generated_file"
    exit 1
  fi

  if ! validate_no_placeholder_amis "$envsubst_output_file"; then
    rm -f "$envsubst_output_file" "$spec_generated_file"
    exit 1
  fi

  if ! validate_regions "$envsubst_output_file"; then
    rm -f "$envsubst_output_file" "$spec_generated_file"
    exit 1
  fi

  networks_config_json=$(cat "$envsubst_output_file")
  rm -f "$envsubst_output_file" "$spec_generated_file"

  echo "Setting preference: cluster.networks.config"
  api_set_preference "cluster.networks.config" "$networks_config_json" "true"
else
  rm -f "$spec_generated_file"
  echo "cluster.networks.config: skipped." \
       "Provide postDeploy.clusterNetworksConfig entries in values.yaml," \
       "or place a template at $SCRIPT_DIR/assets/cluster.networks.config.json / CP_CLOUD_NETWORK_CONFIG_FILE."
fi

echo "cluster.networks.config registration finished."
