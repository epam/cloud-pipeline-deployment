###################################################################
#                          Naming / tagging
###################################################################

variable "deployment_name" {
  type        = string
  description = "Name of the deployment. Used as a prefix for the names of created resources."
}

variable "deployment_env" {
  type        = string
  description = "Environment name (e.g. dev, staging, prod). Used as a prefix for the names of created resources."
}

variable "cp_deployment_id" {
  type        = string
  default     = null
  description = "Cloud Pipeline deployment identifier (CP_DEPLOYMENT_ID). Defaults to '<deployment_name>-<deployment_env>' when unset."
}

variable "additional_tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags applied to every resource created by this module."
}

###################################################################
#                          Networking
###################################################################

variable "vpc_id" {
  type        = string
  description = "ID of the VPC to deploy Cloud Pipeline into."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs used for the master node, application nodes and shared filesystem mount targets. The master node and EFS mount targets are placed starting from the first subnet; application nodes are spread round-robin across all of them."

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one subnet id must be specified."
  }
}

variable "external_access_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Additional, pre-existing security group IDs to attach to every node (e.g. to allow inbound access from a corporate network or a load balancer)."
}

variable "security_group_ids" {
  type        = list(string)
  default     = []
  description = "IDs of existing security groups to attach to every node and the shared filesystem mount targets, instead of having the module create one (e.g. one for intra-cluster traffic plus another for corporate VPN access). Leave empty to have the module create its own -- internal_access_cidr_blocks and kube_api_access_cidr_blocks only apply to that module-created security group, so they're ignored when this is set."
}

variable "internal_access_cidr_blocks" {
  type        = list(string)
  default     = null
  description = "CIDR blocks allowed all-protocols ingress to the internal security group, in addition to the security group's own members. By default (left unset / null) the group is closed to anything outside itself: a single self-referencing all-all rule covers node-to-node and node-to-filesystem traffic, with no VPC-wide or internet access. Set this to open all-all access to additional CIDRs (e.g. the whole VPC, for multi-subnet layouts where not every subnet's traffic is guaranteed to carry this security group). Ignored when security_group_ids is set."
}

variable "kube_api_access_cidr_blocks" {
  type        = list(string)
  default     = []
  description = "CIDR blocks allowed ingress to the Kubernetes API server port (6443) only. Use this when nodes outside the internal security group's membership (e.g. Cloud Pipeline run/worker nodes) need to reach kube-apiserver. Empty by default -- no additional access is opened. Ignored when security_group_ids is set."
}

variable "iam_role_permissions_boundary_arn" {
  type        = string
  default     = null
  description = "ARN of an account-specific IAM permissions boundary to apply to every IAM role created by this module."
}

variable "enable_spot_support" {
  type        = bool
  default     = false
  description = "Grant the AWSServiceRoleForEC2Spot service-linked role access to the KMS key, so EC2 Spot can be used for Cloud Pipeline worker nodes. The service-linked role must already exist in the account."
}

variable "worker_node_amis" {
  type = list(object({
    ami           = string
    platform      = optional(string, "linux")
    instance_mask = optional(string, "*")
    init_script   = optional(string, "")
  }))
  default     = []
  description = "AMIs Cloud Pipeline launches dynamically to run pipeline jobs (built via packer/aws/worker_node, one entry per platform/instance family -- see CLAUDE.md). Populates CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC in cp_values_yaml, along with var.subnet_ids (as the region's networks, named by availability zone) and var.worker_node_security_group_ids. Left empty by default, which leaves CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC as {} -- pipeline runs can't launch until this is set, by variable or by editing values.yaml directly."
}

variable "worker_node_security_group_ids" {
  type        = list(string)
  default     = null
  description = "Security groups attached to dynamically launched worker/run nodes, as part of CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC. Defaults to the cluster's own internal security group when unset. Only used when worker_node_amis is non-empty."
}

###################################################################
#                          EC2 nodes
###################################################################

variable "ami_id" {
  type        = string
  description = "AMI ID to launch the master and application nodes from (built via packer/aws/application_node)."
}

