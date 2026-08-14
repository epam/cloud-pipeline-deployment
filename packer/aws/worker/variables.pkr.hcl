variable "ami_name_prefix" {
  type        = string
  default     = "CloudPipeline-Worker"
  description = "Custom string to prepend to the resulting AMI name."
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC to be used for creating and terminating EC2 during the build AMI process."
}

variable "subnet_id" {
  type        = string
  description = "ID of the VPC subnet to be used for creating and terminating EC2 during the build AMI process."
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "Region where the EC2 instance will be created and terminated during the build AMI process."
}

variable "cpu_instance_type" {
  type        = string
  default     = "m6i.large"
  description = "Instance type for the CPU worker AMI build."
}

variable "gpu_instance_type" {
  type        = string
  default     = "g6.xlarge"
  description = "Instance type for the GPU worker AMI build."
}

variable "security_group_id" {
  type        = string
  description = "ID of the security group for the EC2 instance, configured to allow necessary traffic for the instance operations."
}

variable "iam_instance_profile" {
  type        = string
  default     = ""
  description = "IAM profile to be assigned to the temporary instance (shall allow SSM communication if ssh_interface is set to session_manager)."
}

variable "ssh_interface" {
  type        = string
  default     = ""
  description = "Defines which protocol to use for the instance communication: SSH or SSM. Use session_manager for SSM and keep empty for SSH."
}
