output "master_node_id" {
  value = module.cluster_infrastructure.master_node_id
}

output "master_node_ssm_session_command" {
  value = module.cluster_infrastructure.master_node_ssm_session_command
}

output "application_node_ids" {
  value = module.cluster_infrastructure.application_node_ids
}

output "docker_registry_bucket_name" {
  value = module.cluster_infrastructure.docker_registry_bucket_name
}

output "system_bucket_name" {
  value = module.cluster_infrastructure.system_bucket_name
}

output "ssh_key_name" {
  value = module.cluster_infrastructure.ssh_key_name
}

output "generated_ssh_private_key_pem" {
  value     = module.cluster_infrastructure.generated_ssh_private_key_pem
  sensitive = true
}

output "admin_password" {
  value     = module.helm_values.admin_password
  sensitive = true
}

output "db_password" {
  value     = module.helm_values.db_password
  sensitive = true
}

output "gitlab_root_password" {
  value     = module.helm_values.gitlab_root_password
  sensitive = true
}

output "helm_values_yaml" {
  value     = module.helm_values.rendered
  sensitive = true
}
