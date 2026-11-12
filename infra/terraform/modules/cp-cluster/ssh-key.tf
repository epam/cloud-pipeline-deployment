# Generated only when the caller does not supply an existing key pair name.
resource "tls_private_key" "cp_cluster" {
  count = var.key_name == null ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "cp_cluster" {
  count = var.key_name == null ? 1 : 0

  key_name   = "${local.resource_name_prefix}-key"
  public_key = trimspace(tls_private_key.cp_cluster[0].public_key_openssh)

  tags = local.tags
}
