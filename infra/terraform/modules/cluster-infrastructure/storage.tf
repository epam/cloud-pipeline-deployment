# Shared filesystem mounted at /opt on every node. It also doubles as the
# join-credential exchange point that lets application nodes find and join
# the master automatically (see infra/README.md#multi-node-join-flow).

resource "aws_efs_file_system" "shared" {
  count = var.storage_type == "efs" ? 1 : 0

  creation_token   = "${local.resource_name_prefix}-shared-storage"
  performance_mode = var.efs_performance_mode
  throughput_mode  = var.efs_throughput_mode
  provisioned_throughput_in_mibps = (
    var.efs_throughput_mode == "provisioned" ? var.efs_provisioned_throughput_in_mibps : null
  )
  encrypted  = true
  kms_key_id = module.kms.key_arn

  tags = merge(local.tags, { Name = "${local.resource_name_prefix}-shared-storage" })
}

resource "aws_efs_backup_policy" "shared" {
  count = var.storage_type == "efs" && var.enable_efs_backup_policy ? 1 : 0

  file_system_id = aws_efs_file_system.shared[0].id

  backup_policy {
    status = "ENABLED"
  }
}

resource "aws_efs_mount_target" "shared" {
  for_each = var.storage_type == "efs" ? toset(var.subnet_ids) : toset([])

  file_system_id  = aws_efs_file_system.shared[0].id
  subnet_id       = each.value
  security_groups = local.internal_access_sg_ids
}

resource "aws_fsx_lustre_file_system" "shared" {
  count = var.storage_type == "fsx" ? 1 : 0

  storage_capacity = var.fsx_storage_capacity
  subnet_ids       = [var.subnet_ids[0]]
  deployment_type  = var.fsx_deployment_type
  per_unit_storage_throughput = (
    contains(["PERSISTENT_1", "PERSISTENT_2"], var.fsx_deployment_type) ? var.fsx_per_unit_storage_throughput : null
  )
  kms_key_id         = module.kms.key_arn
  security_group_ids = local.internal_access_sg_ids

  tags = merge(local.tags, { Name = "${local.resource_name_prefix}-shared-storage" })
}
