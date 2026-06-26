# Prerequisites: TLS and PKI for Cloud Pipeline

Generate certificate files locally, then create Kubernetes secrets **before** `helmfile apply`.

Requires: `openssl`, `kubectl` (for `create-cp-secrets.sh` only).

## Scripts

| Generate                       | Kubernetes secret                                         |
|--------------------------------|-----------------------------------------------------------|
| `generate-cp-pki-certs.sh`     | `cp-pki-secret` (API, edge, registry TLS via `ssl-*.pem`) |
| `generate-cp-jwt-pki-certs.sh` | `cp-jwt-pki-secret`                                       |
| `generate-idp-certs.sh`        | `cp-idp-secret`                                           |

| Create secrets         |                              |
|------------------------|------------------------------|
| `create-cp-secrets.sh` | All of the above in one step |

Shared helpers: `lib/cert-common.sh`.

Generated files are written under `certificates/` in this directory (gitignored). All generate scripts use the same
folder; filenames do not overlap.

Override with `OUTPUT_DIR` / the optional second argument to `create-cp-secrets.sh` if needed.

## Typical flow

Replace hostnames and namespace with your values.

```bash
cd cloud-pipeline-deployment/helm/prerequisites
chmod +x *.sh lib/*.sh

API_DOMAIN="pipeline.example.com"
IDP_HOST="idp.pipeline.example.com"
NAMESPACE="cloud-pipeline"
DEPLOYMENT_ID="$NAMESPACE"

# 1) API CA + TLS + SSO (cp-pki-secret; registry reuses ssl-*.pem in Helm)
./generate-cp-pki-certs.sh "$API_DOMAIN" "$DEPLOYMENT_ID"

# 2) JWT signing keys (cp-jwt-pki-secret)
./generate-cp-jwt-pki-certs.sh

# 3) IdP SAML signing cert (cp-idp-secret)
./generate-idp-certs.sh "$IDP_HOST" "" "$NAMESPACE"

# 4) Create all secrets
./create-cp-secrets.sh "$NAMESPACE"
```

## Notes

- **Docker registry TLS** uses the same `ssl-*.pem` as the API (`cp-pki-secret`), mounted as `docker-*.pem` in Helm.
  Include `docker.<api-domain>` (or your registry hostname) in the API cert SAN when using a customer-provided
  certificate.
- **IdP HTTPS** also uses `ssl-*.pem` from `cp-pki-secret`; ensure the API/IdP external hostname is covered by the API
  TLS cert or use a matching domain.
- **PKCS#12 password** for `cp-api-srv-ssl.p12` and `cp-api-srv-sso.p12` defaults to `changeit`. Override with
  `PKCS12_PASSWORD`.
- Set `REPLACE_SECRET=false` to avoid deleting existing secrets before create.

## Helm

Create all required secrets in the target namespace before installing `cp-resources` and related charts. See
`helm/README.md` for release order.
