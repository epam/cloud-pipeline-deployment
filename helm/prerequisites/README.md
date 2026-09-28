# Prerequisites: TLS and PKI for Cloud Pipeline

Create Kubernetes secrets **before** running `helmfile apply`. These secrets contain the TLS
certificates and signing keys used by all Cloud Pipeline services.

**Requirements:** `openssl`, `kubectl` configured to connect to your cluster.

Verify both are available:

```bash
openssl version
kubectl cluster-info
```

---

## Choose your path

| I have... | Go to |
|---|---|
| A certificate file and private key | [Step 1 — Set your variables](#step-1--set-your-variables) |
| Nothing — need a free trusted certificate | [Let's Encrypt](#lets-encrypt) |
| Nothing — need a temporary self-signed certificate for testing | [Self-signed quick start](#self-signed-quick-start-lab-and-testing-only) |
| Expired certificates that need to be renewed | [Updating secrets after certificate renewal](#updating-secrets-after-certificate-renewal) |

---

## Step 1 — Set your variables

Open a terminal, go to this directory, and fill in the three values below:

```bash
cd cloud-pipeline-deployment/helm/prerequisites
chmod +x *.sh lib/*.sh

API_DOMAIN="cloud-pipeline.example.com"   # your deployment domain
IDP_HOST="idp.$API_DOMAIN"
NAMESPACE="default"                        # Kubernetes namespace for this deployment
```

---

## Step 2 — Point to your certificate

Set `TLS_CERT` and `TLS_KEY` to the paths of your certificate and private key files:

```bash
export TLS_CERT=/path/to/certificate.pem
export TLS_KEY=/path/to/private-key.pem
```

> **Full chain required.** `TLS_CERT` must contain the full certificate chain — your server
> certificate followed by any intermediate certificates, all in one PEM file. To check:
> ```bash
> grep -c "BEGIN CERTIFICATE" "$TLS_CERT"
> # Should print 2 or more
> ```
> If it prints 1, ask whoever provided the certificate for the full chain version.

**If you have separate certificates for individual services** (e.g. a dedicated certificate
for the Docker registry, Git, or other services), set the corresponding variables before
proceeding to Step 3. Any service without a dedicated variable uses `TLS_CERT`/`TLS_KEY`:

```bash
export DOCKER_TLS_CERT=/path/to/docker-cert.pem
export DOCKER_TLS_KEY=/path/to/docker-key.pem
export GIT_TLS_CERT=/path/to/git-cert.pem
export GIT_TLS_KEY=/path/to/git-key.pem
# EDGE_TLS_CERT      / EDGE_TLS_KEY
# IDP_TLS_CERT       / IDP_TLS_KEY
# SHARE_SRV_TLS_CERT / SHARE_SRV_TLS_KEY
```

---

## Step 3 — Generate PKI material and create secrets

Run all four commands in order:

```bash
# 1) Import your certificate — creates all per-service cert pairs and .p12 files
./generate-cp-pki-certs.sh "$API_DOMAIN"

# 2) JWT signing keys (internal; not related to your TLS certificate)
./generate-cp-jwt-pki-certs.sh

# 3) IdP SAML signing certificate (generated independently from your TLS certificate)
./generate-idp-certs.sh "$IDP_HOST" "" "$NAMESPACE"

# 4) Create all Kubernetes secrets
./create-cp-secrets.sh "$NAMESPACE"
```

Verify the secrets were created:

```bash
kubectl get secret cp-pki-secret cp-jwt-pki-secret cp-idp-secret -n "$NAMESPACE"
```

All three should show `TYPE: Opaque`. You are now ready to run `helmfile apply`.

---

## Let's Encrypt

Free, publicly trusted certificates. Expire every 90 days and must be renewed manually.

**Step 1 — Run certbot in Docker:**

```bash
docker run -it --rm --name certbot \
  -v "/etc/letsencrypt:/etc/letsencrypt" \
  -v "/var/lib/letsencrypt:/var/lib/letsencrypt" \
  --entrypoint /bin/sh \
  certbot/certbot
```

**Step 2 — Request the certificate inside the container:**

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

Certbot will provide 2 token values and ask you to add them as DNS TXT records under
`_acme-challenge.<your-domain>`. Add both values to your DNS configuration, then verify
propagation before pressing Enter:

```bash
dig TXT _acme-challenge.<your-cloud-pipeline-domain-name>
```

Or use the [Google Admin Toolbox](https://toolbox.googleapps.com/apps/dig/#TXT/_acme-challenge.<your-cloud-pipeline-domain-name>).
Look for both token values in the `;ANSWER` section.

After success, certificates are saved to `/etc/letsencrypt/live/<your-domain>/`:

- `fullchain.pem` — full certificate chain
- `privkey.pem` — private key

**Step 3 — Continue from [Step 1](#step-1--set-your-variables) above, setting:**

```bash
export TLS_CERT=/etc/letsencrypt/live/$API_DOMAIN/fullchain.pem
export TLS_KEY=/etc/letsencrypt/live/$API_DOMAIN/privkey.pem
```

---

## Self-signed quick start (lab and testing only)

Generates a local CA and self-signed certificates in one go. Browsers and external clients
will show certificate warnings. Not suitable for production.

Fill in your values and run all four commands:

```bash
cd cloud-pipeline-deployment/helm/prerequisites
chmod +x *.sh lib/*.sh

API_DOMAIN="cloud-pipeline.example.com"   # your deployment domain
IDP_HOST="idp.$API_DOMAIN"
NAMESPACE="default"                        # Kubernetes namespace for this deployment

# 1) Generate self-signed CA, TLS, and SSO certificates
./generate-cp-pki-certs.sh "$API_DOMAIN" "$NAMESPACE"

# 2) JWT signing keys (internal)
./generate-cp-jwt-pki-certs.sh

# 3) IdP SAML signing certificate
./generate-idp-certs.sh "$IDP_HOST" "" "$NAMESPACE"

# 4) Create all Kubernetes secrets
./create-cp-secrets.sh "$NAMESPACE"
```

Verify the secrets were created:

```bash
kubectl get secret cp-pki-secret cp-jwt-pki-secret cp-idp-secret -n "$NAMESPACE"
```

All three should show `TYPE: Opaque`. You are now ready to run `helmfile apply`.

---

## Updating secrets after certificate renewal

Start by setting your variables:

```bash
cd cloud-pipeline-deployment/helm/prerequisites
chmod +x *.sh lib/*.sh

API_DOMAIN="cloud-pipeline.example.com"   # your deployment domain
IDP_HOST="idp.$API_DOMAIN"
NAMESPACE="default"                        # Kubernetes namespace for this deployment
```

**If your certificate came from Let's Encrypt**, re-run certbot first to obtain a fresh
certificate (same process as the initial setup), then continue below. The renewed certificate
will be saved to the same path as before:

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

Once certbot completes, set the certificate paths and continue:

```bash
export TLS_CERT=/etc/letsencrypt/live/$API_DOMAIN/fullchain.pem
export TLS_KEY=/etc/letsencrypt/live/$API_DOMAIN/privkey.pem
```

**If your certificate came from an org CA or other source**, point to the new files:

```bash
export TLS_CERT=/path/to/new-certificate.pem
export TLS_KEY=/path/to/new-private-key.pem
```

Then run all renewal steps in order:

```bash
# 1) Re-generate cert files from the new certificate
./generate-cp-pki-certs.sh "$API_DOMAIN"

# 2) Regenerate IdP SAML certificate
./generate-idp-certs.sh "$IDP_HOST" "" "$NAMESPACE"

# 3) Re-create Kubernetes secrets
./create-cp-secrets.sh "$NAMESPACE"

# 4) Restart all affected deployments
kubectl rollout restart deployment/cp-api-srv deployment/cp-edge \
  deployment/cp-docker-registry deployment/cp-git \
  deployment/cp-idp deployment/cp-share-srv -n "$NAMESPACE"
```

> JWT signing keys (`cp-jwt-pki-secret`) do not expire with TLS certificates — skip
> `generate-cp-jwt-pki-certs.sh` on renewal unless you explicitly want to rotate JWT keys.

**When cp-idp is enabled:** after it restarts, re-register the SAML connection and refresh
the federation metadata secret:

```bash
# Re-register SP connection (run after cp-idp pod is Ready):
kubectl exec deployment/cp-idp -n "$NAMESPACE" -- bash -c \
  "saml-idp add-connection https://$API_DOMAIN:443/pipeline/ \
   -c /opt/idp/pki/sso-public-cert.pem \
   --profileDatabase /opt/idp/saml-idp-profiles.json"

# Fetch fresh IdP metadata and update the secret:
curl -fsSk "https://cp-idp.default.svc.cluster.local:443/metadata" \
  -H "Host: $IDP_HOST:443" \
  -o cp-api-srv-fed-meta.xml

kubectl create secret generic cp-api-srv-fed-metadata-secret -n "$NAMESPACE" \
  --from-file=cp-api-srv-fed-meta.xml=cp-api-srv-fed-meta.xml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/cp-api-srv -n "$NAMESPACE"
```

---

## Next steps

With all secrets in place, proceed to `helmfile apply`. See `helm/README.md` for the full
release order and deployment instructions.
