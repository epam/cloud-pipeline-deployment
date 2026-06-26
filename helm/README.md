# Helmfile layout for Cloud Pipeline

This directory uses [Helmfile](https://github.com/helmfile/helmfile) to deploy
Cloud Pipeline as **eleven ordered releases** with explicit dependencies.

## Release order and dependencies

| Order | Release name           | Installed condition            | Depends on                                                   |
|-------|------------------------|--------------------------------|--------------------------------------------------------------|
| 1     | **cp-resources**       | Always                         | —                                                            |
| 2     | **cp-idp**             | `idp.enabled: true`            | cp-resources                                                 |
| 3     | **cp-api-db**          | `apiSrv.db.type: internal`     | cp-resources                                                 |
| 4     | **cp-api-srv**         | Always                         | cp-resources, cp-idp (+ cp-api-db if internal DB)            |
| 5     | **cp-monitoring**      | `monitoring.enabled: true`     | cp-resources, cp-api-srv                                     |
| 5     | **cp-docker-registry** | `dockerRegistry.enabled: true` | cp-api-srv                                                   |
| 5     | **cp-search**          | `search.enabled: true`         | cp-resources, cp-api-srv                                     |
| 5     | **cp-billing-srv**     | `billing.enabled: true`        | cp-resources, cp-api-srv, cp-search                          |
| 5     | **cp-git**             | `git.enabled: true`            | cp-resources, cp-idp, cp-api-srv                             |
| 5     | **cp-notifier**        | `notifier.enabled: true`       | cp-resources, cp-api-srv                                     |
| 6     | **cp-edge**            | Always                         | cp-resources, cp-idp, cp-api-srv, cp-docker-registry, cp-git |

Releases 5 in the table are independent of each other and run in parallel once cp-api-srv is ready.

## Secrets

| Secret                   | When needed                 | Source                                                                                                                                                                                                                      |
|--------------------------|-----------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `cp-pki-secret`          | Always                      | `prerequisites/generate-cp-pki-certs.sh` + `prerequisites/create-cp-secrets.sh` (see `prerequisites/README.md`)                                                                                                             |
| `cp-jwt-pki-secret`      | Always                      | `prerequisites/generate-cp-jwt-pki-certs.sh` + `prerequisites/create-cp-secrets.sh` (see `prerequisites/README.md`)                                                                                                         |
| `cp-fed-metadata-secret` | Always (API expects volume) | **`idp.enabled: true`:** seeded empty by cp-resources, patched by cp-api-srv hook from IdP `/metadata`. **`idp.enabled: false`:** create manually from IdP metadata XML (see `cloud-pipeline/readme.md`) before cp-api-srv. |
| `cp-idp-secret`          | Always (API expects volume) | **`idp.enabled: true`:** created by cp-idp chart; cert hook fills keys. **`idp.enabled: false`:** create manually (see `cloud-pipeline/readme.md`).                                                                         |

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
| `internal` | Installs `cp-api-db` release first (Postgres on hostPath `/opt/postgresql/data`), then cp-api-srv init job provisions the app role/database before API starts. |

Optional in-cluster GitLab Postgres (`cp-gitlab-db`) is deployed by the **cp-git** release when
`git.gitlabDb.enabled` is `true`.

## Values configuration

Fill in `values.yaml` with your deployment settings before running `helmfile apply` (see [Usage](#usage)).

Helmfile also supports optional top-level keys not shown in the template (used by hooks and charts):

```yaml
general:
  namespace: default              # Kubernetes namespace (default: default)
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

| Form                       | Example                                       | Behaviour                                                                        |
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
supported for additional regions — the value is passed as-is through the env variable.

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

### `postDeploy`

Cleanup hooks run after all releases are deployed.

```yaml
postDeploy:
  additionalCloudRegions: [ ]
  # - regionId: "us-east-2"
  #   kmsKeyArn: ""
  #   kmsKeyId: ""
  #   sshKeyName: ""
  #   tempCredentialsRole: ""
  #   backupDuration: 20
  #   omicsServiceRole: ""
  #   omicsEcrUrl: ""
  #   corsRules: ""               # inline JSON or \n-escaped string; absent = storage.cors.policy.json default
  #   fileShareMounts: []

  systemPreferenceConfig: ""      # Path to custom preferences JSON file or directory
  dockers:
    - "library/rockylinux:latest"
    - "library/nextflow:latest"

  clusterNetworksConfig: { }       # Worker node pool definition (API preference cluster.networks.config)
  # tags: {}
  # regions:
  #   - name: ""
  #     networks: {}
  #     amis:
  #       - ami: "ami-..."
  #         platform: linux         # linux | windows
  #         instance_mask: "*"
  #     securityGroupIds: []
  #     proxies: [{name: "dns_proxy_post", path: "10.96.0.10"}]
  #     swap: [{name: "swap_ratio", path: "0.01"}]

  emailNotifications:
    enabled: true                 # false = skip register-email-templates.sh hook
    enableOnly: [ ]                # If non-empty, only these types are enabled; all others get enabled=false
```

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
- Chart readme: `cloud-pipeline/readme.md` (manual secret creation details)
