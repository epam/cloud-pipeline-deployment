#!/bin/bash
# Usage: register-in-idp.sh <endpoint>
# Registers a SAML service provider endpoint with the cp-idp deployment.
set -euo pipefail

ENDPOINT="${1:-}"
[ -z "$ENDPOINT" ] && { echo "ERROR: endpoint required as first argument"; exit 1; }

NAMESPACE="${NAMESPACE:-default}"

command -v kubectl >/dev/null || { echo "ERROR: kubectl required but not installed"; exit 1; }

# Runs on every helm upgrade too (not just install) — skip re-adding a connection that is already
# in the profile database, since saml-idp add-connection has no documented idempotent behavior.
already_registered=$(kubectl -n "$NAMESPACE" exec deployment/cp-idp -- sh -c \
  'grep -F "$1" "${CP_IDP_PROFILE_DB:-/opt/idp/pdb/saml-idp-profiles.json}" 2>/dev/null' \
  _ "$ENDPOINT" || true)
if [ -n "$already_registered" ]; then
  echo "IdP connection for $ENDPOINT is already registered — skipping."
  exit 0
fi

kubectl -n "$NAMESPACE" exec deployment/cp-idp -- sh -c \
  'saml-idp add-connection "$1" -c "${CP_IDP_CERT_DIR:-/opt/idp/pki}/sso-public-cert.pem" --profileDatabase "${CP_IDP_PROFILE_DB:-/opt/idp/pdb/saml-idp-profiles.json}"' \
  _ "$ENDPOINT"
echo "IdP connection for $ENDPOINT added."
