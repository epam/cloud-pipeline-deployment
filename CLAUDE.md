# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository does

Infrastructure-as-code for deploying [Cloud Pipeline](https://github.com/epam/cloud-pipeline) — a bioinformatics
platform — onto a Kubernetes cluster on AWS. It has three layers:

1. **`packer/`** — Builds an AWS AMI (Amazon Linux 2023) with Kubernetes pre-installed. During the build, the entire
   `helm/` directory is copied to `/var/lib/cloud-pipeline/deploy/helm` on the AMI. On first boot the instance runs
   `kubeadm init` via a systemd service (`k8s-first-boot.service`).
2. **`infra/`** — Documents (and operators provision) the AWS infrastructure: EC2 instances, EFS/FSx shared
   filesystem, VPC/security group, IAM profile, S3 buckets. Each EC2 instance receives its role via user data that
   appends to `bootstrap.env`.
3. **`helm/`** — Helmfile-driven Helm charts that deploy Cloud Pipeline into that cluster. This is the primary working
   area.

**Full deployment sequence:** build AMI (`packer build`) → provision infrastructure (EC2 + EFS) → launch instances
with user data (node role, storage ID) → `k8s-first-boot.service` runs `kubeadm init`/`join` → generate PKI secrets
(`helm/prerequisites/`) → `helmfile apply`.

---

## Helm deployment

### Commands

All commands run from `/var/lib/cloud-pipeline/deploy/helm` on the EC2 instance (or the repo's `helm/` directory
locally). The `helmfile` binary is vendored at `helm/helmfile`.

```bash
# Required env var for diff plugin compatibility
export HELM_DIFF_IGNORE_UNKNOWN_FLAGS="true"

# Render all releases without applying
helmfile template

# Preview changes before applying
helmfile diff

# Deploy all releases in dependency order
helmfile apply

# Deploy a specific release only
helmfile apply --selector name=cp-api-srv

# Target a custom values file (default: values.yaml)
HELMFILE_VALUES=my-values.yaml helmfile apply
```

Helm charts depend on the `lib` library chart (`helm/cloud-pipeline/lib/`). After adding/changing `lib`, update
dependent charts:

```bash
helm dependency update helm/cloud-pipeline/cp-api-srv
helm dependency update helm/cloud-pipeline/cp-idp
# ...repeat for each chart with a lib dependency
```

### Packer AMI build

The AMI pre-installs: Docker 20.10.24, Helm v3.3.4, Helmfile v1.4.1, helm-diff v3.4.2, jq,
amazon-efs-utils, lustre-client, kubeadm/kubelet v1.15.4. Pre-loaded Docker images: Calico v3.14.1,
Flannel v0.26.4, kube-proxy v1.15.4, pause:3.1. kube-apiserver port range is patched to `80-32767`.

```bash
cd packer/aws
# Fill in variables.auto.pkrvars.hcl first (vpc_id, subnet_id, instance_type, security_group_id, region), then:
packer build .
```

Record the resulting AMI ID — it is needed in `postDeploy.clusterNetworksConfig` in `values.yaml` and in the
EC2 launch configuration for all cluster nodes.

---

## Infrastructure and node bootstrap

Every node determines its role at first boot from
`/var/lib/cloud-pipeline/deploy/k8s-bootstrap/bootstrap.env`. The AMI ships a commented-out skeleton; supply
real values by appending via **EC2 user data**:

```bash
#!/bin/bash
cat >> /var/lib/cloud-pipeline/deploy/k8s-bootstrap/bootstrap.env <<'EOF'
ROLE=master-node           # master-node (default) or application-node
CP_STORAGE_TYPE=efs
CP_STORAGE_ID=fs-xxxxxxxxxxxxxxxxx
APPLICATION_NODE_COUNT=2   # master waits until this many nodes join, then cleans up credentials
EOF
```

Key `bootstrap.env` variables:

| Variable                                            | Default                          | Description                                                                                                    |
|-----------------------------------------------------|----------------------------------|----------------------------------------------------------------------------------------------------------------|
| `ROLE`                                              | `master-node`                    | `master-node` or `application-node`                                                                            |
| `CP_STORAGE_TYPE`                                   | `efs`                            | `efs` or `lustre`                                                                                              |
| `CP_STORAGE_ID`                                     | unset                            | EFS filesystem ID (EFS only)                                                                                   |
| `CP_STORAGE_LUSTRE_DNS` / `CP_STORAGE_LUSTRE_MOUNT` | unset                            | FSx Lustre DNS name + mount name                                                                               |
| `APPLICATION_NODE_COUNT`                            | `0`                              | Expected application nodes; master cleans up join credentials when reached (2h fallback)                       |
| `CP_MASTER_NODE_LABELS`                             | unset                            | Comma-separated `key=value` labels applied to master; unset = apply full default set                           |
| `CP_APPLICATION_NODE_LABELS`                        | `cloud-pipeline/cp-api-srv=true` | Extra labels applied to application nodes at join time; `cloud-pipeline/application-node=true` is always added |
| `CP_KUBE_JOIN_TIMEOUT`                              | `600`                            | Seconds an application node polls for join credentials                                                         |

**Multi-node join flow:** master writes `K8S_JOIN_ENDPOINT`, `K8S_JOIN_TOKEN`, `K8S_JOIN_CA_CERT_HASH` plus
`admin.conf` into `/opt/.temp_kube_join/` on the shared EFS, then touches `ready.txt`. Application nodes
poll for `ready.txt` then run `kubeadm join`. `kube-join-watcher.service` on the master deletes the join
credentials and the bootstrap token Secret once all expected nodes have joined (or after 2h).

Node labels drive pod scheduling — every Cloud Pipeline service uses a `nodeSelector` matching
`cloud-pipeline/<service-name>=true`. In a single-node cluster the default master labels cover all services.
For multi-node clusters, set `CP_MASTER_NODE_LABELS` and `CP_APPLICATION_NODE_LABELS` explicitly to distribute
services across nodes.

Monitor first-boot progress:

```bash
journalctl -fu k8s-first-boot.service
journalctl -fu kube-join-watcher.service
```

---

## Prerequisites: TLS and PKI secrets

Four Kubernetes secrets must exist before `helmfile apply`. The certificate material can come from two sources:

- **Organization-provided (preferred)** — place your own cert files into `helm/prerequisites/certificates/` using
  the exact filenames listed below, then run only `create-cp-secrets.sh`.
- **Script-generated (self-signed fallback)** — use the `generate-*.sh` scripts to produce self-signed material,
  then run `create-cp-secrets.sh`.

Either way, `create-cp-secrets.sh` is the final step that reads the files and creates the Kubernetes secrets.

```bash
cd helm/prerequisites
chmod +x *.sh lib/*.sh

# Option A: generate all certs (self-signed)
./generate-cp-pki-certs.sh "$API_DOMAIN" "$DEPLOYMENT_ID"   # cp-pki-secret material
./generate-cp-jwt-pki-certs.sh                               # cp-jwt-pki-secret material
./generate-idp-certs.sh "$IDP_HOST" "" "$NAMESPACE"          # cp-idp-secret material

# Option B: supply org certs — place files in ./certificates/ (see required filenames below)

# Final step (both options): create the Kubernetes secrets
./create-cp-secrets.sh "$NAMESPACE"
```

### Required files per secret

**`cp-pki-secret`** — API TLS, SSO, and CA material:

| File                  | Content                                                                                                                                                                             |
|-----------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `ca-private-key.pem`  | CA private key                                                                                                                                                                      |
| `ca-public-cert.pem`  | CA certificate (PEM)                                                                                                                                                                |
| `ssl-private-key.pem` | API/TLS private key (RSA)                                                                                                                                                           |
| `ssl-public-cert.pem` | API/TLS certificate chain (cert + CA cert concatenated). SANs must cover `DNS:<api-domain>`, `DNS:*.<api-domain>`, and `DNS:docker.<api-domain>` (Docker registry reuses this cert) |
| `sso-private-key.pem` | SSO signing private key                                                                                                                                                             |
| `sso-public-cert.pem` | SSO signing certificate                                                                                                                                                             |
| `cp-api-srv-ssl.p12`  | PKCS#12 of `ssl-private-key.pem` + `ssl-public-cert.pem`, alias `ssl`, password `changeit` (override with `PKCS12_PASSWORD`)                                                        |
| `cp-api-srv-sso.p12`  | PKCS#12 of `sso-private-key.pem` + `sso-public-cert.pem`, alias `sso`, same password                                                                                                |

**`cp-jwt-pki-secret`** — internal JWT signing keys (no external PKI equivalent; generate with the script):

| File              | Content                                                                  |
|-------------------|--------------------------------------------------------------------------|
| `jwt.key.private` | RSA private key material — base64 body only, no PEM headers, no newlines |
| `jwt.key.public`  | RSA public key material — same format                                    |
| `jwt.key.x509`    | PEM X.509 certificate wrapping the public key                            |

**`cp-idp-secret`** — SAML signing cert for the built-in IdP (not needed when `idp.enabled: false`):

| File                  | Content                                                                         |
|-----------------------|---------------------------------------------------------------------------------|
| `idp-private-key.pem` | SAML signing private key                                                        |
| `idp-public-cert.pem` | SAML signing certificate; must be registered with the external IdP if using one |

**`cp-fed-metadata-secret`** — SAML federation metadata XML from the IdP (not a file in `certificates/`; created
separately or seeded automatically when `idp.enabled: true`).

---

## Architecture: release order and dependencies

`helm/helmfile.yaml.gotmpl` is the entrypoint. It reads `helm/values.yaml` (deployment config), merges it with each
chart's own `values.yaml`, and renders releases in this strict order:

```
cp-resources → cp-idp (if idp.enabled)
             → cp-api-db (if db.type=internal)
             → cp-api-srv → [Kubernetes Jobs: register-cloud-region, register-system-folder, register-system-storage]
                          → cp-monitoring
                          → cp-docker-registry (if dockerRegistry.enabled)
                          → cp-search (if search.enabled)
                          → cp-billing-srv (if billing.enabled)
                          → cp-git → [Kubernetes Job: configure-git]
                          → cp-notifier (if notifier.enabled)
                          → cp-edge
[global cleanup hooks: wait-for-api, apply-preferences, apply-cluster-networks-config,
                       register-additional-cloud-regions, register-docker-tools,
                       register-demo-pipelines, register-email-templates]
```

| Release              | Chart                | Purpose                                                                                                                                              |
|----------------------|----------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `cp-resources`       | `cp-resources`       | `cp-config-global` ConfigMap (shared config), PKI/JWT secrets (generated or pre-created), RBAC                                                       |
| `cp-idp`             | `cp-idp`             | In-cluster SAML IdP (optional).                                                                                                                      |
| `cp-api-db`          | `cp-api-db`          | Internal Postgres on hostPath `/opt/postgresql/data` (only when `db.type: internal`)                                                                 |
| `cp-api-srv`         | `cp-api-srv`         | Main API server                                                                                                                                      |
| `cp-monitoring`      | `cp-monitoring`      | Monitoring stack: heapster + ELK, node-logger (DaemonSet), node-reporter (DaemonSet), vm-monitor; patches `cp-config-global` with heapster endpoints |
| `cp-docker-registry` | `cp-docker-registry` | Internal Docker registry                                                                                                                             |
| `cp-search`          | `cp-search`          | Elasticsearch + search-srv (optional). Node labelling required: `cloud-pipeline/cp-search-srv` and `cloud-pipeline/cp-search-elk`                    |
| `cp-billing-srv`     | `cp-billing-srv`     | Billing report agent; syncs billing data to Elasticsearch. Requires node label `cloud-pipeline/cp-billing-srv=true`                                  |
| `cp-git`             | `cp-git`             | GitLab instance + optional Postgres (`cp-gitlab-db`)                                                                                                 |
| `cp-notifier`        | `cp-notifier`        | Email / Azure-Graph notifier (optional). Patches `cp-config-global` with `CP_NOTIFIER_*` keys                                                        |
| `cp-edge`            | `cp-edge`            | Edge proxy/gateway                                                                                                                                   |

### cp-config-global patching pattern

Every chart that needs to expose configuration to other components does so by patching the shared `cp-config-global`
ConfigMap. The pattern is:

1. The chart's `hook-patch-config-global-*.yaml` template builds a `$data` dict using individual
   `{{- set $data "KEY" value -}}` calls (one per line for readability), then renders it as a
   `configmap-to-update-<service-name>` ConfigMap.
2. The shared `lib.cpConfigGlobal.patchHookTemplate` (from `lib/templates/_hook-patch-cp-config-global.tpl`) creates a
   pre-install/pre-upgrade hook Job that reads the above ConfigMap and `kubectl patch`-es each key into
   `cp-config-global` only when the value has changed.

### Secrets

Four Kubernetes secrets are required before deployment (see `helm/prerequisites/` and the
[Prerequisites section](#prerequisites-tls-and-pki-secrets) above for required file formats):

| Secret                   | Source                                                                                    |
|--------------------------|-------------------------------------------------------------------------------------------|
| `cp-pki-secret`          | Org-provided or `generate-cp-pki-certs.sh` → `create-cp-secrets.sh`                       |
| `cp-jwt-pki-secret`      | `generate-cp-jwt-pki-certs.sh` → `create-cp-secrets.sh` (internal; no org PKI equivalent) |
| `cp-fed-metadata-secret` | SAML IdP metadata XML; seeded automatically when `idp.enabled: true`                      |
| `cp-idp-secret`          | Org-provided or `generate-idp-certs.sh` → `create-cp-secrets.sh`                          |

### Hooks overview

**Pre-deploy `prepare` hook** (bash, runs on the deploying host before any release):

- `hooks/validation/validate-values.sh` — validates `values.yaml` against per-release rules in
  `hooks/validation/releases/`. Fails fast on misconfigured values before any Kubernetes changes.

**Post-release Kubernetes Jobs** (run inside the cluster after each release syncs):

- After `cp-api-srv`: `register-cloud-region.sh`, `register-system-folder.sh`, `register-system-storage.sh`
  (scripts live in `cp-api-srv/files/hooks/` and are mounted into hook Job pods)
- After `cp-git`: `configure-git.sh`

**Global `cleanup` hooks** (bash, run on the deploying host after all releases complete):

1. `wait-for-api.sh` — polls until the Cloud Pipeline REST API is up
2. `apply-preferences.sh` — uploads system preferences to the API; loads from
   `hooks/post-deploy/assets/preferences/*.json` (defaults, split by topic: base, cluster, commit, data, etc.),
   then optionally from `CP_SYSTEM_PREFERENCE_CONFIG` (file or dir, wins on conflict); also sets computed prefs
   like `base.cloud.data.distribution.url`
3. `apply-cluster-networks-config.sh` — posts `postDeploy.clusterNetworksConfig` as the `cluster.networks.config`
   API preference
4. `register-additional-cloud-regions.sh` — registers any additional AWS regions from
   `postDeploy.additionalCloudRegions`
5. `register-docker-tools.sh` — pushes/registers Docker images from `hooks/post-deploy/assets/dockers-manifest/`;
   image list controlled by `postDeploy.dockers` in `values.yaml`
6. `register-demo-pipelines.sh` — registers pipelines from `hooks/post-deploy/assets/pipe-demo/` (only when
   `git.enabled: true`)
7. `register-email-templates.sh` — registers email templates from `hooks/post-deploy/assets/email-templates/`

All scripts source `hooks/post-deploy/utils/cloud-pipeline-utils.sh` for shared API helpers.

### Docker tools manifest

`hooks/post-deploy/assets/dockers-manifest/` contains one directory per tool image. Directory names use Docker's
`name:tag` convention (e.g. `centos:7`, `ubuntu:18.04`) — **the colon is invalid on Windows**, so this repo cannot
be checked out on Windows. Each tool directory contains `spec.json` (tool registration metadata), optionally
`icon.png`, and `README.md`. Only tools listed in `postDeploy.dockers` in `values.yaml` are actually registered;
the full manifest directory is the superset.

### Key configuration values (`helm/values.yaml`)

- `general.namespace` — Kubernetes namespace (default: `default`)
- `resources.config.global.*` — Merged into `cp-config-global`; includes `CP_KUBE_EXTERNAL_HOST`,
  `CP_CLOUD_REGION_ID`, AWS KMS/IAM ARNs, admin credentials
- `idp.enabled` — Deploy in-cluster IdP (true) or use external SAML IdP (false)
- `apiSrv.db.type` — `external` (RDS or managed) or `internal` (in-cluster Postgres)
- `apiSrv.cloudRegion.corsRules` — S3 CORS policy for the primary region. Absent = use
  `hooks/post-deploy/assets/storage.cors.policy.json`; a path string = read JSON file at helmfile render time;
  an inline `[...]`/`{...}` string = use as-is. File-path form is not supported for `additionalCloudRegions`.
- `edge.region` — AWS region of the edge node
- `edge.externalIP` — Public IP of the edge node (used in DNS and run endpoints)
- `git.enabled` — Deploy GitLab (true/false); also controls whether `cp-edge` waits on `cp-git`
- `search.enabled` — Deploy search stack (false by default)
- `billing.enabled` — Deploy billing agent (true by default)
- `notifier.enabled` — Deploy email/Azure notifier (false by default)
- `monitoring.enabled` — Deploy entire monitoring stack (true by default); individual components toggled via
  `monitoring.heapster.enabled`, `monitoring.nodeLogger.enabled`, `monitoring.nodeReporter.enabled`,
  `monitoring.vmMonitor.enabled`
- `postDeploy.systemPreferenceConfig` — Path to a custom preferences JSON file or directory; overrides
  `hooks/post-deploy/assets/preferences/` defaults. Can also be set via `CP_SYSTEM_PREFERENCE_CONFIG` env var.
- `postDeploy.clusterNetworksConfig` — AMI IDs, subnets, security groups for worker node pools
- `postDeploy.additionalCloudRegions` — List of additional AWS regions to register after deployment; each entry
  uses the same fields as `apiSrv.cloudRegion` with `regionId` and `kmsKeyArn` required
- `postDeploy.dockers` — List of tool images to register post-deploy

### Library chart templates (`helm/cloud-pipeline/lib/`)

Shared Go templates used by all application charts:

- `_hook-patch-cp-config-global.tpl` — Pre-install/upgrade Job that patches `cp-config-global`
- `_hook-patch-dnsmasq-hosts.tpl` — DNS patch hook
- `_hook-service-account.tpl` — RBAC for hook Jobs
- `_hook-deployment-image.tpl` — Resolves the container image used by hook Jobs
- `_backup-worker.tpl` — Backup worker sidecar template
- `_namespace.tpl` / `_cp-api-token-secret-name.tpl` — Namespace and token secret helpers

All application charts declare `lib` as a dependency (`file://../lib`). The `.tgz` in each `charts/` directory is the
packaged library and must be kept in sync with `lib/`.
