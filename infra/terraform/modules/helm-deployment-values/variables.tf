variable "aws_region" {
  type        = string
  description = "AWS region (CP_CLOUD_REGION_ID, edge.region)."
}

variable "deployment_id" {
  type        = string
  description = "Deployment identifier (CP_DEPLOYMENT_ID, apiSrv.config.CP_PREF_UI_PIPELINE_DEPLOYMENT_NAME)."
}

variable "master_node_private_ip" {
  type        = string
  description = "Master node private IP (resources.config.CP_KUBE_EXTERNAL_HOST)."
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN (apiSrv.cloudRegion.kmsKeyArn)."
}

variable "ssh_key_name" {
  type        = string
  description = "EC2 key pair name (apiSrv.cloudRegion.sshKeyName)."
}

variable "s3_via_sts_role_arn" {
  type        = string
  description = "IAM role ARN assumed for S3-via-STS access (apiSrv.cloudRegion.tempCredentialsRole)."
}

variable "docker_registry_bucket_name" {
  type        = string
  description = "S3 bucket backing the Docker registry (dockerRegistry.config.CP_DOCKER_STORAGE_CONTAINER)."
}

variable "system_bucket_name" {
  type        = string
  description = "S3 bucket for Cloud Pipeline system storage (apiSrv.config.CP_PREF_STORAGE_SYSTEM_STORAGE_NAME)."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs of the cluster, used to name CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC's regions by availability zone."
}

variable "security_group_ids" {
  type        = list(string)
  description = "Security group IDs shared by every cluster node, included in CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC's security_group_ids alongside worker_node_security_group_ids."
}

variable "api_srv_host" {
  type        = string
  description = "External DNS hostname for the Cloud Pipeline API/UI (apiSrv.service.host.external)."
}

variable "docker_registry_host" {
  type        = string
  description = "External DNS hostname for the internal Docker registry (dockerRegistry.service.host.external)."
}

variable "edge_host" {
  type        = string
  description = "External DNS hostname for the edge proxy (edge.service.host.external)."
}

variable "edge_external_ip" {
  type        = string
  default     = null
  description = "Public or routable IP that the above hostnames resolve to (edge.externalIP). Defaults to master_node_private_ip, matching a VPN/Direct-Connect-only deployment with no load balancer or Elastic IP."
}

variable "git_host" {
  type        = string
  description = "External DNS hostname for the bundled GitLab instance (git.service.host.external)."
}

variable "idp_host" {
  type        = string
  default     = null
  description = "External DNS hostname for the in-cluster SAML IdP (idp.service.host.external, idp.enabled). Leave unset to disable the in-cluster IdP and use an external SAML IdP instead."
}

variable "share_srv_host" {
  type        = string
  default     = null
  description = "External DNS hostname for the data-sharing service (shareSrv.service.host.external, shareSrv.enabled). Leave unset to disable cp-share-srv."
}

variable "admin_name" {
  type        = string
  default     = "pipe_admin"
  description = "Default Cloud Pipeline administrator username (CP_DEFAULT_ADMIN_NAME)."
}

variable "admin_email" {
  type        = string
  default     = ""
  description = "Default Cloud Pipeline administrator email (CP_DEFAULT_ADMIN_EMAIL)."
}

variable "admin_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Default Cloud Pipeline administrator password (CP_DEFAULT_ADMIN_PASS). When unset, this module generates a random one and returns it via the sensitive admin_password output."
}

variable "db_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password for the internal Postgres 'pipeline' database user (apiSrv.db.pass). When unset, this module generates a random one and returns it via the sensitive db_password output."
}

variable "gitlab_root_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password for the GitLab 'root' user (git.config.GITLAB_ROOT_PASSWORD). When unset, this module generates a random one and returns it via the sensitive gitlab_root_password output."
}

variable "docker_tools" {
  type        = list(string)
  default     = ["library/rockylinux:latest", "library/nextflow:latest"]
  description = "<group>/<tool>:<tag> entries to register via the RegisterDockerTools post-deploy hook (CP_TOOLS_JSON). Each entry must exist as a directory under helm/hooks/post-deploy/assets/dockers-manifest/ with a matching source in manifest.txt -- an entry with no manifest directory (e.g. anything under ngs/) is silently never registered, it isn't an error here or at deploy time."
}

variable "worker_node_amis" {
  type = list(object({
    ami           = string
    platform      = optional(string, "linux")
    instance_mask = optional(string, "*")
    init_script   = optional(string, "")
  }))
  default     = []
  description = "AMIs Cloud Pipeline launches dynamically to run pipeline jobs (built via packer/aws/worker_node, one entry per platform/instance family -- see CLAUDE.md). Populates CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC, along with subnet_ids (as the region's networks, named by availability zone) and worker_node_security_group_ids. Left empty by default, which leaves CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC as {} -- pipeline runs can't launch until this is set, by variable or by editing values.yaml directly."
}

variable "worker_node_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Additional security groups attached to dynamically launched worker/run nodes, as part of CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC, on top of security_group_ids (always included). Only used when worker_node_amis is non-empty."
}

variable "enable_search" {
  type        = bool
  default     = true
  description = "Enable the search stack (search.enabled)."
}

variable "enable_billing" {
  type        = bool
  default     = true
  description = "Enable the billing report agent (billing.enabled)."
}

variable "enable_notifier" {
  type        = bool
  default     = true
  description = "Enable the email/Azure-Graph notifier (notifier.enabled)."
}

variable "enable_monitoring" {
  type        = bool
  default     = true
  description = "Enable the monitoring stack (monitoring.enabled)."
}

variable "enable_storage_lifecycle" {
  type        = bool
  default     = true
  description = "Enable the storage lifecycle service (storageLifecycle.enabled)."
}

variable "enable_dav" {
  type        = bool
  default     = true
  description = "Enable the WebDAV gateway (dav.enabled)."
}

variable "enable_run_policy_manager" {
  type        = bool
  default     = true
  description = "Enable the run policy manager (runPolicyManager.enabled)."
}

variable "enable_post_deploy" {
  type        = bool
  default     = true
  description = "Run the post-deploy hooks after helmfile apply (postDeploy.enabled)."
}
