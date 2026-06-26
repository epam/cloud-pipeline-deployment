#!/bin/bash
set -euo pipefail

if [ -n "${CP_API_SRV_INTERNAL_HOST:-}" ] && [ -n "${CP_API_SRV_INTERNAL_PORT:-}" ]; then
  API_HOST="$CP_API_SRV_INTERNAL_HOST"
  API_PORT="$CP_API_SRV_INTERNAL_PORT"
else
  API_HOST="${CP_API_SRV_EXTERNAL_HOST:-}"
  API_PORT="${CP_API_SRV_EXTERNAL_PORT:-}"
fi
if [ -z "${API_HOST:-}" ] || [ -z "${API_PORT:-}" ] || [ -z "${CP_API_JWT_ADMIN:-}" ]; then
  echo "WARNING: Missing API endpoint or admin JWT; skipping Search preference registration." >&2
  exit 0
fi

SEARCH_SCHEME="${CP_SEARCH_ELK_INTERNAL_SCHEME:-http}"
SEARCH_HOST="${CP_SEARCH_ELK_INTERNAL_HOST:-cp-search-elk.${NAMESPACE}.svc.cluster.local}"
SEARCH_PORT="${CP_SEARCH_ELK_ELASTIC_INTERNAL_PORT:-30091}"
API_URL="https://${API_HOST}:${API_PORT}/pipeline/restapi"
SEARCH_HOOK_URL="http://${CP_SEARCH_INTERNAL_HOST:-cp-search-srv.${NAMESPACE}.svc.cluster.local}:${CP_SEARCH_INTERNAL_PORT:-30093}/elastic-agent/restapi/githook/event"

index_type_prefix=$(jq -nc '{
  PIPELINE_RUN: "cp-pipeline-run",
  S3_FILE: "cp-s3-file*",
  AZ_BLOB_FILE: "cp-az-file*",
  NFS_FILE: "cp-nfs-file*",
  S3_STORAGE: "cp-s3-storage",
  AZ_BLOB_STORAGE: "cp-az-storage",
  NFS_STORAGE: "cp-nfs-storage",
  GS_FILE: "cp-gs-file*",
  GS_STORAGE: "cp-gs-storage",
  TOOL: "cp-tool",
  TOOL_GROUP: "cp-tool-group",
  DOCKER_REGISTRY: "cp-docker-registry",
  FOLDER: "cp-folder",
  METADATA_ENTITY: "cp-metadata-entity",
  CONFIGURATION: "cp-run-configuration",
  PIPELINE: "cp-pipeline",
  ISSUE: "cp-issue",
  PIPELINE_CODE: "cp-pipeline-code*"
}')

payload=$(jq -nc \
  --arg scheme "$SEARCH_SCHEME" \
  --arg host "$SEARCH_HOST" \
  --arg port "$SEARCH_PORT" \
  --arg idx "$index_type_prefix" \
  --arg hook "$SEARCH_HOOK_URL" \
  '[
    {"name":"search.elastic.scheme","value":"http","visible":"false"},
    {"name":"search.elastic.allowed.users.field","value":"allowed_users","visible":"false"},
    {"name":"search.elastic.denied.users.field","value":"denied_users","visible":"false"},
    {"name":"search.elastic.denied.groups.field","value":"denied_groups","visible":"false"},
    {"name":"search.elastic.type.field","value":"doc_type","visible":"false"},
    {"name":"search.elastic.scheme","value":$scheme,"visible":"true"},
    {"name":"search.elastic.host","value":$host,"visible":"true"},
    {"name":"search.elastic.port","value":$port,"visible":"false"},
    {"name":"search.elastic.search.fields","value":"[]","visible":"false"},
    {"name":"search.elastic.index.common.prefix","value":"cp-*","visible":"false"},
    {"name":"search.elastic.allowed.groups.field","value":"allowed_groups","visible":"false"},
    {"name":"search.elastic.index.type.prefix","value":$idx,"visible":"false"},
    {"name":"git.repository.hook.url","value":$hook,"visible":"false"},
    {"name":"git.repository.indexing.enabled","value":"true","visible":"false"}
  ]')

for attempt in $(seq 1 30); do
  if resp=$(curl -k -sS --connect-timeout 15 --max-time 60 \
      -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${CP_API_JWT_ADMIN}" \
      -d "$payload" \
      "${API_URL}/preferences"); then
    status=$(echo "$resp" | jq -r '.status // "OK"' 2>/dev/null || echo "OK")
    if [ "$status" != "ERROR" ] && [[ "$status" != 4* ]]; then
      echo "Search preferences were synced."
      exit 0
    fi
    echo "Attempt ${attempt}/30: API returned status=${status}; retrying..." >&2
  else
    echo "Attempt ${attempt}/30: API request failed; retrying..." >&2
  fi
  sleep 10
done

echo "WARNING: Could not sync Search preferences after retries; continuing deployment." >&2
exit 0
