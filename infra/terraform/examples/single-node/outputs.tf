output "master_node_id" {
  value = module.cp_cluster.master_node_id
}

output "master_node_ssm_session_command" {
  value = module.cp_cluster.master_node_ssm_session_command
}

output "application_node_ids" {
  value = module.cp_cluster.application_node_ids
}

output "docker_registry_bucket_name" {
  value = module.cp_cluster.docker_registry_bucket_name
}

output "system_bucket_name" {
  value = module.cp_cluster.system_bucket_name
}

output "ssh_key_name" {
  value = module.cp_cluster.ssh_key_name
}

output "generated_ssh_private_key_pem" {
  value     = module.cp_cluster.generated_ssh_private_key_pem
  sensitive = true
}

output "admin_password" {
  value     = module.cp_cluster.admin_password
  sensitive = true
}

output "db_password" {
  value     = module.cp_cluster.db_password
  sensitive = true
}

output "gitlab_root_password" {
  value     = module.cp_cluster.gitlab_root_password
  sensitive = true
}

output "cp_values_yaml" {
  value     = module.cp_cluster.cp_values_yaml
  sensitive = true
}
