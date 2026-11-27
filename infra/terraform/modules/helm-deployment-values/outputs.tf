output "rendered" {
  description = "A full values.yaml enabling every Cloud Pipeline service, pre-filled with this infrastructure's values (see infra/terraform/README.md). Sensitive: it embeds the admin/db/GitLab passwords below."
  value       = local.rendered
  sensitive   = true
}

output "admin_password" {
  description = "Default Cloud Pipeline administrator password. Only set here when admin_password was left unset and this module generated one."
  value       = local.admin_password
  sensitive   = true
}

output "db_password" {
  description = "Password for the internal Postgres 'pipeline' database user. Only set here when db_password was left unset and this module generated one."
  value       = local.db_password
  sensitive   = true
}

output "gitlab_root_password" {
  description = "Password for the GitLab 'root' user. Only set here when gitlab_root_password was left unset and this module generated one."
  value       = local.gitlab_root_password
  sensitive   = true
}
