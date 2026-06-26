#!/bin/bash
# Validation for cp-resources release.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

CP_CLOUD_PLATFORM=$(jq_val '.resources.config.CP_CLOUD_PLATFORM // ""')
CP_CLOUD_REGION_ID=$(jq_val '.resources.config.CP_CLOUD_REGION_ID // ""')
CP_DEFAULT_ADMIN_NAME=$(jq_val '.resources.config.CP_DEFAULT_ADMIN_NAME // ""')
CP_DEFAULT_ADMIN_EMAIL=$(jq_val '.resources.config.CP_DEFAULT_ADMIN_EMAIL // ""')

if [ -z "$CP_CLOUD_PLATFORM" ]; then
  add_error "resources.config.CP_CLOUD_PLATFORM is required"
elif [[ ! "$CP_CLOUD_PLATFORM" =~ ^(aws|azure|gcp)$ ]]; then
  add_error "resources.config.CP_CLOUD_PLATFORM='$CP_CLOUD_PLATFORM' is invalid; must be aws, azure, or gcp"
fi

[ -z "$CP_CLOUD_REGION_ID" ]     && add_error "resources.config.CP_CLOUD_REGION_ID is required"
[ -z "$CP_DEFAULT_ADMIN_NAME" ]  && add_error "resources.config.CP_DEFAULT_ADMIN_NAME is required"
[ -z "$CP_DEFAULT_ADMIN_EMAIL" ] && add_error "resources.config.CP_DEFAULT_ADMIN_EMAIL is required"
