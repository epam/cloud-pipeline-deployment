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

variable "deployment_id" {
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

variable "enable_ssm_run_commands" {
  type        = bool
  default     = true
  description = "Master switch for all SSM Run Command automation (security_patch_schedule, pre_reboot_scripts, custom_pre_reboot_scripts) -- each of these shells out to the \"aws\" CLI via a local-exec provisioner during terraform apply. Set to false when that CLI isn't installed/authenticated wherever terraform apply runs, or you simply don't want this automation: every other resource (EC2, EFS/FSx, IAM, S3, etc.) is still created normally -- you'll just need to manage the dnf-automatic schedule and pre-reboot script symlinks another way (e.g. via EC2 user data, or manually over SSH/SSM)."
}

variable "security_patch_schedule" {
  type        = string
  default     = null
  description = "systemd OnCalendar expression (e.g. \"Sun *-*-* 03:00:00\") to apply to the dnf-automatic security-patch timer on every already-running node, via SSM Run Command, in this apply -- without rebuilding the AMI or replacing instances (see packer/common/scripts/install_security_patches.sh for the AMI-build-time default). Left unset by default, which skips this entirely. Also skipped when var.enable_ssm_run_commands is false."
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

variable "pre_reboot_scripts" {
  type = map(map(bool))
  default = {
    master = {
      grace_shutdown_api_db = true
      grace_shutdown_git_db = true
    }
    application = {
      grace_shutdown_api_db = false
      grace_shutdown_git_db = false
    }
  }
  description = "Per-role map of which pre-reboot grace-shutdown scripts run on a node before it reboots. Keys are script names under packer/common/scripts/reboot/pre_reboot_scripts/ (without the .sh extension); true symlinks <key>.sh into /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/<role>/ on every already-running node of that role, false removes the symlink if present. Applied via SSM Run Command -- no AMI rebuild or instance replace needed."
}

variable "custom_pre_reboot_scripts" {
  type = map(list(string))
  default = {
    master      = []
    application = []
  }
  description = "Additional, user-supplied pre-reboot scripts to run on nodes of each role, on top of the built-in ones in pre_reboot_scripts. Each entry is a local file path read at terraform apply time; because it's read with file() from inside this module, pass an absolute path or one built from path.root (e.g. $${path.root}/scripts/my-hook.sh) in the caller, not a bare relative path -- that is only resolved relative to this module's own directory. Each file is copied onto every already-running node of that role as /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/<basename of the path>, made executable, and symlinked into pre_reboot_scripts/<role>/ so reboot.sh picks it up. Two paths with the same basename collide -- use distinct filenames. Applied via SSM Run Command -- no AMI rebuild or instance replace needed."
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

