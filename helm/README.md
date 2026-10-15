# Helmfile layout for Cloud Pipeline

This directory uses [Helmfile](https://github.com/helmfile/helmfile) to deploy
Cloud Pipeline as **fifteen ordered releases** with explicit dependencies.

## Release order and dependencies

| Order | Release name                       | Installed condition                          | Depends on                                                   |
|-------|------------------------------------|----------------------------------------------|--------------------------------------------------------------|
| 1     | **cp-resources**                   | Always                                       | —                                                            |
| 2     | **cp-idp**                         | `idp.enabled: true`                          | cp-resources                                                 |
| 3     | **cp-api-db**                      | `apiSrv.db.type: internal`                   | cp-resources                                                 |
| 4     | **cp-api-srv**                     | Always                                       | cp-resources, cp-idp (+ cp-api-db if internal DB)            |
| 5     | **cp-monitoring**                  | `monitoring.enabled: true` (default on)      | cp-resources, cp-api-srv                                     |
| 5     | **cp-docker-registry**             | `dockerRegistry.enabled: true` (default on)  | cp-api-srv                                                   |
| 5     | **cp-search**                      | `search.enabled: true` (default off)         | cp-resources, cp-api-srv                                     |
| 5     | **cp-billing-srv**                 | `billing.enabled: true` (default on)         | cp-resources, cp-api-srv, cp-search                          |
| 5     | **cp-git**                         | `git.enabled: true` (default on)             | cp-resources, cp-idp, cp-api-srv                             |
| 5     | **cp-notifier**                    | `notifier.enabled: true` (default off)       | cp-resources, cp-api-srv                                     |
| 5     | **cp-storage-lifecycle-service**   | `storageLifecycle.enabled: true` (default on)| cp-resources, cp-api-srv                                     |
| 5     | **cp-dav**                         | `dav.enabled: true` (default on)             | —                                                            |
| 5     | **cp-share-srv**                   | `shareSrv.enabled: true` (default off)       | cp-resources, cp-idp, cp-api-srv                             |
| 5     | **cp-run-policy-manager**          | `runPolicyManager.enabled: true` (default off)| cp-resources, cp-api-srv                                    |
| 6     | **cp-edge**                        | Always                                       | cp-resources, cp-idp, cp-api-srv, cp-docker-registry, cp-git |

Releases at order 5 are independent of each other and run in parallel once cp-api-srv is ready.

## Secrets

| Secret                             | When needed                              | Source                                                                                                                                                                                                                        |
|------------------------------------|------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `cp-pki-secret`                    | Always                                   | `prerequisites/generate-cp-pki-certs.sh` + `prerequisites/create-cp-secrets.sh` (see `prerequisites/README.md`). Also carries cp-share-srv's TLS pair + p12s when `shareSrv.enabled: true` (`cp-share-srv-pki-secret` was folded into this secret). |
| `cp-jwt-pki-secret`                | Always                                   | `prerequisites/generate-cp-jwt-pki-certs.sh` + `prerequisites/create-cp-secrets.sh` (see `prerequisites/README.md`)                                                                                                           |
| `cp-api-srv-fed-metadata-secret`   | Always (API expects volume)              | **`idp.enabled: true`:** seeded empty by cp-idp pre-install hook, patched with IdP metadata by `hook-register-api-srv-in-idp`. **`idp.enabled: false`:** create manually from IdP metadata XML before cp-api-srv.            |
| `cp-idp-secret`                    | Always (API expects volume)              | **`idp.enabled: true`:** created by cp-idp chart; cert hook fills keys. **`idp.enabled: false`:** create manually.                                                                                                            |
| `cp-share-srv-fed-metadata-secret` | `shareSrv.enabled: true`                 | **`idp.enabled: true`:** seeded empty and patched by `hook-register-share-srv-in-idp`. **`idp.enabled: false`:** create manually.                                                                                             |

## Configuration

- **namespace**: Set `general.namespace` in `values.yaml` (e.g. `cloud-pipeline-test`). Defaults to `default` if unset.
- **PKI secrets**: Create `cp-pki-secret`, `cp-jwt-pki-secret`, and `cp-idp-secret` with
  `prerequisites/create-cp-secrets.sh` before `helmfile apply`.

- **`general.namespace`**: Kubernetes namespace (defaults to `default` if unset).

### cp-api-srv database (`apiSrv.db.type`)

`apiSrv.db` holds connection settings (`type`, `host`, `port`, `version`, `db`, `user`, `pass`, plus
`sharedBuffers` / `maxConnections` for internal Postgres). All values are merged into `cp-config-global` as `PSG_*`
keys by the cp-api-srv hook.

| Value      | Behavior                                                                                                                                                       |
|------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `external` | No `cp-api-db` release. Point `db.host` / credentials at a managed DB (e.g. RDS).                                                                              |
| `internal` | Installs `cp-api-db` release first (Postgres on hostPath `/opt/postgresql/data`), then the cp-api-srv init job provisions the app role/database before the API starts. |

Optional in-cluster GitLab Postgres (`cp-gitlab-db`) is deployed by the **cp-git** release when
`git.gitlabDb.enabled` is `true`.

## Values configuration

Fill in `values.yaml` with your deployment settings before running `helmfile apply` (see [Usage](#usage)).

Helmfile also supports optional top-level keys not shown in the template (used by hooks and charts):

```yaml
general:
  namespace: default              # Kubernetes namespace (default: default)
  # Optional — not needed in most deployments. Cloud Pipeline images come from public quay.io, and tool images
  # go through the in-cluster cp-docker-registry; set this only to route those pulls through a private mirror.
  # Set user+password or secret (not both); leave all empty (default) to disable imagePullSecrets entirely.
  # imagePullCredentials:
  #   registry: ""
  #   user: ""
  #   password: ""
  #   secret: ""                   # name of a pre-existing docker-registry Secret
  customDNS:
    entries: []
    # - ip: "203.0.113.5"
    #   host: "external-rds.corp.internal"
```

### `resources`

Core platform identity and admin bootstrap settings (merged into `cp-config-global`).

```yaml
resources:
  config:
    CP_CLOUD_PLATFORM: aws        # aws | azure | gcp
    CP_CLOUD_REGION_ID: ""        # Primary region, e.g. us-east-1
    CP_DEFAULT_ADMIN_NAME: ""
    CP_DEFAULT_ADMIN_EMAIL: ""
```

### `idp`

In-cluster IdP (`cp-idp` release). Set `enabled: false` when using an external IdP.

```yaml
idp:
  enabled: false
  service:
    host:
      external: ""
```

### `apiSrv`

API server deployment, database, primary cloud region, and UI preferences.

```yaml
apiSrv:
  service:
    host:
      external: ""
  highAvailability:
    enabled: false
    replicas: 2
  db:
    type: internal                # internal (bundled Postgres) | external (RDS / managed)
    db: pipeline
    user: pipeline
    pass: ""
  cloudRegion:
    kmsKeyArn: ""                 # arn:aws:kms:<region>:<account>:key/<id>
    kmsKeyId: ""
    sshKeyName: ""
    tempCredentialsRole: ""
    backupDuration: 20
    omicsServiceRole: ""
    omicsEcrUrl: ""
    # corsRules: ""               # S3 CORS policy — see "corsRules" section below
    fileShareMounts: [ ]
    # - mountRoot: "fs-xxx.efs.us-east-1.amazonaws.com"
    #   mountType: "NFS"          # NFS | SMB
    #   mountOptions: ""
  config:
    CP_PREF_UI_PIPELINE_DEPLOYMENT_NAME: ""
    CP_KUBE_EXTERNAL_HOST: ""
    CP_API_SRV_SSO_ENDPOINT_ID: ""
    CP_PREF_STORAGE_SYSTEM_STORAGE_NAME: ""
```

#### `corsRules` — S3 CORS policy

`apiSrv.cloudRegion.corsRules` controls the CORS policy applied to the primary region's S3 bucket on first deploy
(POST) and on every subsequent deploy (PUT). Three forms are accepted:

| Form                       | Example                                       | Behavior                                                                         |
|----------------------------|-----------------------------------------------|----------------------------------------------------------------------------------|
| **Absent / commented out** | `#corsRules: ""`                              | Uses `hooks/post-deploy/assets/storage.cors.policy.json` (default open policy)   |
| **Path to a JSON file**    | `corsRules: "path/to/cors.json"`              | File is read at helmfile render time (relative to the `helm/` directory)         |
| **Inline JSON string**     | `corsRules: '[{"AllowedOrigins":["*"],...}]'` | Value used as-is; shell escape sequences (`\n`, `\"`) are expanded automatically |

The path form is detected when the value does not start with `[` or `{`. Examples:

```yaml
# 1. Default — uses storage.cors.policy.json
corsRules: ""
```

```yaml
# 2. File path (resolved at helmfile render time)
corsRules: "my-cors/production.json"
```

```yaml
# 3. Inline compact JSON
corsRules: '[{"AllowedOrigins":["*"],"AllowedMethods":["GET","PUT","POST","DELETE","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["ETag"]}]'
```
```yaml
# 4. Inline with \n escapes (equivalent to 3, printf '%b' expands them before jq parses)
corsRules: "[{\n\"AllowedOrigins\":[\"*\"],\n\"AllowedMethods\":[\"GET\",\"PUT\",\"POST\",\"DELETE\",\"HEAD\"],\n\"AllowedHeaders\":[\"*\"],\n\"ExposeHeaders\":[\"ETag\"]\n}]"
```

`postDeploy.additionalCloudRegions[].corsRules` accepts the same inline forms. File-path resolution is not
supported for additional regions — the value is passed as-is through the environment variable.

### `dockerRegistry`

```yaml
dockerRegistry:
  enabled: true
  service:
    host:
      external: ""
  config:
    CP_DOCKER_STORAGE_CONTAINER: ""
```

### `edge`

```yaml
edge:
  region: ""                      # AWS region of this edge node
  externalIP: ""                  # Public IP (DNS and run endpoints)
  service:
    host:
      external: ""
```

### `git`

GitLab (`cp-git`). When `enabled: false`, the release and cp-edge dependency on cp-git are skipped.
Includes an optional GitLab Postgres (`cp-gitlab-db`, on by default) and a GitLab Reader sidecar
(`cp-gitlab-reader`, on by default) that provides a git content browsing API.

```yaml
git:
  enabled: true
  patchDNS:
    enabled: true
  service:
    host:
      external: ""
  gitlab:
    internalHttpPort: 443
  image:
    repository: quay.io/lifescience/cloud-pipeline
    tag: git-15-0.17
  config:
    CP_GITLAB_SSO_ENDPOINT_ID: ""
    CP_GITLAB_SSO_TARGET_URL: ""
    CP_GITLAB_SSO_TARGET_URL_TRAIL: ""
    GITLAB_ROOT_PASSWORD: ""
  gitlabDb:
    enabled: true               # Deploy in-cluster GitLab Postgres
  gitlabReader:
    enabled: true               # Deploy GitLab Reader sidecar
```

### `search`

Elasticsearch search stack (`cp-search-srv`, `cp-search-elk`, curator). Requires node labels
`cloud-pipeline/cp-search-srv` and `cloud-pipeline/cp-search-elk`.

```yaml
search:
  enabled: false
  elk:
    elasticsearch:
      enabled: true
  srv:
    mode: default                 # default | nfsEvents | nfsOnly
```

### `billing`

Billing report agent (`cp-billing-srv`). Requires node label `cloud-pipeline/cp-billing-srv=true`.

```yaml
billing:
  enabled: true
```

### `notifier`

Email notifier (`cp-notifier`). Requires node label `cloud-pipeline/cp-notifier=true`.

```yaml
notifier:
  enabled: false
  smtp:
    enabled: false
    server:
      host: ""
      port: ""                    # e.g. 587 (STARTTLS) or 465 (SSL)
    sslOnConnect: false
    startTls: true
    from: ""
    user: ""
    pass: ""
  ui:
    enabled: true
  azure:
    enabled: false
    tenantId: ""
    clientId: ""
    clientSecret: ""
    scopes: "https://graph.microsoft.com/.default"
    sender: ""
    dryRun: false                 # true = log without sending
```

### `monitoring`

Heapster, node logger/reporter, and vm-monitor (`cp-monitoring`).

```yaml
monitoring:
  enabled: true
  heapster:
    enabled: true
    elk:
      dataHostPath: /opt/heapster-elk/data
  nodeLogger:
    enabled: true
  nodeReporter:
    enabled: true
  vmMonitor:
    enabled: true
    logsHostPath: /opt/vm-monitor/logs
```

### `storageLifecycle`

Storage lifecycle service (`cp-storage-lifecycle-service`). Schedules and executes S3 archive/restore
operations. Requires node label `cloud-pipeline/cp-storage-lifecycle-service=true`.

```yaml
storageLifecycle:
  enabled: true
  archive:
    startAt: "23:00"        # Time of day to run the archive job (HH:MM)
  restore:
    startEach: "20"         # Interval in minutes between restore checks
  reportBucketPrefix: "storage-lifecycle-service/tagging-job-reports"
  regions: []
  # Per-region overrides — inline list or path to a JSON file.
  # - awsRegionId: "us-east-1"
  #   slsRoleArn: "arn:aws:iam::<account-id>:role/cp-sls-role"
```

A `configure-storage-lifecycle-regions.sh` cleanup hook runs post-deploy when this service is enabled,
registering each entry in `storageLifecycle.regions` via the Cloud Pipeline API.

### `dav`

WebDAV gateway (`cp-dav`). Provides WebDAV access to Cloud Pipeline data storages. Patches
`cp-config-global` with `CP_DAV_*` keys. Requires node label `cloud-pipeline/cp-dav=true`.

```yaml
dav:
  enabled: true
```

### `shareSrv`

Data sharing service (`cp-share-srv`). Shares Cloud Pipeline storages with external users over SAML SSO.
Requires `idp.enabled: true` or an external IdP configured in cp-api-srv, and
`cp-pki-secret` (with cp-share-srv's TLS pair + p12s) / `cp-share-srv-fed-metadata-secret` must exist before deployment.
Requires node label `cloud-pipeline/cp-share-srv=true`.

```yaml
shareSrv:
  enabled: false
  service:
    host:
      external: ""          # e.g. share.example.com
    port:
      external: "443"
      internal: "31084"
  config: {}
```

### `runPolicyManager`

Run policy manager (`cp-run-policy-manager`). Evaluates and enforces run lifecycle policies (pause,
terminate) on a configurable polling interval. Requires node label
`cloud-pipeline/cp-run-policy-manager=true`.

```yaml
runPolicyManager:
  enabled: false
  pollPeriodSec: "5"        # Interval between run policy evaluation cycles in seconds
```

### `postDeploy`

Post-deploy cleanup hooks run, in list order, after all releases sync. Set `postDeploy.enabled: true` to
activate them; `false` is safe for `helmfile template`/`diff` without a live cluster.

Each entry under `postDeploy.hooks` is `{name, enable, data}`: `name` is looked up in the
`hooks/post-deploy/hooks.yaml` registry to find the script to run (or set `script` directly on the entry to
bypass the registry), `enable` toggles that one hook, and `data` keys are passed to the script as env vars
(see each key's own comment below for whether it takes a path or a value directly).

```yaml
postDeploy:
  enabled: false                  # true = run post-deploy hooks (register tools, prefs, etc.)

  hooks:
    - name: WaitForApi
      enable: true

    - name: RegisterDockerTools
      enable: true
      data:
        CP_MANIFEST_DIR: "./hooks/post-deploy/assets/dockers-manifest"
        CP_TOOLS_JSON:                      # Tools to push/register; empty/omitted = push everything in the manifest
          - "library/rockylinux:latest"
          - "library/nextflow:latest"

    - name: ApplyPreferences
      enable: true
      data:
        # Path to a custom preferences JSON file or directory; merged after defaults, wins on conflict.
        # Leave empty to use only the built-in defaults from hooks/post-deploy/assets/preferences/.
        CP_SYSTEM_PREFERENCE_CONFIG: ""

    - name: ApplyClusterNetworksConfig
      enable: true
      data:
        # Explicit config — path to a JSON file, or set the values directly inline. You provide the
        # concrete AMI IDs / security group IDs yourself; nothing is pulled from preferences.
        CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC: #"/path/to/file/cluster-networks-config.json"
        # tags: {}                 # optional; instance tags applied to every launched worker
        # regions:
        #   - name: ""              # AWS region ID; omit or leave empty to use CP_CLOUD_REGION_ID
        #     default: true         # exactly one region must have default=true (omit when there's only one region)
        #     networks: {}          # Map of subnet-id → network-name, e.g. { "subnet-xxx": "my-net" }
        #     amis:
        #       - ami: "ami-..."      # Required — e.g. the AMI built from packer/aws/worker_node
        #         platform: linux     # linux (default) | windows
        #         instance_mask: "*"  # Instance type glob, e.g. "p*" for GPU
        #         init_script: ""
        #     security_group_ids: []
        #     proxies: [{name: "dns_proxy_post", path: "10.96.0.10"}]
        #     swap: [{name: "swap_ratio", path: "0.01"}]

        # Alternative to CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC above: leave it unset. The hook then fills in
        # AMI IDs / security groups from already-registered CP_PREF_CLUSTER_INSTANCE_IMAGE* /
        # CP_PREF_CLUSTER_INSTANCE_SECURITY_GROUPS preferences, using one of these template files:
        #   - CP_CLOUD_NETWORK_CONFIG_FILE below, if set
        #   - otherwise the bundled template at hooks/post-deploy/assets/cluster.networks.config.json
        # CP_CLOUD_NETWORK_CONFIG_FILE: "/path/to/cluster.networks.config.template.json"
        #
        # CP_PREF_CLUSTER_INSTANCE_IMAGE* must already be registered — if it isn't, the AMI is left
        # unresolved and the hook FAILS (aborting the post-deploy run) rather than applying a
        # placeholder AMI. (Only the AMI is checked this way — an empty security_group_ids list is
        # not rejected and will silently register as "no security group".)

    - name: RegisterAdditionalCloudRegions
      enable: true
      data:
        # Inline list, or path to a JSON file containing the same list.
        CP_POST_DEPLOY_ADDITIONAL_CLOUD_REGIONS_SPEC: []
        # - regionId: "us-east-2"        # required
        #   kmsKeyArn: ""                 # Full ARN: arn:aws:kms:<region>:<account>:key/<id>
        #   kmsKeyId: ""
        #   sshKeyName: ""
        #   tempCredentialsRole: ""
        #   backupDuration: 20
        #   omicsServiceRole: ""
        #   omicsEcrUrl: ""
        #   corsRules: ""
        #   fileShareMounts: []
        # or: CP_POST_DEPLOY_ADDITIONAL_CLOUD_REGIONS_SPEC: "./path/to/additional-regions.json"

    - name: StorageLifecycleRegionsConfiguration
      enable: true
      data:
        CP_POST_DEPLOY_SLS_REPORT_BUCKET_PREFIX: "storage-lifecycle-service/tagging-job-reports"
        # Per-region overrides. Inline list or path to a JSON file.
        # Each entry: awsRegionId (required), slsRoleArn or full slsProperties object.
        CP_POST_DEPLOY_SLS_REGIONS_SPEC: []
        # - awsRegionId: "us-east-1"          # use slsRoleArn to override the S3 Batch Operations role
        #   slsRoleArn: "arn:aws:iam::<account-id>:role/cp-sls-role"
        # - awsRegionId: "eu-west-1"          # use slsProperties to set all properties explicitly
        #   slsProperties:
        #     properties:
        #       batch_operation_job_aws_account_id: "<account-id>"
        #       batch_operation_job_role_arn: "arn:aws:iam::<account-id>:role/cp-sls-role"
        #       batch_operation_job_report_bucket: "my-bucket"
        #       batch_operation_job_report_bucket_prefix: "storage-lifecycle-service/tagging-job-reports"
        #       batch_operation_job_poll_status_retry_count: "30"
        #       batch_operation_job_poll_status_sleep_sec: "5"
        #       storage_skip_archiving_tag: "disable_storage_lifecycle"
        # or: CP_POST_DEPLOY_SLS_REGIONS_SPEC: "./path/to/sls-regions.json"

    - name: RegisterDemoPipelines
      enable: true

    - name: RegisterEmailTemplates
      enable: true
      data:
        CP_POST_DEPLOY_EMAIL_NOTIFICATIONS_SPEC:
          # If non-empty, only these types are enabled; all others get enabled=false.
          enableOnly: []
          # enableOnly:
          #   - IDLE_RUN
          #   - LONG_RUNNING

    - name: RestartApiServer
      enable: true
```

| Hook name                              | Script                                    | Purpose                                                                                                         |
|-----------------------------------------|-------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `WaitForApi`                            | `wait-for-api.sh`                          | Polls until the Cloud Pipeline REST API is up                                                                   |
| `RegisterDockerTools`                   | `register-docker-tools.sh`                 | Pushes/registers Docker images from `hooks/post-deploy/assets/dockers-manifest/`, filtered by `CP_TOOLS_JSON`   |
| `ApplyPreferences`                      | `apply-preferences.sh`                     | Uploads system preferences, defaults plus optional `CP_SYSTEM_PREFERENCE_CONFIG` override                       |
| `ApplyClusterNetworksConfig`             | `apply-cluster-networks-config.sh`         | Posts `CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC` as the `cluster.networks.config` API preference                    |
| `RegisterAdditionalCloudRegions`        | `register-additional-cloud-regions.sh`     | Registers extra AWS regions from `CP_POST_DEPLOY_ADDITIONAL_CLOUD_REGIONS_SPEC`                                 |
| `StorageLifecycleRegionsConfiguration`  | `configure-storage-lifecycle-regions.sh`   | Registers storage-lifecycle region configs via the API (relevant when `storageLifecycle.enabled`)               |
| `RegisterDemoPipelines`                 | `register-demo-pipelines.sh`               | Registers demo pipelines from `hooks/post-deploy/assets/pipe-demo/` (only when `git.enabled: true`)             |
| `RegisterEmailTemplates`                | `register-email-templates.sh`              | Registers email templates from `hooks/post-deploy/assets/email-templates/`, filtered by `enableOnly`           |
| `RestartApiServer`                      | `restart-cp-api-srv.sh`                    | Restarts cp-api-srv so applied preferences take effect                                                          |

**Available notification types (21):**

|                           |                                   |                                        |
|---------------------------|-----------------------------------|----------------------------------------|
| `BILLING_QUOTA_EXCEEDING` | `DATASTORAGE_LIFECYCLE_ACTION`    | `DATASTORAGE_LIFECYCLE_RESTORE_ACTION` |
| `FULL_NODE_POOL`          | `HIGH_CONSUMED_NETWORK_BANDWIDTH` | `HIGH_CONSUMED_RESOURCES`              |
| `IDLE_RUN`                | `IDLE_RUN_PAUSED`                 | `IDLE_RUN_STOPPED`                     |
| `INACTIVE_USERS`          | `LDAP_BLOCKED_POSTPONED_USERS`    | `LDAP_BLOCKED_USERS`                   |
| `LONG_INIT`               | `LONG_PAUSED`                     | `LONG_PAUSED_STOPPED`                  |
| `LONG_RUNNING`            | `LONG_STATUS`                     | `NEW_ISSUE`                            |
| `NEW_ISSUE_COMMENT`       | `PIPELINE_RUN_STATUS`             | `STORAGE_QUOTA_EXCEEDING`              |

## Usage

**On the EC2 instance** navigate to the deployment directory:

```bash
cd /var/lib/cloud-pipeline/deploy/helm
```

```bash
# Required for helmfile diff plugin compatibility
export HELM_DIFF_IGNORE_UNKNOWN_FLAGS="true"

# Template all releases (no cluster needed)
helmfile template

# Preview changes
helmfile diff

# Deploy in order
helmfile apply

# Deploy a single release
helmfile apply --selector name=cp-api-srv
```

## References

- Prerequisites: `prerequisites/README.md` (certificate generation and secret creation)
- Chart prerequisites: `cloud-pipeline/prerequisites.md` (manual secret creation details)
