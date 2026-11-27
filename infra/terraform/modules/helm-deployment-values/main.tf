# Renders a full Cloud Pipeline helm/values.yaml from this infrastructure's values -- see
# ../../CLAUDE.md and ../../../helm/README.md for what each value configures.
locals {
  idp_enabled       = var.idp_host != null
  share_srv_enabled = var.share_srv_host != null

  edge_external_ip = coalesce(var.edge_external_ip, var.master_node_private_ip)

  admin_password       = coalesce(var.admin_password, try(random_password.admin[0].result, null))
  db_password          = coalesce(var.db_password, try(random_password.db[0].result, null))
  gitlab_root_password = coalesce(var.gitlab_root_password, try(random_password.gitlab_root[0].result, null))

  cluster_networks_azs = distinct([for s in var.subnet_ids : data.aws_subnet.this[s].availability_zone])
  cluster_networks_map = {
    for az in local.cluster_networks_azs :
    az => [for s in var.subnet_ids : s if data.aws_subnet.this[s].availability_zone == az][0]
  }

  cluster_networks_spec = length(var.worker_node_amis) == 0 ? " {}" : "\n          ${indent(10, yamlencode({
    regions = [
      {
        name               = ""
        default            = true
        networks           = local.cluster_networks_map
        amis               = var.worker_node_amis
        security_group_ids = distinct(concat(var.security_group_ids, var.worker_node_security_group_ids))
      }
    ]
  }))}"

  rendered = templatefile("${path.module}/templates/helm-deployment-values.yaml.tpl", {
    aws_region                  = var.aws_region
    deployment_id               = var.deployment_id
    master_node_private_ip      = var.master_node_private_ip
    kms_key_arn                 = var.kms_key_arn
    ssh_key_name                = var.ssh_key_name
    s3_via_sts_role_arn         = var.s3_via_sts_role_arn
    docker_registry_bucket_name = var.docker_registry_bucket_name
    system_bucket_name          = var.system_bucket_name

    admin_name     = var.admin_name
    admin_email    = var.admin_email
    admin_password = local.admin_password
    db_password    = local.db_password

    api_srv_host         = var.api_srv_host
    docker_registry_host = var.docker_registry_host
    edge_host            = var.edge_host
    edge_external_ip     = local.edge_external_ip
    git_host             = var.git_host
    gitlab_root_password = local.gitlab_root_password
    idp_enabled          = local.idp_enabled
    idp_host             = var.idp_host != null ? var.idp_host : ""
    share_srv_enabled    = local.share_srv_enabled
    share_srv_host       = var.share_srv_host != null ? var.share_srv_host : ""

    cluster_networks_spec = local.cluster_networks_spec
    docker_tools          = var.docker_tools

    enable_search             = var.enable_search
    enable_billing            = var.enable_billing
    enable_notifier           = var.enable_notifier
    enable_monitoring         = var.enable_monitoring
    enable_storage_lifecycle  = var.enable_storage_lifecycle
    enable_dav                = var.enable_dav
    enable_run_policy_manager = var.enable_run_policy_manager
    enable_post_deploy        = var.enable_post_deploy
  })
}
