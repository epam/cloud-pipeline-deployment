locals {
  resource_name_prefix = lower(replace("${var.deployment_name}-${var.deployment_env}", "_", "-"))
  cp_deployment_id     = coalesce(var.cp_deployment_id, local.resource_name_prefix)

  tags = merge(
    {
      Project     = var.deployment_name
      Environment = var.deployment_env
    },
    var.additional_tags
  )

  key_name               = var.key_name != null ? var.key_name : aws_key_pair.cp_cluster[0].key_name
  internal_access_sg_ids = length(var.security_group_ids) > 0 ? var.security_group_ids : [module.internal_access_sg[0].id]

  docker_registry_bucket_name = var.create_s3_buckets ? module.s3_docker_registry[0].s3_bucket_id : var.docker_registry_bucket_name
  system_bucket_name          = var.create_s3_buckets ? module.s3_system_storage[0].s3_bucket_id : var.system_bucket_name

  edge_external_ip = coalesce(var.edge_external_ip, aws_instance.master.private_ip)

  idp_enabled       = var.idp_host != null
  share_srv_enabled = var.share_srv_host != null

  admin_password       = coalesce(var.admin_password, try(random_password.admin[0].result, null))
  db_password          = coalesce(var.db_password, try(random_password.db[0].result, null))
  gitlab_root_password = coalesce(var.gitlab_root_password, try(random_password.gitlab_root[0].result, null))

  cp_storage_id         = var.storage_type == "efs" ? aws_efs_file_system.cp_storage[0].id : aws_fsx_lustre_file_system.cp_storage[0].id
  cp_storage_dns_name   = var.storage_type == "efs" ? "${aws_efs_file_system.cp_storage[0].id}.efs.${data.aws_region.current.region}.amazonaws.com" : aws_fsx_lustre_file_system.cp_storage[0].dns_name
  cp_storage_mount_name = var.storage_type == "fsx" ? aws_fsx_lustre_file_system.cp_storage[0].mount_name : ""

  # CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC: see helm/hooks/post-deploy/apply-cluster-networks-config.sh
  # for the actual consumed shape (helm/README.md's and helm/values.yaml's own commented-out
  # schemas agree with it, except values.yaml's "securityGroupIds" is stale -- the script reads
  # snake_case "security_group_ids"). Kept as the same "{}" placeholder upstream uses until
  # worker_node_amis is set, since pipeline runs can't launch without at least one worker AMI
  # anyway. Once set, also auto-fills networks (every var.subnet_ids entry, named by its AZ) and
  # security_group_ids (defaulting to this cluster's own security group) -- the parts this module
  # already knows, rather than requiring a manual values.yaml edit for all of it.
  cluster_networks_spec = length(var.worker_node_amis) == 0 ? " {}" : "\n          ${indent(10, yamlencode({
    regions = [
      {
        name               = ""
        networks           = { for s in var.subnet_ids : s => data.aws_subnet.this[s].availability_zone }
        amis               = var.worker_node_amis
        security_group_ids = coalesce(var.worker_node_security_group_ids, local.internal_access_sg_ids)
      }
    ]
  }))}"

  master_node_userdata = templatefile("${path.module}/templates/master_node_userdata.sh.tpl", {
    storage_type           = var.storage_type
    storage_id             = local.cp_storage_id
    storage_dns_name       = local.cp_storage_dns_name
    storage_mount_name     = local.cp_storage_mount_name
    application_node_count = var.application_node_count
    master_node_labels     = var.master_node_labels != null ? var.master_node_labels : ""
  })

  application_node_userdata = templatefile("${path.module}/templates/application_node_userdata.sh.tpl", {
    storage_type            = var.storage_type
    storage_id              = local.cp_storage_id
    storage_dns_name        = local.cp_storage_dns_name
    storage_mount_name      = local.cp_storage_mount_name
    application_node_labels = var.application_node_labels
  })

  cp_values_yaml = templatefile("${path.module}/templates/cp-values.yaml.tpl", {
    aws_region                  = data.aws_region.current.region
    deployment_id               = local.cp_deployment_id
    master_node_private_ip      = aws_instance.master.private_ip
    kms_key_arn                 = module.kms.key_arn
    ssh_key_name                = local.key_name
    s3_via_sts_role_arn         = aws_iam_role.s3_via_sts.arn
    docker_registry_bucket_name = local.docker_registry_bucket_name
    system_bucket_name          = local.system_bucket_name

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
