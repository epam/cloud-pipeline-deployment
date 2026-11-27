output "resource_name_prefix" {
  description = "Prefix used for the name of every resource created by this module."
  value       = local.resource_name_prefix
}

output "deployment_id" {
  description = "Cloud Pipeline deployment identifier (CP_DEPLOYMENT_ID)."
  value       = local.deployment_id
}

output "master_node_id" {
  description = "EC2 instance ID of the master node."
  value       = aws_instance.master.id
}

output "master_node_private_ip" {
  description = "Private IP of the master node (CP_KUBE_EXTERNAL_HOST)."
  value       = aws_instance.master.private_ip
}

output "master_node_ssm_session_command" {
  description = "AWS CLI command to open an SSM session on the master node."
  value       = "aws ssm start-session --region ${data.aws_region.current.region} --target ${aws_instance.master.id}"
}

output "application_node_ids" {
  description = "EC2 instance IDs of the application nodes."
  value       = aws_instance.application[*].id
}

output "application_node_private_ips" {
  description = "Private IPs of the application nodes."
  value       = aws_instance.application[*].private_ip
}

output "security_group_ids" {
  description = "IDs of the internal-access security group(s) shared by all nodes and the filesystem mount targets."
  value       = local.internal_access_sg_ids
}

output "storage_type" {
  description = "Shared filesystem backend in use ('efs' or 'fsx')."
  value       = var.storage_type
}

output "storage_id" {
  description = "ID of the shared filesystem (EFS filesystem ID or FSx Lustre filesystem ID)."
  value       = local.shared_storage_id
}

output "storage_mount_command" {
  description = "Command to manually mount the shared filesystem at /opt (for reference; nodes mount it automatically via user data)."
  value = (
    var.storage_type == "efs"
    ? "mount -t efs -o tls ${local.shared_storage_id}:/ /opt"
    : "mount -t lustre -o relatime,flock ${local.shared_storage_dns_name}@tcp:/${local.shared_storage_mount_name} /opt"
  )
}

output "kms_key_id" {
  description = "ID of the KMS key used to encrypt EBS volumes, the shared filesystem and S3 buckets."
  value       = module.kms.key_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt EBS volumes, the shared filesystem and S3 buckets."
  value       = module.kms.key_arn
}

output "platform_main_role_name" {
  description = "Name of the IAM role attached to every cluster node."
  value       = aws_iam_role.platform_main.name
}

output "platform_main_role_arn" {
  description = "ARN of the IAM role attached to every cluster node."
  value       = aws_iam_role.platform_main.arn
}

output "s3_via_sts_role_arn" {
  description = "ARN of the role assumed to hand out temporary storage credentials (CP_PREF_STORAGE_TEMP_CREDENTIALS_ROLE)."
  value       = aws_iam_role.s3_via_sts.arn
}

output "docker_registry_bucket_name" {
  description = "Name of the S3 bucket backing the internal Docker registry (CP_DOCKER_STORAGE_CONTAINER)."
  value       = local.docker_registry_bucket_name
}

output "system_bucket_name" {
  description = "Name of the S3 bucket used for Cloud Pipeline system storage (CP_PREF_STORAGE_SYSTEM_STORAGE_NAME)."
  value       = local.system_bucket_name
}

output "ssh_key_name" {
  description = "Name of the EC2 key pair used by the cluster nodes."
  value       = local.key_name
}

output "generated_ssh_private_key_pem" {
  description = "PEM-encoded private key, only set when key_name was left unset and this module generated a new key pair. Store it securely (e.g. in a secrets manager) -- it is not retained anywhere else."
  value       = try(tls_private_key.generated[0].private_key_pem, null)
  sensitive   = true
}

