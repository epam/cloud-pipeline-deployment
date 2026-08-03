# Cloud-Pipeline deployment prerequisites

This document describes the procedure to create Kubernetes secrets required for the Cloud-Pipeline Helm deployment,
including prerequisites and how each secret is used.

## Kubernetes secrets: Creation process

All secrets below are required for the Helm deployment to work. Replace `<namespace-name>` in commands with your
Kubernetes namespace.

Secrets:

- `cp-pki-secret`
- `cp-jwt-pki-secret`
- `cp-api-srv-fed-metadata-secret`
- `cp-idp-secret`

The sections below describe how to create each secret.

### Secret: `cp-pki-secret`

**Description**  
Contains TLS materials, PKCS#12 bundles, and JWT keys used by Cloud-Pipeline components.

**Used by**

- `cp-api-srv` deployment: mounts this secret at `/opt/api/pki` (files are read from this path by the API container).
- `cp-edge` deployment: mounts this secret (projected together with `cp-jwt-pki-secret`) at `/opt/api/pki`,
  `/opt/idp/pki`, `/opt/edge/pki`, and conditionally at `/etc/gitlab/pki` when `git.enabled: true`.

**Prerequisites**

- `kubectl` access to the target cluster and namespace
- `openssl` available on PATH
- Files present in your current folder:
    - `ssl-private-key.pem` - SSL private key generated and signed by Grunenthal CA for Cloud-Pipeline domain (f.e.
      cloud-pipeline.grtgroup.com)
    - `ssl-public-cert.pem` - SSL public key generated and signed by Grunenthal CA for Cloud-Pipeline domain (f.e.
      cloud-pipeline.grtgroup.com)

**Generate required assets (run in the same folder)**
If your existing files have different names, rename them first:

```
mv <your-ssl-cert>.pem ssl-public-cert.pem
mv <your-ssl-key>.pem ssl-private-key.pem
```

In the folder with your PEM certificate and private key, generate `sso-*`, and `*.p12` assets:

```
cp ssl-public-cert.pem sso-public-cert.pem
cp ssl-private-key.pem sso-private-key.pem
chmod 644 sso-public-cert.pem
chmod 640 sso-private-key.pem

openssl pkcs12 -export \
  -inkey ssl-private-key.pem \
  -in ssl-public-cert.pem \
  -out cp-api-srv-ssl.p12 \
  -name ssl \
  -passout pass:changeit
chmod 644 cp-api-srv-ssl.p12

openssl pkcs12 -export \
  -in sso-public-cert.pem \
  -inkey sso-private-key.pem \
  -out cp-api-srv-sso.p12 \
  -name sso \
  -passout pass:changeit
chmod 644 cp-api-srv-sso.p12
```

**Create secret**

```
kubectl create secret generic cp-pki-secret \
  --from-file=ssl-private-key.pem=ssl-private-key.pem \
  --from-file=ssl-public-cert.pem=ssl-public-cert.pem \
  --from-file=sso-private-key.pem=sso-private-key.pem \
  --from-file=sso-public-cert.pem=sso-public-cert.pem \
  --from-file=cp-api-srv-ssl.p12=cp-api-srv-ssl.p12 \
  --from-file=cp-api-srv-sso.p12=cp-api-srv-sso.p12 \
  -n <namespace-name>
```

**Verify**

```
kubectl get secret cp-pki-secret -n <namespace-name>
```

### Secret `cp-jwt-pki-secret`

**Description**  
Contains JWT keys used by Cloud-Pipeline components.

**Used by**

- `cp-api-srv` deployment: mounts this secret at `/opt/api/pki` (files are read from this path by the API container).
- Helm pre-install/pre-upgrade job `pre-deploy-jwt-generator`: mounts this secret at `/opt/api/pki` and uses
  `jwt.key.private` to generate an admin JWT token.

**Prerequisites**

- `kubectl` access to the target cluster and namespace
- `openssl` available on PATH

**Generate required assets (run in the same folder)**

```
openssl genpkey -algorithm RSA -out jwt.key.private.tmp -pkeyopt rsa_keygen_bits:1024
openssl rsa -pubout -in jwt.key.private.tmp -out jwt.key.public.tmp
openssl req -new -x509 -key jwt.key.private.tmp -sha256 -nodes \
  -out jwt.key.x509.pem -days 7300 -subj "/CN=Cloud-Pipeline-JWT"
sed '$d' < jwt.key.private.tmp | sed "1d" | tr -d '\n' > jwt.key.private
sed '$d' < jwt.key.public.tmp | sed "1d" | tr -d '\n' > jwt.key.public
rm -f jwt.key.private.tmp jwt.key.public.tmp
chmod 600 jwt.key.private
chmod 644 jwt.key.public
chmod 644 jwt.key.x509.pem
```

