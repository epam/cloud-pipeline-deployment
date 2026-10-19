#!/bin/bash
# Validation for cp-storage-async-task-service release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

SATS_ENABLED=$(jq_val '.storageAsyncTaskService.enabled // "false"')
[ "$SATS_ENABLED" != "true" ] && exit 0

for field in CP_SATS_SLOTS CP_SATS_POLL_INTERVAL CP_SATS_CLEANUP_INTERVAL CP_SATS_STATUS_POLL \
             CP_SATS_PART_SIZE_MB CP_SATS_NFS_MOUNT_TIMEOUT CP_SATS_LOG_BACKUP_DAYS; do
  VALUE=$(jq_val ".storageAsyncTaskService.config.${field} // \"\"")
  if [ -n "$VALUE" ] && ! [[ "$VALUE" =~ ^[0-9]+$ ]]; then
    add_error "storageAsyncTaskService.config.${field}='$VALUE' must be a positive integer"
  fi
done

COMPRESS_LEVEL=$(jq_val '.storageAsyncTaskService.config.CP_SATS_COMPRESS_LEVEL // ""')
if [ -n "$COMPRESS_LEVEL" ] && { ! [[ "$COMPRESS_LEVEL" =~ ^[0-9]+$ ]] || [ "$COMPRESS_LEVEL" -gt 9 ]; }; then
  add_error "storageAsyncTaskService.config.CP_SATS_COMPRESS_LEVEL='$COMPRESS_LEVEL' must be an integer between 0 and 9"
fi
