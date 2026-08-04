# Prerequisites: TLS and PKI for Cloud Pipeline

Generate certificate files locally, then create Kubernetes secrets **before** `helmfile apply`.

Requires: `openssl`, `kubectl` (for `create-cp-secrets.sh` only).

## Scripts

| Generate                       | Kubernetes secret                                                              |
|--------------------------------|--------------------------------------------------------------------------------|
| `generate-cp-pki-certs.sh`     | `cp-pki-secret` (self-signed CA + API TLS + SSO, or import from Let's Encrypt) |
| `generate-cp-jwt-pki-certs.sh` | `cp-jwt-pki-secret`                                                            |
| `generate-idp-certs.sh`        | `cp-idp-secret`                                                                |

| Create secrets         |                                                                                      |
|------------------------|--------------------------------------------------------------------------------------|
| `create-cp-secrets.sh` | All of the above in one step; also creates `cp-share-srv-pki-secret` automatically  |

Shared helpers: `lib/cert-common.sh`.

Generated files are written under `certificates/` in this directory (gitignored). All generate scripts use the same
folder; filenames do not overlap.

Override with `OUTPUT_DIR` / the optional second argument to `create-cp-secrets.sh` if needed.

## Typical flow — self-signed certificates

> Replace hostnames and namespace with your values.

```bash
cd cloud-pipeline-deployment/helm/prerequisites
chmod +x *.sh lib/*.sh

API_DOMAIN="<your-cloud-pipeline-domain-name>"
IDP_HOST="idp.<your-cloud-pipeline-domain-name>"
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

## Typical flow — Let's Encrypt certificates

You can generate certificates from Let's Encrypt using Certbot; they will be valid for 3 months. Here is how you can do
this:

### Step 0 — Obtain the certificate via certbot

Run certbot in Docker using the DNS-01 challenge (required for wildcard certs):

```bash
docker run -it --rm --name certbot \
  -v "/etc/letsencrypt:/etc/letsencrypt" \
  -v "/var/lib/letsencrypt:/var/lib/letsencrypt" \
  --entrypoint /bin/sh \
  certbot/certbot
```

Inside the container:

```bash
certbot certonly \
  --manual \
  --preferred-challenges dns \
  --server https://acme-v02.api.letsencrypt.org/directory \
  --register-unsafely-without-email \
  -d "<your-cloud-pipeline-domain-name>" \
  -d "*.<your-cloud-pipeline-domain-name>"
```

When prompted, agree to the Terms of Service by typing `yes`.

Certbot will provide 2 string values and request to add it as DNS TXT records under `_acme-challenge.<your-cloud-pipeline-domain-name>`. 
Add both values to your DNS configuration before pressing Enter.

> **Note:** If your DNS provider supports multiple values per record, you can add both at once.
>
```
"<value-1>"
"<value-2>"
```

Verify propagation before pressing Enter:

```bash
dig TXT _acme-challenge.<your-cloud-pipeline-domain-name>
```

or the Google Admin Toolbox:

```
https://toolbox.googleapps.com/apps/dig/#TXT/_acme-challenge.<your-cloud-pipeline-domain-name>
```

Look for both token values in the `;ANSWER` section.

After success, certificates are saved at `/etc/letsencrypt/live/<your-cloud-pipeline-domain-name>/`:

- `fullchain.pem` — server cert + intermediate chain
- `privkey.pem` — private key (EC P-256)

> Certificate validity is **90 days**. Manual certificates do not auto-renew — repeat this step before expiry.

Set `TLS_CERT` and `TLS_KEY` before calling `generate-cp-pki-certs.sh` to enable import mode; all other steps are the same.

```bash
cd cloud-pipeline-deployment/helm/prerequisites
chmod +x *.sh lib/*.sh

API_DOMAIN="<your-cloud-pipeline-domain-name>"
IDP_HOST="idp.<your-cloud-pipeline-domain-name>"
NAMESPACE="cloud-pipeline"
export TLS_CERT=/etc/letsencrypt/live/$API_DOMAIN/fullchain.pem
export TLS_KEY=/etc/letsencrypt/live/$API_DOMAIN/privkey.pem

# 1) Import Let's Encrypt cert
./generate-cp-pki-certs.sh "$API_DOMAIN"

# 2) JWT signing keys — skip on renewal (JWT keys don't expire with TLS cert)
./generate-cp-jwt-pki-certs.sh

# 3) IdP SAML signing cert (always RSA; independent of Let's Encrypt cert)
./generate-idp-certs.sh "$IDP_HOST" "" "$NAMESPACE"

# 4) Create all secrets
./create-cp-secrets.sh "$NAMESPACE"
```

### Certificate renewal with Let's Encrypt

On renewal, only steps 1, 3, and 4 are needed. Skip JWT regeneration.

```bash
# 1) Re-import renewed cert
TLS_CERT=/etc/letsencrypt/live/$API_DOMAIN/fullchain.pem \
TLS_KEY=/etc/letsencrypt/live/$API_DOMAIN/privkey.pem \
./generate-cp-pki-certs.sh "$API_DOMAIN"

# 2) Regenerate IdP cert (cp-idp-secret must be updated when renewing)
./generate-idp-certs.sh "$IDP_HOST" "" "$NAMESPACE"

# 3) Re-apply secrets
./create-cp-secrets.sh "$NAMESPACE"

# 4) Restart affected services and refresh federation metadata
kubectl rollout restart deployment/cp-idp -n "$NAMESPACE"

# Re-register SP connection (run after cp-idp is ready):
kubectl exec deployment/cp-idp -- bash -c \
  "saml-idp add-connection https://$API_DOMAIN:443/pipeline/ -c /opt/idp/pki/sso-public-cert.pem --profileDatabase /opt/idp/saml-idp-profiles.json"

# Fetch fresh IdP metadata and update secret:
curl -fsSk "https://cp-idp.default.svc.cluster.local:443/metadata" \
  -H "Host: $IDP_HOST:443" \
  -o cp-api-srv-fed-meta.xml

kubectl create secret generic cp-api-srv-fed-metadata-secret -n "$NAMESPACE" \
  --from-file=cp-api-srv-fed-meta.xml=cp-api-srv-fed-meta.xml \
  --dry-run -o yaml | kubectl apply -f -

kubectl rollout restart deployment/cp-api-srv -n "$NAMESPACE"
```

## Helm

Create all required secrets in the target namespace before installing `cp-resources` and related charts. See
`helm/README.md` for release order.
