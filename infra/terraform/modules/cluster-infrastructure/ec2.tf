resource "aws_instance" "master" {
  ami                    = var.ami_id
  instance_type          = var.master_node_instance_type
  key_name               = local.key_name
  subnet_id              = var.subnet_ids[0]
  vpc_security_group_ids = concat(local.internal_access_sg_ids, var.external_access_security_group_ids)
  iam_instance_profile   = aws_iam_instance_profile.platform_main.name
  user_data              = local.master_node_userdata

  depends_on = [aws_efs_mount_target.shared]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.master_node_volume_size
    encrypted             = true
    kms_key_id            = module.kms.key_arn
    delete_on_termination = true
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name_prefix}-master-node"
    Role = "master-node"
  })
}

resource "aws_instance" "application" {
  count = var.application_node_count

  ami                    = var.ami_id
  instance_type          = var.application_node_instance_type
  key_name               = local.key_name
  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids = concat(local.internal_access_sg_ids, var.external_access_security_group_ids)
  iam_instance_profile   = aws_iam_instance_profile.platform_main.name
  user_data              = local.application_node_userdata

  depends_on = [aws_efs_mount_target.shared]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.application_node_volume_size
    encrypted             = true
    kms_key_id            = module.kms.key_arn
    delete_on_termination = true
  }

  tags = merge(local.tags, {
    Name = "${local.resource_name_prefix}-application-node-${count.index + 1}"
    Role = "application-node"
  })
}
