output "master_node_id" {
  value = module.cluster_infrastructure.master_node_id
}

output "master_node_ssm_session_command" {
  value = module.cluster_infrastructure.master_node_ssm_session_command
}

output "application_node_ids" {
  value = module.cluster_infrastructure.application_node_ids
}

output "storage_id" {
  value = module.cluster_infrastructure.storage_id
}

output "storage_mount_command" {
  value = module.cluster_infrastructure.storage_mount_command
}

output "kms_key_arn" {
  value = module.cluster_infrastructure.kms_key_arn
}

output "docker_registry_bucket_name" {
  value = module.cluster_infrastructure.docker_registry_bucket_name
}

output "system_bucket_name" {
  value = module.cluster_infrastructure.system_bucket_name
}

output "s3_via_sts_role_arn" {
  value = module.cluster_infrastructure.s3_via_sts_role_arn
}

output "ssh_key_name" {
  value = module.cluster_infrastructure.ssh_key_name
}

output "generated_ssh_private_key_pem" {
  value     = module.cluster_infrastructure.generated_ssh_private_key_pem
  sensitive = true
}
