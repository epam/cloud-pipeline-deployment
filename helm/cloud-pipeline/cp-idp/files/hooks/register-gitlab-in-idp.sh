#!/bin/bash
set -euo pipefail
kubectl -n "$NAMESPACE" exec deployment/cp-idp -- sh -c \
  'saml-idp add-connection "$1" -c /opt/idp/pki/sso-public-cert.pem --profileDatabase /opt/idp/saml-idp-profiles.json' \
  _ "$ISSUER"
echo "IdP connection for GitLab issuer $ISSUER added"
