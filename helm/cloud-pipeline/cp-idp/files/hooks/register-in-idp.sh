#!/bin/bash
# Usage: register-in-idp.sh <endpoint>
# Registers a SAML service provider endpoint with the cp-idp deployment.
set -euo pipefail

ENDPOINT="${1:-}"
[ -z "$ENDPOINT" ] && { echo "ERROR: endpoint required as first argument"; exit 1; }

NAMESPACE="${NAMESPACE:-default}"

command -v kubectl >/dev/null || { echo "ERROR: kubectl required but not installed"; exit 1; }

kubectl -n "$NAMESPACE" exec deployment/cp-idp -- sh -c \
  'saml-idp add-connection "$1" -c /opt/idp/pki/sso-public-cert.pem --profileDatabase "${CP_IDP_PROFILE_DB:-/opt/idp/pdb/saml-idp-profiles.json}"' \
  _ "$ENDPOINT"
echo "IdP connection for $ENDPOINT added."
