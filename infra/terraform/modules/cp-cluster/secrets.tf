# Generated only when the caller does not supply the corresponding credential.
# special = false avoids characters that would need extra quoting/escaping in
# YAML (helm/values.yaml) or shell scripts (bootstrap.env, GitLab init).

resource "random_password" "admin" {
  count   = var.admin_password == null ? 1 : 0
  length  = 20
  special = false
}

resource "random_password" "db" {
  count   = var.db_password == null ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "gitlab_root" {
  count   = var.gitlab_root_password == null ? 1 : 0
  length  = 20
  special = false
}
