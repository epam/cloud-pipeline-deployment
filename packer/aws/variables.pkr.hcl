variable "ami_name_prefix" {
  type        = string
  description = "Custom string to preprend to the resulting AMI name"
  default     = "CloudPipeline-Quick-Start"
}

variable "vpc_id" {
  type        = string
  description = "Id of the VCP to be used for creating and terminating EC2 during build AMI process"
}

variable "subnet_id" {
  type        = string
  description = "Ids of the VCP subnets to be used for creating and terminating EC2 during the build AMI process"
}

variable "region" {
  type        = string
  description = "Region where will be created and terminated EC2 during the build AMI process"
  default     = "us-east-1"
}

variable "instance_type" {
  type        = string
  description = "Type of instance that will be created and terminated during the build AMI process"
}

variable "security_group_id" {
  type        = string
  description = "ID of the security group for the EC2 instance, configured to allow necessary traffic for the instance operations"
}

variable "iam_instance_profile" {
  type =  string
  default = ""
  description = "IAM profile to be assigned to the temporary instance (shall allow SSM communication if ssh_interface is set to session_manager)"
}

variable "ssh_interface" {
  type =  string
  default = ""
  description = "Defines which protocol to use for the instance communication: SSH or SSM. Use session_manager for SSM and keep empty for SSH."
}

variable "dns_hosts_sync_image" {
  type        = string
  default     = "quay.io/lifescience/cloud-pipeline:dns-hosts-sync-0.17"
  description = "Full image reference for the dns-hosts-sync sidecar injected into the kube-dns deployment."
}

variable "cloud_pipeline_deploy_dir_path" {
  type        = string
  default     = "/var/lib/cloud-pipeline/deploy"
  description = "Filesystem path on the AMI where Cloud Pipeline deployment artifacts are stored. Exposed on the instance as CLOUD_PIPELINE_DISTRO_DIR in /etc/environment."
}
