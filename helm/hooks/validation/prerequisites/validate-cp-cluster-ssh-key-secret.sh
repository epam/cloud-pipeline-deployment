#!/bin/bash
# Validation for the cp-cluster-ssh-key prerequisite.
# Reads VALUES_JSON from env. Outputs ERROR:/WARNING: lines to stdout.
# cp-api-srv (always deployed) mounts this secret at /etc/cp_ssh and will not start without it --
# see helm/prerequisites/create-cp-cluster-ssh-key-secret.sh and CLAUDE.md's
# "Prerequisite: cluster SSH key secret".

function add_error   { printf 'ERROR: %s\n' "$1"; }
function add_warning { printf 'WARNING: %s\n' "$1"; }
function jq_val      { printf '%s' "${VALUES_JSON:-}" | jq -r "${1}" 2>/dev/null || true; }

KUBECTL="${KUBECTL:-kubectl}"
NAMESPACE=$(jq_val '.general.namespace // "default"')

command -v "$KUBECTL" >/dev/null 2>&1 || exit 0

if ! "$KUBECTL" get secret cp-cluster-ssh-key -n "$NAMESPACE" >/dev/null 2>&1; then
  add_warning "cp-cluster-ssh-key not found in namespace '$NAMESPACE' — cp-api-srv will not start without it. Create it: cd helm/prerequisites && ./create-cp-cluster-ssh-key-secret.sh $NAMESPACE /path/to/key.pem"
  exit 0
fi

SECRET_KEYS=$("$KUBECTL" get secret cp-cluster-ssh-key -n "$NAMESPACE" \
  -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null || true)

MISSING_KEYS=()
for key in deploy.key deploy.pub; do
  printf '%s\n' "$SECRET_KEYS" | grep -qxF "$key" || MISSING_KEYS+=("$key")
done

if [ ${#MISSING_KEYS[@]} -gt 0 ]; then
  add_error "cp-cluster-ssh-key in namespace '$NAMESPACE' is missing required keys: ${MISSING_KEYS[*]}. Recreate it: cd helm/prerequisites && ./create-cp-cluster-ssh-key-secret.sh $NAMESPACE /path/to/key.pem"
fi
