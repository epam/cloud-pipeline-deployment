#!/bin/bash
set -euo pipefail
kubectl -n "$NAMESPACE" exec deployment/cp-idp -- bash -c \
  "saml-idp add-connection https://${API_SRV_HOST}:${API_SRV_PORT}/pipeline/ -c /opt/idp/pki/sso-public-cert.pem --profileDatabase \${CP_IDP_PROFILE_DB}"
echo "IdP connection for API server https://${API_SRV_HOST}:${API_SRV_PORT} added"
