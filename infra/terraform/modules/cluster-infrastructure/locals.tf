locals {
  resource_name_prefix = lower(replace("${var.deployment_name}-${var.deployment_env}", "_", "-"))
  deployment_id        = coalesce(var.deployment_id, local.resource_name_prefix)

  tags = merge(
    {
      Project     = var.deployment_name
      Environment = var.deployment_env
    },
    var.additional_tags
  )

  key_name               = var.key_name != null ? var.key_name : aws_key_pair.generated[0].key_name
  internal_access_sg_ids = length(var.security_group_ids) > 0 ? var.security_group_ids : [module.internal_access_sg[0].id]

  docker_registry_bucket_name = var.create_s3_buckets ? module.s3_docker_registry[0].s3_bucket_id : var.docker_registry_bucket_name
  system_bucket_name          = var.create_s3_buckets ? module.s3_system_storage[0].s3_bucket_id : var.system_bucket_name

  shared_storage_id         = var.storage_type == "efs" ? aws_efs_file_system.shared[0].id : aws_fsx_lustre_file_system.shared[0].id
  shared_storage_dns_name   = var.storage_type == "efs" ? "${aws_efs_file_system.shared[0].id}.efs.${data.aws_region.current.region}.amazonaws.com" : aws_fsx_lustre_file_system.shared[0].dns_name
  shared_storage_mount_name = var.storage_type == "fsx" ? aws_fsx_lustre_file_system.shared[0].mount_name : ""

  master_node_userdata = templatefile("${path.module}/templates/master_node_userdata.sh.tpl", {
    storage_type           = var.storage_type
    storage_id             = local.shared_storage_id
    storage_dns_name       = local.shared_storage_dns_name
    storage_mount_name     = local.shared_storage_mount_name
    application_node_count = var.application_node_count
    master_node_labels     = var.master_node_labels != null ? var.master_node_labels : ""
  })

  application_node_userdata = templatefile("${path.module}/templates/application_node_userdata.sh.tpl", {
    storage_type            = var.storage_type
    storage_id              = local.shared_storage_id
    storage_dns_name        = local.shared_storage_dns_name
    storage_mount_name      = local.shared_storage_mount_name
    application_node_labels = var.application_node_labels
  })
}
