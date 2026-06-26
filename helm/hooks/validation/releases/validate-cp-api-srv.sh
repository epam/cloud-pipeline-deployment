#!/bin/bash
# Validation for cp-api-srv release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

API_EXTERNAL_HOST=$(jq_val '.apiSrv.service.host.external // ""')
[ -z "$API_EXTERNAL_HOST" ] && add_error "apiSrv.service.host.external is required"

CP_CLOUD_PLATFORM=$(jq_val '.resources.config.CP_CLOUD_PLATFORM // ""')
[ "$CP_CLOUD_PLATFORM" != "aws" ] && exit 0

# AWS-specific cloud region settings
KMS_ARN=$(jq_val '.apiSrv.cloudRegion.kmsKeyArn // ""')
if [ -z "$KMS_ARN" ]; then
  add_error "apiSrv.cloudRegion.kmsKeyArn is required for CP_CLOUD_PLATFORM=aws"
elif ! [[ "$KMS_ARN" =~ ^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9_/-]+ ]]; then
  add_error "apiSrv.cloudRegion.kmsKeyArn='$KMS_ARN' does not match ARN format arn:aws[...]:kms:<region>:<account>:key/<id>"
fi

STORAGE_ROLE=$(jq_val '.apiSrv.cloudRegion.tempCredentialsRole // ""')
if [ -n "$STORAGE_ROLE" ] && ! [[ "$STORAGE_ROLE" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+ ]]; then
  add_warning "apiSrv.cloudRegion.tempCredentialsRole='$STORAGE_ROLE' does not match IAM role ARN format"
fi

OMICS_ROLE=$(jq_val '.apiSrv.cloudRegion.omicsServiceRole // ""')
if [ -n "$OMICS_ROLE" ] && ! [[ "$OMICS_ROLE" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+ ]]; then
  add_warning "apiSrv.cloudRegion.omicsServiceRole='$OMICS_ROLE' does not match IAM role ARN format"
fi

BACKUP_DURATION=$(jq_val '.apiSrv.cloudRegion.backupDuration // ""')
if [ -n "$BACKUP_DURATION" ] && ! [[ "$BACKUP_DURATION" =~ ^[0-9]+$ ]]; then
  add_error "apiSrv.cloudRegion.backupDuration='$BACKUP_DURATION' must be a non-negative integer"
fi

while IFS= read -r fs_json; do
  mount_type=$(printf '%s' "$fs_json" | jq -r '.mountType // ""')
  mount_root=$(printf '%s' "$fs_json" | jq -r '.mountRoot // ""')
  if [ -n "$mount_type" ] && ! [[ "$mount_type" =~ ^(NFS|SMB)$ ]]; then
    add_warning "apiSrv.cloudRegion fileShareMount '$mount_root' mountType='$mount_type' should be NFS or SMB"
  fi
done < <(printf '%s' "${VALUES_JSON:-}" | jq -c '.apiSrv.cloudRegion.fileShareMounts[]? // empty' 2>/dev/null || true)
