#!/usr/bin/env bash
# Shared helpers for prerequisite certificate scripts.
# Source from other scripts: source "$(dirname "$0")/lib/cert-common.sh"

cert_common_usage() {
  echo "Usage: $1" >&2
  exit 1
}

cert_common_require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  fi
}

cert_common_find_openssl_config() {
  local config_path
  for config_path in /etc/ssl/openssl.cnf /usr/lib/ssl/openssl.cnf /etc/pki/tls/openssl.cnf; do
    if [[ -f "$config_path" ]]; then
      echo "$config_path"
      return 0
    fi
  done
  echo ""
}

# Build OpenSSL subjectAltName value: DNS:host or IP:addr for each hostname.
cert_common_build_san_names() {
  local san_names=""
  local hostname
  for hostname in "$@"; do
    [[ -z "$hostname" ]] && continue
    if [[ "$hostname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      san_names="${san_names:+$san_names,}IP:${hostname}"
    else
      san_names="${san_names:+$san_names,}DNS:${hostname}"
    fi
  done
  echo "$san_names"
}

cert_common_prepare_output_dir() {
  local output_dir="$1"
  mkdir -p "$output_dir"
  cd "$output_dir" || return 42
}

cert_common_default_idp_internal_host() {
  local namespace="$1"
  echo "cp-idp.${namespace}.svc.cluster.local"
}
