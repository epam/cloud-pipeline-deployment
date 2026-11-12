#!/usr/bin/env bash
#
# Create the cp-cluster-ssh-key secret from an SSH private key -- typically the one
# infra/terraform/modules/cp-cluster generates for you (see its generated_ssh_private_key_pem
# output).
#
# cp-api-srv mounts this secret at /etc/cp_ssh (read-only) to SSH into dynamically launched
# worker/run nodes, and for the run "commit" feature. It is required -- cp-api-srv will not
# start without it.
#
# Usage:
#   ./create-cp-cluster-ssh-key-secret.sh <namespace> <private-key-file> [public-key-file]
#
# When public-key-file is omitted, the public key is derived from the private key via
# ssh-keygen (requires openssh-client).
#
# Example:
#   cd infra/terraform/examples/single-node
#   terraform output -raw generated_ssh_private_key_pem > key.pem
#   cd ../../../../helm/prerequisites
#   ./create-cp-cluster-ssh-key-secret.sh default ../../infra/terraform/examples/single-node/key.pem
#
# Environment:
#   KUBECTL           kubectl binary (default: kubectl)
#   REPLACE_SECRET    When "true", delete the existing secret first (default: true)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cert-common.sh
source "${SCRIPT_DIR}/lib/cert-common.sh"

if [[ -z "${2:-}" ]]; then
  cert_common_usage "$0 <namespace> <private-key-file> [public-key-file]"
fi

NAMESPACE="$1"
PRIVATE_KEY_FILE="$2"
PUBLIC_KEY_FILE="${3:-}"
KUBECTL="${KUBECTL:-kubectl}"
REPLACE_SECRET="${REPLACE_SECRET:-true}"

cert_common_require_command "$KUBECTL"

if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
  echo "ERROR: private key file not found: $PRIVATE_KEY_FILE" >&2
  exit 1
fi

DERIVED_PUBLIC_KEY_FILE=""
if [[ -z "$PUBLIC_KEY_FILE" ]]; then
  cert_common_require_command ssh-keygen
  DERIVED_PUBLIC_KEY_FILE="$(mktemp)"
  trap 'rm -f "$DERIVED_PUBLIC_KEY_FILE"' EXIT
  ssh-keygen -y -f "$PRIVATE_KEY_FILE" >"$DERIVED_PUBLIC_KEY_FILE"
  PUBLIC_KEY_FILE="$DERIVED_PUBLIC_KEY_FILE"
elif [[ ! -f "$PUBLIC_KEY_FILE" ]]; then
  echo "ERROR: public key file not found: $PUBLIC_KEY_FILE" >&2
  exit 1
fi

echo "Creating cp-cluster-ssh-key secret in namespace ${NAMESPACE}..."
if [[ "$REPLACE_SECRET" == "true" ]]; then
  "$KUBECTL" delete secret cp-cluster-ssh-key -n "$NAMESPACE" --ignore-not-found=true
fi
"$KUBECTL" create secret generic cp-cluster-ssh-key -n "$NAMESPACE" \
  --from-file=deploy.key="$PRIVATE_KEY_FILE" \
  --from-file=deploy.pub="$PUBLIC_KEY_FILE"

echo "Done. Secret cp-cluster-ssh-key is ready in namespace ${NAMESPACE}."