variable "key_name" {
  type        = string
  default     = null
  description = "Name of an existing EC2 key pair to use for SSH access. When unset, the module generates a new RSA key pair."
}

variable "security_patch_schedule" {
  type        = string
  default     = null
  description = "systemd OnCalendar expression (e.g. \"Sun *-*-* 03:00:00\") to apply to the dnf-automatic security-patch timer on every already-running node, via SSM Run Command, in this apply -- without rebuilding the AMI or replacing instances (see packer/common/scripts/install_security_patches.sh for the AMI-build-time default). Left unset by default, which skips this entirely."
}

variable "master_node_instance_type" {
  type        = string
  default     = "m5.xlarge"
  description = "EC2 instance type for the master node."
}

variable "master_node_volume_size" {
  type        = number
  default     = 100
  description = "Root EBS volume size (GiB) for the master node."
}

variable "master_node_labels" {
  type        = string
  default     = null
  description = "Comma-separated key=value node labels applied to the master after kubeadm init (CP_MASTER_NODE_LABELS). When unset, the AMI's default full service label set is applied."
}

variable "application_node_instance_type" {
  type        = string
  default     = "m5.2xlarge"
  description = "EC2 instance type for application nodes."
}

variable "application_node_count" {
  type        = number
  default     = 0
  description = "Number of application nodes to create."

  validation {
    condition     = var.application_node_count >= 0
    error_message = "application_node_count must be >= 0."
  }
}

variable "application_node_volume_size" {
  type        = number
  default     = 100
  description = "Root EBS volume size (GiB) for each application node."
}

variable "application_node_labels" {
  type        = string
  default     = "cloud-pipeline/cp-api-srv=true"
  description = "Comma-separated key=value node labels registered by application nodes at kubelet join time (CP_APPLICATION_NODE_LABELS). cloud-pipeline/application-node=true is always added by the AMI and cannot be overridden."
}

###################################################################
#                   Shared filesystem (EFS or FSx Lustre)
###################################################################

variable "storage_type" {
  type        = string
  default     = "efs"
  description = "Shared filesystem backend mounted at /opt on every node: 'efs' or 'fsx'."

  validation {
    condition     = contains(["efs", "fsx"], var.storage_type)
    error_message = "storage_type must be either 'efs' or 'fsx'."
  }
}

variable "efs_performance_mode" {
  type        = string
  default     = "generalPurpose"
  description = "EFS performance mode: 'generalPurpose' or 'maxIO'."
}

variable "efs_throughput_mode" {
  type        = string
  default     = "elastic"
  description = "EFS throughput mode: 'bursting', 'provisioned' or 'elastic'."
}

variable "efs_provisioned_throughput_in_mibps" {
  type        = number
  default     = null
  description = "EFS provisioned throughput in MiB/s. Only used when efs_throughput_mode = 'provisioned'."
}

variable "enable_efs_backup_policy" {
  type        = bool
  default     = true
  description = "Enable AWS Backup's automatic daily backups for the EFS filesystem."
}

variable "fsx_storage_capacity" {
  type        = number
  default     = 1200
  description = "FSx for Lustre storage capacity, in GiB."
}

variable "fsx_deployment_type" {
  type        = string
  default     = "PERSISTENT_1"
  description = "FSx for Lustre deployment type: one of SCRATCH_1, SCRATCH_2, PERSISTENT_1, PERSISTENT_2."
}

variable "fsx_per_unit_storage_throughput" {
  type        = number
  default     = 200
  description = "FSx for Lustre throughput per 1 TiB of storage, in MB/s/TiB. Only applies to PERSISTENT_1 and PERSISTENT_2 deployment types."
}

###################################################################
#                          S3 buckets
###################################################################

variable "create_s3_buckets" {
  type        = bool
  default     = true
  description = "Create the Docker registry and system storage S3 buckets. Set to false to supply pre-existing buckets via docker_registry_bucket_name / system_bucket_name instead."
}

variable "docker_registry_bucket_name" {
  type        = string
  default     = null
  description = "Name of the S3 bucket used by the internal Docker registry. Defaults to '<deployment_name>-<deployment_env>-docker' when create_s3_buckets = true; required when create_s3_buckets = false."
}