**Create secret**

```
kubectl create secret generic cp-jwt-pki-secret \
  --from-file=jwt.key.private=jwt.key.private \
  --from-file=jwt.key.public=jwt.key.public \
  --from-file=jwt.key.x509=jwt.key.x509.pem \
  -n <namespace-name>
```

**Verify**

```
kubectl get secret cp-jwt-pki-secret -n <namespace-name>
```

### Secret: `cp-api-srv-fed-metadata-secret`

**Description**  
Contains the SSO federation metadata for Cloud-Pipeline SSO/SAML integration.

**Used by**

- `cp-api-srv` pod: mounts this secret at `/opt/api/sso` (metadata file is read from this folder by the API container).

**Prerequisites**

- `kubectl` access to the target cluster and namespace
- IdP Metadata file present in your current folder: `cp-api-srv-fed-meta.xml`
- If your IdP metadata has a different name, rename it:

```
mv <your-idp-metadata>.xml cp-api-srv-fed-meta.xml
```

> **Note:** Remove the `<Signature>` block from `cp-api-srv-fed-meta.xml` to avoid validation errors.

**Create secret**

```
kubectl create secret generic cp-api-srv-fed-metadata-secret \
  --from-file=cp-api-srv-fed-meta.xml=cp-api-srv-fed-meta.xml \
  -n <namespace-name>
```

**Verify**

```
kubectl get secret cp-api-srv-fed-metadata-secret -n <namespace-name>
```

### Secret: `cp-idp-secret` (external IdP)

**Description**  
Trust material for SAML IdP signing verification. The `cp-api-srv` pod mounts this secret at `/opt/idp/pki` (
`CP_IDP_CERT_DIR`).

**Prerequisites**

- IdP **signing** public certificate from your SAML IdP (PEM), saved as `idp-public-cert.pem` in your current folder.
- The in-cluster IdP hook also stores `idp-private-key.pem` in this secret. If your API image expects that key, include
  it (PEM) in the same `kubectl create secret` command; otherwise start with `idp-public-cert.pem` only.

**Create secret**

```
kubectl create secret generic cp-idp-secret \
  --from-file=idp-public-cert.pem=idp-public-cert.pem \
  -n <namespace-name>
```

**Verify**

```
kubectl get secret cp-idp-secret -n <namespace-name>
```

After all secrets are created, you can run Helm to deploy Cloud-Pipeline.

## Kubernetes secrets: Update process

When SSL key pair expired you will need to request a new one and update secret value with it.
After you receive a new key pair, here are the steps to update Cloud-Pipeline Platform with it:

> You need to login to the machine where you have access to manage kubernetes cluster.

0. Create temporary folder for the procedure:

```
export UPDATE_KUBE_SECRET_DIR=$(mktemp -d)
cd $UPDATE_KUBE_SECRET_DIR
```

### cp-pki-secret

1. Backup previous secret:

```
kubectl get secret cp-pki-secret -n <namespace-name> -o yaml > "$UPDATE_KUBE_SECRET_DIR/cp-pki-secret.bkp.yaml"
```

2. Follow the procedure from `Kubernetes secrets: Creation process` to prepare all required files for `cp-pki-secret`
   creation

3. Generate `yaml` secret config with the following command:

```
kubectl create secret generic cp-pki-secret \
  --from-file=ssl-private-key.pem=ssl-private-key.pem \
  --from-file=ssl-public-cert.pem=ssl-public-cert.pem \
  --from-file=sso-private-key.pem=sso-private-key.pem \
  --from-file=sso-public-cert.pem=sso-public-cert.pem \
  --from-file=cp-api-srv-ssl.p12=cp-api-srv-ssl.p12 \
  --from-file=cp-api-srv-sso.p12=cp-api-srv-sso.p12 \
  -n <namespace-name> \
  --dry-run=client \
  -o yaml > cp-pki-secret.yaml
```

4. Apply this yaml to update existing secret:

```
kubectl apply -f cp-pki-secret.yaml
```

5. If previous step was successfully completed, restart `cp-api-srv` and `cp-edge` pods:

```
kubectl rollout restart <deployment> -n <namespace-name>

kubectl rollout restart cp-api-srv cp-edge -n <namespace-name>
```

After all pods will be ready, Cloud-Pipeline should be available again.
