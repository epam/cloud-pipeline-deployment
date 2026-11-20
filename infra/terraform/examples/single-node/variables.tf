variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
}

variable "deployment_name" {
  type        = string
  description = "Name of the deployment. Used as a prefix for the names of created resources."
}

variable "deployment_env" {
  type        = string
  description = "Environment name (e.g. dev, staging, prod)."
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC to deploy Cloud Pipeline into."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for the master node, application nodes and shared filesystem mount targets."
}

variable "external_access_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Additional, pre-existing security group IDs to attach to every node (master and application), on top of the module's own internal-access security group (e.g. to allow inbound access from a corporate network or a load balancer)."
}

variable "ami_id" {
  type        = string
  description = "AMI ID built via packer/aws/application_node."
}

variable "key_name" {
  type        = string
  default     = null
  description = "Name of an existing EC2 key pair. When unset, the module generates one and returns the private key as a sensitive output."
}

variable "master_node_instance_type" {
  type    = string
  default = "m5.xlarge"
}

variable "application_node_instance_type" {
  type    = string
  default = "m5.2xlarge"
}

variable "application_node_count" {
  type    = number
  default = 0
}

variable "storage_type" {
  type        = string
  default     = "efs"
  description = "Shared filesystem backend: 'efs' or 'fsx'."
}

variable "api_srv_host" {
  type        = string
  description = "External DNS hostname for the Cloud Pipeline API/UI."
}

variable "docker_registry_host" {
  type        = string
  description = "External DNS hostname for the internal Docker registry."
}

variable "edge_host" {
  type        = string
  description = "External DNS hostname for the edge proxy."
}

variable "git_host" {
  type        = string
  description = "External DNS hostname for the bundled GitLab instance."
}

variable "idp_host" {
  type        = string
  default     = null
  description = "External DNS hostname for the in-cluster SAML IdP. Leave unset to disable it."
}

variable "share_srv_host" {
  type        = string
  default     = null
  description = "External DNS hostname for the data-sharing service. Leave unset to disable it."
}

variable "admin_email" {
  type        = string
  default     = ""
  description = "Default Cloud Pipeline administrator email."
}

variable "admin_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Default Cloud Pipeline administrator password. When unset, the module generates a random one and returns it via the sensitive admin_password output."
}

variable "docker_tools" {
  type        = list(string)
  default     = ["library/rockylinux:latest", "library/nextflow:latest"]
  description = "<group>/<tool>:<tag> entries to register via the RegisterDockerTools post-deploy hook."
}

variable "worker_node_amis" {
  type = list(object({
    ami           = string
    platform      = optional(string, "linux")
    instance_mask = optional(string, "*")
    init_script   = optional(string, "")
  }))
  default     = []
  description = "AMIs built via packer/aws/worker_node (one entry per platform/instance family, e.g. CPU and GPU). Left empty, pipeline runs can't launch until this is set, here or by hand in values.yaml."
}

variable "worker_node_security_group_ids" {
  type        = list(string)
  default     = null
  description = "Security groups attached to dynamically launched worker/run nodes. Defaults to the cluster's own internal security group when unset."
}