variable "system_bucket_name" {
  type        = string
  default     = null
  description = "Name of the S3 bucket used for Cloud Pipeline system storage (logs, backups, FSBrowser transfers). Defaults to '<deployment_name>-<deployment_env>-system' when create_s3_buckets = true; required when create_s3_buckets = false."
}

variable "s3_force_destroy" {
  type        = bool
  default     = false
  description = "Allow `terraform destroy` to delete created S3 buckets even when they still contain objects. Leave false in production."
}

variable "s3_versioning_enabled" {
  type        = bool
  default     = false
  description = "Enable versioning on created S3 buckets."
}

###################################################################
#                Cloud Pipeline service hostnames
###################################################################

variable "api_srv_host" {
  type        = string
  description = "External DNS hostname for the Cloud Pipeline API/UI (apiSrv.service.host.external), e.g. 'cp.example.com'."
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
  description = "Public or routable IP that the above hostnames resolve to (edge.externalIP). Defaults to the master node's private IP, matching a VPN/Direct-Connect-only deployment with no load balancer or Elastic IP."
}

variable "git_host" {
  type        = string
  description = "External DNS hostname for the bundled GitLab instance (git.service.host.external)."
}

variable "idp_host" {
  type        = string
  default     = null
  description = "External DNS hostname for the in-cluster SAML IdP (idp.service.host.external). Leave unset to disable the in-cluster IdP (idp.enabled = false) and use an external SAML IdP instead."
}

variable "share_srv_host" {
  type        = string
  default     = null
  description = "External DNS hostname for the data-sharing service (shareSrv.service.host.external). Leave unset to disable cp-share-srv."
}

###################################################################
#                Cloud Pipeline credentials
###################################################################

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
  description = "Default Cloud Pipeline administrator password (CP_DEFAULT_ADMIN_PASS). When unset, the module generates a random one and returns it via the sensitive admin_password output."
}

variable "db_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password for the internal Postgres 'pipeline' database user (apiSrv.db.pass). When unset, the module generates a random one and returns it via the sensitive db_password output."
}

variable "gitlab_root_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password for the GitLab 'root' user (git.config.GITLAB_ROOT_PASSWORD). When unset, the module generates a random one and returns it via the sensitive gitlab_root_password output."
}

###################################################################
#                Cloud Pipeline optional services
###################################################################
# Everything below is enabled by default so that `terraform apply` produces
# a cp-values.yaml that installs the full Cloud Pipeline service set, matching
# the release order documented in ../../CLAUDE.md. Flip any of these to false
# to skip that service.

variable "enable_search" {
  type        = bool
  default     = true
  description = "Enable the search stack (cp-search-srv, cp-search-elk)."
}

variable "enable_billing" {
  type        = bool
  default     = true
  description = "Enable the billing report agent (cp-billing-srv)."
}

variable "enable_notifier" {
  type        = bool
  default     = true
  description = "Enable the email/Azure-Graph notifier (cp-notifier). In-app UI notifications only by default -- set SMTP/Azure details directly in helm/values.yaml to also send email."
}

variable "enable_monitoring" {
  type        = bool
  default     = true
  description = "Enable the monitoring stack (heapster, node-logger, node-reporter, vm-monitor)."
}

variable "enable_storage_lifecycle" {
  type        = bool
  default     = true
  description = "Enable the storage lifecycle service (cp-storage-lifecycle-service)."
}

variable "enable_dav" {
  type        = bool
  default     = true
  description = "Enable the WebDAV gateway (cp-dav)."
}

variable "enable_run_policy_manager" {
  type        = bool
  default     = true
  description = "Enable the run policy manager (cp-run-policy-manager)."
}

variable "enable_post_deploy" {
  type        = bool
  default     = true
  description = "Run the post-deploy hooks (register Docker tools, apply preferences, register demo pipelines, etc.) after helmfile apply. Requires the Cloud Pipeline API to be reachable at apply time -- set to false for `helmfile template`/`diff` without a live cluster."
}
