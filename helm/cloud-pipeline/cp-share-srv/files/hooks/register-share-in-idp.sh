#!/bin/bash
# Helm post-install/post-upgrade Job: register cp-share-srv SAML endpoint with cp-idp.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"

command -v kubectl >/dev/null || { echo "ERROR: kubectl required but not installed"; exit 1; }

[ -z "${CP_SHARE_SRV_EXTERNAL_HOST:-}" ] && { echo "ERROR: CP_SHARE_SRV_EXTERNAL_HOST not set in cp-config-global"; exit 1; }
[ -z "${CP_SHARE_SRV_EXTERNAL_PORT:-}" ] && { echo "ERROR: CP_SHARE_SRV_EXTERNAL_PORT not set in cp-config-global"; exit 1; }

ENDPOINT="https://${CP_SHARE_SRV_EXTERNAL_HOST}:${CP_SHARE_SRV_EXTERNAL_PORT}/proxy/"
IDP_PDB="${CP_IDP_PROFILE_DB:-/opt/idp/pdb/saml-idp-profiles.json}"
SSO_CERT="/opt/idp/pki/sso-public-cert.pem"

echo "Registering share-srv endpoint ${ENDPOINT} with cp-idp ..."
kubectl -n "$NAMESPACE" exec deployment/cp-idp -- bash -c \
  "saml-idp add-connection ${ENDPOINT} -c ${SSO_CERT} --profileDatabase ${IDP_PDB}"
echo "IdP connection for cp-share-srv registered."
